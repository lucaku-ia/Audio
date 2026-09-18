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
"""
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


def _log_call(db: AsyncSession, *, prompt: str, version: str, purpose: str, usage, latency_ms: int,
              context: dict, rejected_reason: str | None = None) -> None:
    db.add(AICall(
        call_id=uuid.uuid4(),
        prompt=prompt,
        version=version,
        purpose=purpose,
        model=MODEL,
        provider=PROVIDER,
        tokens_in=usage.input_tokens,
        tokens_out=usage.output_tokens,
        cost=_cost(usage),
        latency_ms=latency_ms,
        context=context,
        rejected_reason=rejected_reason,
        creado_en=datetime.utcnow(),
    ))


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
    start = time.monotonic()
    response = _client.messages.parse(
        model=MODEL,
        max_tokens=1024,
        thinking={"type": "adaptive"},
        output_config={"effort": "low"},
        system=STRUCTURE_REQUEST_SYSTEM,
        messages=[{"role": "user", "content": raw_text}],
        output_format=StructuredRequest,
    )
    latency_ms = int((time.monotonic() - start) * 1000)
    result = response.parsed_output

    _log_call(
        db, prompt="structure_request", version=STRUCTURE_REQUEST_VERSION, purpose="structure_request",
        usage=response.usage, latency_ms=latency_ms,
        context={"customer_id": str(customer_id), "request_id": str(request_id) if request_id else None},
        rejected_reason=result.rejected_reason,
    )
    return result


class BlockResult(BaseModel):
    summary: str
    script: str
    sources: list[dict]
    no_news: bool


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
    server-side web_search tool (licensed/API sources per the Generator PRD's
    intent, not scraping) so the whole research+write step happens in a
    single request/response, no client-side tool loop needed.

    Scope reduction vs. the full PRD: true novelty judgment (§4, "against
    the customer's previous blocks in the shared index, last 14 days") isn't
    implemented — there's no shared index yet (AI Platform hasn't built it).
    This call only judges "is there anything new today", not "new since we
    last told this customer" — see episode_generator.py for the fuller note.
    """
    depth = depth if depth in _DEPTH_WORDS else "standard"
    style = style if style in _STYLE_DESCRIPTIONS else "news"
    language_name = "Spanish" if language == "es" else "English"

    system = RESEARCH_AND_WRITE_BLOCK_SYSTEM.format(
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

    _log_call(
        db, prompt="research_and_write_block", version=RESEARCH_AND_WRITE_BLOCK_VERSION,
        purpose="research_and_write_block", usage=response.usage, latency_ms=latency_ms,
        context={"customer_id": str(customer_id), "request_id": str(request_id)},
    )

    text = next((b.text for b in reversed(response.content) if b.type == "text"), "")
    return _parse_block_result(text)


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


# ── synthesize() — TTS via ElevenLabs ────────────────────────────────────────
#
# The AI Platform PRD names ElevenLabs as the pilot's TTS provider (§9, and
# the pilot budget in the Umbrella PRD §9 is costed off ElevenLabs Scale-tier
# rates). Deliberately minimal: one REST call per script, no voice cloning,
# no timestamp alignment (ElevenLabs' character-level alignment lives behind
# a separate `/with-timestamps` endpoint — the Generator falls back to the
# word-count estimate for block offsets either way, per its own PRD §5).

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


async def synthesize(
    db: AsyncSession,
    text: str,
    voice_id: str | None,
    customer_id: uuid.UUID,
    request_id: uuid.UUID | None = None,
    episode_id: uuid.UUID | None = None,
) -> bytes:
    """
    Text-to-speech for one script (a block, or the whole assembled episode).
    Returns raw audio bytes (mp3). Logs one AICall with `characters` set
    (PRD: AICall.characters is "for TTS calls") and cost from the pilot's
    per-1000-character rate.

    Raises on any failure (missing key, non-2xx from ElevenLabs) — callers
    must check elevenlabs_configured() first if a missing key should
    degrade gracefully rather than fail the job.
    """
    api_key = os.getenv("ELEVENLABS_API_KEY")
    if not api_key:
        raise RuntimeError("ELEVENLABS_API_KEY is not set")

    voice_id = voice_id or await _default_voice_id(api_key)

    start = time.monotonic()
    async with httpx.AsyncClient(timeout=120.0) as client:
        response = await client.post(
            f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}",
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
        raise RuntimeError(f"ElevenLabs synthesize failed: {reason}")

    db.add(AICall(
        call_id=uuid.uuid4(), prompt="synthesize", version="v1", purpose="synthesize",
        model=_ELEVENLABS_MODEL, provider="elevenlabs", characters=len(text),
        cost=(len(text) / 1000) * _ELEVENLABS_PRICE_PER_1K_CHARS,
        latency_ms=latency_ms,
        context={"customer_id": str(customer_id), "request_id": str(request_id) if request_id else None,
                 "episode_id": str(episode_id) if episode_id else None},
        creado_en=datetime.utcnow(),
    ))
    return response.content
