"""
AI Platform PRD (Andrés + Juan, Draft v1) — the one door every model call
goes through.

Scope note: this implements step 1 of the PRD's own delivery order (§9):
"Call wrapper with cost telemetry — unblocks Onboarding and Request
Management." Everything else in the PRD (a full prompt registry, the
shared semantic index for Home/Search, evals, multi-provider fallback,
budgets/rate limits) is deliberately deferred — each needs the epic that
consumes it (Home, Search) to exist first.

Also now backs the Episode Generator's research+writing stage
(research_and_write_block) and voicing stage (synthesize) — see
app/services/episode_generator.py for the scope note on what's built
there. The Generator PRD's own tenet applies here too: this function
decides *how* to research or voice (a bounded web search call; a TTS
call) and log it; episode_generator.py decides *what* to do with the
result (assemble, trim, publish).

Tenets followed here:
- How, never what: this module doesn't decide whether a request is worth
  pursuing, only whether it's safe and how to structure it. Callers
  (Request Management, Onboarding, the Generator) decide what to do with
  the result.
- Every call has an id and a cost: every call writes an AICall row
  (app/models/instrumentation.py), matching the existing Instrumentation
  catalog.
- Prompts are versioned artifacts: each *_VERSION constant is bumped
  whenever its matching *_SYSTEM prompt changes.

Prompt registry (PRD §9's next delivery-order item, now built — see
app/models/prompt_registry.py and app/services/prompt_registry.py for the
full scope note): the *_SYSTEM / *_VERSION constants below are no longer
what callers use directly. They're now the SEED DATA — the source of
truth the registry's `prompt_versions` table is populated from on first
boot (app/main.py's lifespan), and the safety fallback if the registry
lookup ever comes up empty. Each function below calls
prompt_registry.get_active_prompt() to get its actual system prompt text
and version at call time, passing its own *_SYSTEM/*_VERSION constant as
the fallback. Do not delete these constants — they are load-bearing for
both seeding and the fallback path, not dead code.
"""
import base64
import json
import os
import re
import time
import uuid
from datetime import datetime

import anthropic
import httpx
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.instrumentation import AICall
from app.services.events import emitir
from app.services.prompt_registry import get_active_prompt
from app.services.source_catalogue import attach_licenses

_client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from the environment

MODEL = "claude-opus-5"
PROVIDER = "anthropic"

# Per-1M-token prices (USD) — PRD §5: "per-provider price tables in config;
# cost computed at call time." Update here if pricing changes. Note: this
# does not include the web_search tool's own per-search cost, which isn't
# broken out by the API response usage object — logged costs are therefore
# a token-only approximation for any call that uses web_search.
_PRICE_PER_1M = {"claude-opus-5": {"input": 5.00, "output": 25.00}}


def _cost(usage) -> float:
    prices = _PRICE_PER_1M.get(MODEL, {"input": 0.0, "output": 0.0})
    return (usage.input_tokens / 1_000_000) * prices["input"] + (usage.output_tokens / 1_000_000) * prices["output"]


async def _log_call(db: AsyncSession, *, customer_id: uuid.UUID, prompt: str, version: str, purpose: str,
                     usage, latency_ms: int, context: dict, rejected_reason: str | None = None) -> float:
    """
    Logs the AICall row and returns its `cost` so direct callers (currently
    research_and_write_block and synthesize) can thread per-call cost up to
    the Generator's stage-cost accounting without either function's public
    signature growing new business-logic parameters — see the "Cost per
    stage" scope note on research_and_write_block/synthesize below and in
    app/services/episode_generator.py's run_generation for why this (not a
    time-window AICall query) was chosen.
    """
    cost = _cost(usage)
    db.add(AICall(
        call_id=uuid.uuid4(),
        prompt=prompt,
        version=version,
        purpose=purpose,
        model=MODEL,
        provider=PROVIDER,
        tokens_in=usage.input_tokens,
        tokens_out=usage.output_tokens,
        cost=cost,
        latency_ms=latency_ms,
        context=context,
        rejected_reason=rejected_reason,
        creado_en=datetime.utcnow(),
    ))
    # The AICall row above is the detailed cost/latency record (System Contracts'
    # own object); the Instrumentation catalogue (§5) additionally lists "ai_call"
    # as its own Event, distinct from AICall, so it's emitted here too — the
    # catalogue's "if it's not in the catalogue it doesn't exist" tenet is read
    # literally: an AICall row alone doesn't make an `ai_call` Event exist.
    # `ai_rejected` fires in addition to (not instead of) `ai_call`, since a
    # rejected request still consumed a call — losing that from the ai_call
    # count would undercount volume/cost.
    await emitir(db, "ai_call", customer_id=customer_id, source="ai_platform", purpose=purpose)
    if rejected_reason:
        await emitir(db, "ai_rejected", customer_id=customer_id, source="ai_platform", purpose=purpose)
    return cost


class StructuredRequest(BaseModel):
    topic: str
    scope: str
    geography: str | None
    depth: str
    rejected: bool
    rejected_reason: str | None


STRUCTURE_REQUEST_VERSION = "v1"

STRUCTURE_REQUEST_SYSTEM = """You turn a customer's freeform research request into a structured object for a daily audio research service, and screen it for safety.

Output fields:
- topic: the subject in a few words.
- scope: what specifically about the topic (e.g. "daily developments", "price movements", "new research").
- geography: a place name if the request is geography-scoped, else null.
- depth: "brief" | "standard" | "deep" — how much detail the customer seems to want.
- rejected: true if the request cannot be safely or meaningfully researched.
- rejected_reason: a short, customer-facing explanation when rejected, else null.

Reject when the request:
- cannot be sourced (too vague, not about anything researchable — e.g. "asdf" or "tell me something"),
- is about a private individual (not a public figure) rather than a public topic,
- asks for something malicious, illegal, or intended to harm a person or group.

Do not reject requests merely because they are broad, opinionated, or about a public figure or public company — narrow scoping is fine and expected, that's what 'scope' is for."""


async def structure_request(
    db: AsyncSession,
    raw_text: str,
    customer_id: uuid.UUID,
    request_id: uuid.UUID | None = None,
) -> StructuredRequest:
    """
    structure_request — used by Request Management (create/edit) and, by
    extension, Onboarding, since requests created during onboarding go
    through the same POST /requests path. Free text in, a structured
    object plus a safety verdict out. See STRUCTURE_REQUEST_SYSTEM for the
    exact contract; bump STRUCTURE_REQUEST_VERSION when it changes.
    """
    system_prompt, version = await get_active_prompt(
        db, "structure_request",
        fallback_version=STRUCTURE_REQUEST_VERSION, fallback_system_prompt=STRUCTURE_REQUEST_SYSTEM,
    )

    start = time.monotonic()
    response = _client.messages.parse(
        model=MODEL,
        max_tokens=1024,
        thinking={"type": "adaptive"},
        output_config={"effort": "low"},
        system=system_prompt,
        messages=[{"role": "user", "content": raw_text}],
        output_format=StructuredRequest,
    )
    latency_ms = int((time.monotonic() - start) * 1000)
    result = response.parsed_output

    await _log_call(
        db, customer_id=customer_id, prompt="structure_request", version=version,
        purpose="structure_request", usage=response.usage, latency_ms=latency_ms,
        context={"customer_id": str(customer_id), "request_id": str(request_id) if request_id else None},
        rejected_reason=result.rejected_reason,
    )
    return result


class BlockResult(BaseModel):
    summary: str
    script: str
    sources: list[dict]
    no_news: bool
    # Not part of the model's own JSON output (_parse_block_result never sees
    # it) — set by research_and_write_block after _log_call returns, so the
    # Generator's research stage can accumulate real per-call cost across the
    # per-active-request loop without querying AICall back out of the DB.
    # See episode_generator.run_generation's "Cost per stage" note.
    cost: float = 0.0


RESEARCH_AND_WRITE_BLOCK_VERSION = "v1"

_DEPTH_WORDS = {"brief": "about 50-70 words", "standard": "about 100-140 words", "deep": "about 180-240 words"}
_STYLE_DESCRIPTIONS = {
    "news": "a neutral, concise news-brief voice — just the facts, no personality",
    "story": "a narrative, storytelling voice that gives context and builds a small arc",
    "casual": "a casual, conversational voice, like a knowledgeable friend catching you up",
}

RESEARCH_AND_WRITE_BLOCK_SYSTEM = """You research one customer's standing request for a daily audio briefing and write the spoken segment that answers it for today.

Use the web_search tool to find what is genuinely new or notable today (or in the last 1-2 days) about the topic. Never invent facts; only report what your searches actually returned, and cite every source you use.

After researching, respond with ONLY a single JSON object (no other text, no markdown fences) with these fields:
- "summary": one sentence, plain text, summarizing the block (for internal indexing, not read aloud).
- "script": the spoken segment itself, written in {style_description}, in {language}, targeting {word_target}. Written to be read aloud — no headers, no bullet points, no markdown.
- "sources": a list of objects {{"url": ..., "title": ..., "publisher": ...}} for every fact used. Empty list only if no_news is true.
- "no_news": true if your research found nothing new, notable, or researchable for this request today — in that case "script" and "summary" should be empty strings and "sources" an empty list. Do not pad or speculate to avoid returning no_news; an honestly empty day is correct behavior, not a failure."""


async def research_and_write_block(
    db: AsyncSession,
    raw_text: str,
    topic: str,
    scope: str,
    geography: str | None,
    depth: str,
    style: str,
    language: str,
    customer_id: uuid.UUID,
    request_id: uuid.UUID,
) -> BlockResult:
    """
    research_and_write_block — the Episode Generator's research+judge_novelty
    +write_block stages, collapsed into one call for this MVP. Uses Claude's
    server-side web_search tool (a general open-web, API-driven tool — not
    scraping — so it satisfies the PRD's "only licensed or API sources, no
    scraping" tenet at the mechanism level) so the whole research+write step
    happens in a single request/response, no client-side tool loop needed.

    Scope reduction vs. the full PRD: true novelty judgment (§4, "against
    the customer's previous blocks in the shared index, last 14 days") isn't
    implemented — there's no shared index yet (AI Platform hasn't built it).
    This call only judges "is there anything new today", not "new since we
    last told this customer" — see episode_generator.py for the fuller note.

    Source catalogue / license labeling (PRD §5's "config file: source, API,
    license, language, topics" and §4's "every block stores its sources
    (url, title, publisher, license)"): app/models/source_catalogue.py now
    holds that curated catalogue, and every source this function returns is
    passed through app.services.source_catalogue.attach_licenses before
    being handed back, which best-effort matches the source's domain against
    it and adds an explicit "license" key (the matched license_name, or None
    if the domain isn't catalogued — never fabricated). Read that module's
    docstring before assuming more: this is a provenance/labeling layer
    applied AFTER web_search already ran — it does not and cannot restrict
    web_search itself to the catalogued domains, since the `web_search_20260209`
    tool used below is a general open-web tool with no API-level allowlist
    parameter this codebase uses.
    """
    depth = depth if depth in _DEPTH_WORDS else "standard"
    style = style if style in _STYLE_DESCRIPTIONS else "news"
    language_name = "Spanish" if language == "es" else "English"

    system_template, version = await get_active_prompt(
        db, "research_and_write_block",
        fallback_version=RESEARCH_AND_WRITE_BLOCK_VERSION, fallback_system_prompt=RESEARCH_AND_WRITE_BLOCK_SYSTEM,
    )
    system = system_template.format(
        style_description=_STYLE_DESCRIPTIONS[style],
        language=language_name,
        word_target=_DEPTH_WORDS[depth],
    )

    user_content = f"Request (customer's own words): {raw_text}\nTopic: {topic}\nScope: {scope}"
    if geography:
        user_content += f"\nGeography: {geography}"

    start = time.monotonic()
    response = _client.messages.create(
        model=MODEL,
        max_tokens=4096,
        thinking={"type": "adaptive"},
        output_config={"effort": "medium"},
        system=system,
        messages=[{"role": "user", "content": user_content}],
        tools=[{"type": "web_search_20260209", "name": "web_search", "max_uses": 3}],
    )
    latency_ms = int((time.monotonic() - start) * 1000)

    cost = await _log_call(
        db, customer_id=customer_id, prompt="research_and_write_block", version=version,
        purpose="research_and_write_block", usage=response.usage, latency_ms=latency_ms,
        context={"customer_id": str(customer_id), "request_id": str(request_id)},
    )

    text = next((b.text for b in reversed(response.content) if b.type == "text"), "")
    result = _parse_block_result(text)
    result.cost = cost
    result.sources = await attach_licenses(db, result.sources)
    return result


def _parse_block_result(text: str) -> BlockResult:
    try:
        return BlockResult.model_validate_json(text)
    except Exception:
        pass
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if match:
        try:
            return BlockResult.model_validate(json.loads(match.group(0)))
        except Exception:
            pass
    # Model didn't return parseable JSON — treat as no_news rather than
    # publishing garbage (Generator tenet: "no source, no block").
    return BlockResult(summary="", script="", sources=[], no_news=True)


class RefinedStructured(BaseModel):
    topic: str
    scope: str
    geography: str | None
    depth: str


REFINE_REQUEST_VERSION = "v1"

REFINE_REQUEST_SYSTEM = """You adjust a customer's standing research request based on quick in-player feedback ("less of this" or "go deeper"), without asking them anything new.

You are given the customer's original request (their raw words, unchanged and never to be rewritten by you) together with its current structured form, and the block that most recently answered it — the actual spoken segment they reacted to — so you know exactly what "this" means to them right now.

Return a revised structured object with the same fields as the input — topic, scope, geography, depth:
- intent "less": narrow the scope and/or drop depth one level (deep -> standard -> brief; already brief stays brief) — shrink it to be closer to what the block already covered, not away from the topic entirely.
- intent "deeper": broaden the scope where it makes sense and/or raise depth one level (brief -> standard -> deep; already deep stays deep).

Keep topic and geography stable unless the block itself shows the request has clearly drifted — do not invent a different subject from a single block."""


async def refine_request(
    db: AsyncSession,
    raw_text: str,
    structured: dict,
    intent: str,
    block_summary: str,
    block_script: str,
    customer_id: uuid.UUID,
    request_id: uuid.UUID,
) -> RefinedStructured:
    """
    refine_request — backs Request Management's POST /requests/{id}/refine
    (Player PRD §5: "refine_request(request_id, intent, block_id, episode_id)
    to Request Management. RM rewrites via the AI Platform and stores a
    pending version. The player only sends intent and context.").

    raw_text is passed through only as context for the model, never
    returned or stored as a new version's raw_text — "less of this"/"go
    deeper" is feedback on depth and scope, not a new request in the
    customer's own words, so raw_text stays sacred and unchanged here
    (System Contracts §3). Only `structured` (and therefore how future
    episodes research/write this request) changes.
    """
    start = time.monotonic()
    user_content = (
        f"Original request (customer's own words, do not rewrite): {raw_text}\n"
        f"Current structured form: {json.dumps(structured)}\n"
        f"Intent: {intent}\n"
        f"Most recent block summary: {block_summary}\n"
        f"Most recent block script: {block_script}"
    )
    response = _client.messages.parse(
        model=MODEL,
        max_tokens=1024,
        thinking={"type": "adaptive"},
        output_config={"effort": "low"},
        system=REFINE_REQUEST_SYSTEM,
        messages=[{"role": "user", "content": user_content}],
        output_format=RefinedStructured,
    )
    latency_ms = int((time.monotonic() - start) * 1000)
    result = response.parsed_output

    await _log_call(
        db, customer_id=customer_id, prompt="refine_request", version=REFINE_REQUEST_VERSION, purpose="refine_request",
        usage=response.usage, latency_ms=latency_ms,
        context={"customer_id": str(customer_id), "request_id": str(request_id), "intent": intent},
    )
    return result


# ── synthesize() — TTS via ElevenLabs ────────────────────────────────────────
#
# The AI Platform PRD names ElevenLabs as the pilot's TTS provider (§9, and
# the pilot budget in the Umbrella PRD §9 is costed off ElevenLabs Scale-tier
# rates). One REST call per script, no voice cloning.
#
# Word-level timestamps (Player PRD's karaoke-style transcript view): ElevenLabs
# exposes character-level alignment only via a separate endpoint variant,
# POST /v1/text-to-speech/{voice_id}/with-timestamps (not a query param on the
# plain endpoint) — confirmed against ElevenLabs' own current API reference
# (https://elevenlabs.io/docs/api-reference/text-to-speech/convert-with-timestamps,
# fetched 2026-09-17). That endpoint returns JSON, not a raw audio/mpeg body:
#   {"audio_base64": "...", "alignment": {"characters": [...],
#    "character_start_times_seconds": [...], "character_end_times_seconds": [...]},
#    "normalized_alignment": {...same shape...}}
# instead of the plain endpoint's raw `audio/mpeg` bytes. synthesize() below
# always requests it now (with_timestamps=True by default) and collapses the
# character alignment into word-level spans, since the Player highlights whole
# words. Response-size/cost note (per the PRD's own instrumentation tenet —
# see this function's docstring): billed TTS characters and $/1k-char rate are
# unchanged (ElevenLabs prices both endpoint variants identically — you pay for
# characters synthesized, not for getting alignment back), but the HTTP response
# body is meaningfully larger than before: audio now travels as base64 (~33%
# larger than the raw bytes the plain endpoint returned) plus the alignment
# arrays themselves (3 entries per character of the script). For a ~150-word
# block this is a few hundred KB of extra JSON, not bytes — fine for a single
# server-side call, but worth knowing if this is ever called at higher volume
# or the JSON is ever proxied directly to a client.

_ELEVENLABS_MODEL = "eleven_multilingual_v2"
_ELEVENLABS_PRICE_PER_1K_CHARS = 0.18  # USD — matches the Umbrella PRD §9 pilot-budget assumption; update if ElevenLabs pricing changes

_default_voice_id_cache: str | None = None  # process-lifetime cache; see _default_voice_id()


def elevenlabs_configured() -> bool:
    """Whether an ElevenLabs key is set. The Generator checks this before
    attempting synthesize() so a missing key degrades to the pre-TTS
    behavior (script-only episode, status stays "voicing") instead of
    failing the whole job."""
    return bool(os.getenv("ELEVENLABS_API_KEY"))


async def _default_voice_id(api_key: str) -> str:
    """
    Used when the customer's profile has no voice_id yet. A hardcoded
    "well-known" voice ID (e.g. the public "Rachel" voice) isn't reliable
    across accounts/plans — free-tier accounts get HTTP 402
    "Free users cannot use library voices via the API" for voices that
    aren't already in their own account. Instead, ask the account what it
    actually has access to (GET /v1/voices, which always includes at least
    the account's premade defaults) and use the first one.
    """
    global _default_voice_id_cache
    if _default_voice_id_cache:
        return _default_voice_id_cache

    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.get("https://api.elevenlabs.io/v1/voices", headers={"xi-api-key": api_key})
    response.raise_for_status()
    voices = response.json().get("voices", [])
    if not voices:
        raise RuntimeError("ElevenLabs account has no voices available (GET /v1/voices returned none)")

    _default_voice_id_cache = voices[0]["voice_id"]
    return _default_voice_id_cache


def _collapse_alignment_to_words(text: str, alignment: dict) -> list[dict]:
    """
    ElevenLabs' alignment is per-character (`characters`,
    `character_start_times_seconds`, `character_end_times_seconds` — three
    parallel lists, one entry per character of `text` as ElevenLabs actually
    voiced it). The Player highlights whole words, not characters, so this
    collapses runs of non-whitespace characters into one span each:
    {"word": str, "start_s": float, "end_s": float}. Whitespace characters
    (which ElevenLabs includes in the alignment with their own, usually
    zero-length, timing) are dropped rather than turned into "words".

    Defensive about length mismatches (a provider-side truncation or a future
    API change) — zips only over the shortest of the three lists rather than
    indexing, so a short list never raises IndexError; any character short of
    truncated timing data is simply dropped instead of forming a partial word.
    """
    chars = alignment.get("characters") or []
    starts = alignment.get("character_start_times_seconds") or []
    ends = alignment.get("character_end_times_seconds") or []

    words: list[dict] = []
    current_word = ""
    current_start: float | None = None
    current_end: float | None = None

    def _flush():
        if current_word:
            words.append({"word": current_word, "start_s": current_start, "end_s": current_end})

    for ch, s, e in zip(chars, starts, ends):
        if ch.isspace():
            _flush()
            current_word = ""
            current_start = None
            current_end = None
            continue
        if current_start is None:
            current_start = s
        current_word += ch
        current_end = e
    _flush()
    return words


async def synthesize(
    db: AsyncSession,
    text: str,
    voice_id: str | None,
    customer_id: uuid.UUID,
    request_id: uuid.UUID | None = None,
    episode_id: uuid.UUID | None = None,
    with_timestamps: bool = True,
) -> tuple[bytes, float, list[dict] | None]:
    """
    Text-to-speech for one script (a block, or the whole assembled episode).
    Returns (raw audio bytes (mp3), cost, word_timestamps) — cost is the same
    value logged on the AICall row below, returned directly rather than making
    the Generator query AICall back out to attribute it to the voicing
    stage. See episode_generator.run_generation's "Cost per stage" note.
    Logs one AICall with `characters` set (PRD: AICall.characters is "for
    TTS calls") and cost from the pilot's per-1000-character rate — pricing is
    per character regardless of with_timestamps (see module docstring above).

    with_timestamps (default True) selects ElevenLabs' `/with-timestamps`
    endpoint variant and returns per-word timing (see
    _collapse_alignment_to_words) as the third tuple element; pass False to
    use the plain endpoint and get back (audio_bytes, cost, None) exactly as
    before this field was added — kept as an escape hatch, e.g. if a caller
    needs the smaller/simpler plain response and has no use for timestamps.

    Raises on any failure (missing key, non-2xx from ElevenLabs) — callers
    must check elevenlabs_configured() first if a missing key should
    degrade gracefully rather than fail the job.
    """
    api_key = os.getenv("ELEVENLABS_API_KEY")
    if not api_key:
        raise RuntimeError("ELEVENLABS_API_KEY is not set")

    voice_id = voice_id or await _default_voice_id(api_key)
    url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}"
    if with_timestamps:
        url += "/with-timestamps"

    start = time.monotonic()
    async with httpx.AsyncClient(timeout=120.0) as client:
        response = await client.post(
            url,
            headers={"xi-api-key": api_key, "Accept": "audio/mpeg", "Content-Type": "application/json"},
            json={"text": text, "model_id": _ELEVENLABS_MODEL},
        )
    latency_ms = int((time.monotonic() - start) * 1000)

    if response.status_code >= 400:
        # Log the failed call too (PRD: "every call is logged, including rejected ones")
        # before raising, so the cost/failure is still visible in Instrumentation.
        # rejected_reason is String(200) — truncate the whole formatted message, not
        # just response.text, or the INSERT itself fails (StringDataRightTruncationError)
        # and takes down the caller's transaction along with it.
        reason = f"HTTP {response.status_code}: {response.text}"[:200]
        db.add(AICall(
            call_id=uuid.uuid4(), prompt="synthesize", version="v1", purpose="synthesize",
            model=_ELEVENLABS_MODEL, provider="elevenlabs", characters=len(text), cost=0,
            latency_ms=latency_ms,
            context={"customer_id": str(customer_id), "request_id": str(request_id) if request_id else None,
                     "episode_id": str(episode_id) if episode_id else None},
            rejected_reason=reason,
            creado_en=datetime.utcnow(),
        ))
        # Not ai_rejected: this is a technical/provider failure, not a safety
        # rejection — ai_rejected is reserved for structure_request's safety verdict.
        await emitir(db, "ai_call", customer_id=customer_id, source="ai_platform",
                     purpose="synthesize", failed=True, status_code=response.status_code)
        raise RuntimeError(f"ElevenLabs synthesize failed: {reason}")

    cost = (len(text) / 1000) * _ELEVENLABS_PRICE_PER_1K_CHARS
    db.add(AICall(
        call_id=uuid.uuid4(), prompt="synthesize", version="v1", purpose="synthesize",
        model=_ELEVENLABS_MODEL, provider="elevenlabs", characters=len(text),
        cost=cost,
        latency_ms=latency_ms,
        context={"customer_id": str(customer_id), "request_id": str(request_id) if request_id else None,
                 "episode_id": str(episode_id) if episode_id else None},
        creado_en=datetime.utcnow(),
    ))
    await emitir(db, "ai_call", customer_id=customer_id, source="ai_platform", purpose="synthesize", failed=False)

    if not with_timestamps:
        return response.content, cost, None

    # The /with-timestamps variant returns JSON, not a raw audio/mpeg body.
    payload = response.json()
    audio_bytes = base64.b64decode(payload["audio_base64"])
    word_timestamps = _collapse_alignment_to_words(text, payload.get("alignment") or {})
    return audio_bytes, cost, word_timestamps
