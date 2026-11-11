"""
AI Platform PRD (Andrés + Juan, Draft v1) — the one door every model call
goes through.

Scope note: this implements step 1 of the PRD's own delivery order (§9):
"Call wrapper with cost telemetry — unblocks Onboarding and Request
Management." Everything else in the PRD (a full prompt registry, the
shared semantic index for Home/Search, evals, multi-provider fallback,
budgets/rate limits) is deliberately deferred — each needs the epic that
consumes it (Home, Search) to exist first.

Also now backs the Episode Generator's research stage (research_topic),
its writing stage (write_block) and its voicing stage (synthesize) — see
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
import asyncio
import base64
import json
import logging
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
from app.services import findings_store
from app.services.events import emitir
from app.services.prompt_registry import get_active_prompt
from app.services.source_catalogue import attach_licenses

_client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from the environment

PROVIDER = "anthropic"

logger = logging.getLogger(__name__)


class ModelUnavailable(RuntimeError):
    """
    The model could not be reached, or answered with an error, after retries.

    Exists so callers can tell "the provider is having a moment" apart from a
    bug in this module. Every HTTP route that structures text must translate
    this into a 503 with a sentence a person can act on — a bare exception
    here reaches the customer as `Server error (500): Internal Server Error`,
    which is both frightening and useless. See app/api/routes/requests.py.
    """


# Worth one more attempt: the request never reached a model, or the model was
# momentarily too busy. The SDK already retries these a couple of times on its
# own; this is the outer loop for when that was not enough. A 400 or a 401 is
# deliberately NOT here — those are our bug, and retrying them just spends the
# customer's time before failing anyway.
_TRANSIENT_ERRORS = (
    anthropic.APIConnectionError,   # covers APITimeoutError
    anthropic.RateLimitError,
    anthropic.InternalServerError,  # covers 529 overloaded
)
_MAX_ATTEMPTS = 3
_RETRY_BACKOFF_S = 0.75


async def _invoke(call, *args, **kwargs):
    """
    Runs one blocking Anthropic SDK call without stalling the event loop, and
    retries it when the failure is the kind that passes.

    Two separate problems, one helper, because they share a call site.

    **The blocking half.** `_client` is `anthropic.Anthropic` — the synchronous
    client. Called directly from an `async def` handler it holds the event loop
    for the entire round trip, so for those seconds this process serves nobody:
    not another customer, not a health check, not the scheduler. With
    generation still running inline on the request path that is tens of seconds
    of total freeze per episode. `asyncio.to_thread` hands the blocking call to
    a worker thread and gives the loop back immediately.

    The sync client is kept on purpose rather than switching to
    `AsyncAnthropic`: the test fakes throughout backend/tests patch `_client`
    with plain synchronous callables, and `to_thread` runs those unchanged.
    Switching the client type would mean rewriting every fake to be awaitable
    for no behavioural gain over this.

    **The failing half.** Nothing used to catch anything. One rate limit, one
    529, one dropped connection became an uncaught exception, a 500, and — in
    the onboarding chat — the literal string "Server error (500): Internal
    Server Error" in a speech bubble next to a friendly assistant. Transient
    failures now get `_MAX_ATTEMPTS` tries with backoff; anything still failing
    after that, and anything non-transient, is re-raised as `ModelUnavailable`
    for the route to turn into a 503.
    """
    last: Exception | None = None
    for attempt in range(_MAX_ATTEMPTS):
        try:
            return await asyncio.to_thread(call, *args, **kwargs)
        except _TRANSIENT_ERRORS as exc:
            last = exc
            if attempt == _MAX_ATTEMPTS - 1:
                break
            delay = _RETRY_BACKOFF_S * (2 ** attempt)
            logger.warning(
                "ai_platform: transient model failure (%s), attempt %d/%d, retrying in %.1fs",
                type(exc).__name__, attempt + 1, _MAX_ATTEMPTS, delay,
            )
            await asyncio.sleep(delay)
        except anthropic.APIError as exc:
            # Not transient: a bad request, a bad key, a model id that does not
            # exist. Retrying cannot help, and the customer cannot act on it,
            # so it is logged loudly here and reported to them as unavailable.
            logger.error("ai_platform: model call failed permanently: %s", exc, exc_info=True)
            raise ModelUnavailable(str(exc)) from exc
    logger.error("ai_platform: model unreachable after %d attempts: %s", _MAX_ATTEMPTS, last)
    raise ModelUnavailable(str(last)) from last

# Per-1M-token prices (USD) — PRD §5: "per-provider price tables in config;
# cost computed at call time." Update here if pricing changes. Note: this
# does not include the web_search tool's own per-search cost, which isn't
# broken out by the API response usage object — logged costs are therefore
# a token-only approximation for any call that uses web_search.
_PRICE_PER_1M = {
    "claude-opus-5-5":  {"input": 4.00, "output": 20.00},
    "claude-opus-5":    {"input": 5.00, "output": 25.00},
    "claude-sonnet-5-5": {"input": 2.00, "output": 10.00},
    # Haiku 5.5's listed rate holds for prompts up to 100K tokens; beyond that
    # it is $0.50 / $2.50. Every call we route to it is far under that, but if
    # one ever is not, this understates its cost — see _cost.
    "claude-haiku-5-5": {"input": 0.10, "output": 0.50},
}

_HAIKU_CHEAP_INPUT_LIMIT = 100_000
_HAIKU_LONG_PROMPT_PRICE = {"input": 0.50, "output": 2.50}

# Every call still runs on this unless its purpose says otherwise. Kept as a
# module constant because the rest of the codebase and its tests refer to it.
MODEL = "claude-opus-5-5"

# ---------------------------------------------------------------------------
# Model routing
#
# Research is ~73% of what an episode costs, and until now every call in this
# module ran on the same Opus model regardless of what it was doing. The four
# jobs here have very different shapes, and paying Opus rates for all of them
# is the single largest avoidable cost in the product:
#
#   research_topic     ~50K input tokens of web-search results, real judgment
#                      about what is new and what is worth reporting.
#   write_block        small input (findings, not raw search results), no web
#                      access. Turning facts into a paragraph in a given voice.
#   structure_request  one short sentence in, a few fields out. Classification.
#   refine_request     one block plus an intent, a few fields out.
#
# So: research stays on a strong model, writing and the two classifiers drop to
# cheap ones. Writing is the bigger saving of the two because it runs once per
# block per customer, where research can be shared.
#
# Why Sonnet and not Haiku for research: the `web_search_20260209` tool — the
# one with dynamic filtering, which this module uses — is not available on
# Haiku 5.5. Routing research there would silently fall back to a weaker search
# variant, which is a quality change disguised as a cost change.
#
# Nothing here is a guess at quality. `_ESCALATE_TO` is the other half: a cheap
# model that returns something unusable gets retried once on the strong model,
# so the floor is Opus's answer at Opus's price for the few calls that need it,
# not a worse episode.
# ---------------------------------------------------------------------------
_STRONG = "claude-opus-5-5"
_MID = "claude-sonnet-5-5"
_CHEAP = "claude-haiku-5-5"

_MODEL_BY_PURPOSE = {
    "research_topic": _MID,
    "write_block": _CHEAP,
    "structure_request": _CHEAP,
    "refine_request": _CHEAP,
}

# Which model a failed cheap call is retried on. One hop only — if the strong
# model also fails, the caller's own fallback handles it.
_ESCALATE_TO = {
    _CHEAP: _MID,
    _MID: _STRONG,
}


def model_for(purpose: str) -> str:
    """The model a given call runs on. Unknown purposes get the strong model,
    so a new call site is expensive rather than quietly degraded."""
    return _MODEL_BY_PURPOSE.get(purpose, _STRONG)


def escalation_for(purpose: str) -> str | None:
    """The model to retry `purpose` on when its first answer is unusable."""
    return _ESCALATE_TO.get(model_for(purpose))


def _cost(usage, model: str) -> float:
    prices = _PRICE_PER_1M.get(model, {"input": 0.0, "output": 0.0})
    if model == _CHEAP and usage.input_tokens > _HAIKU_CHEAP_INPUT_LIMIT:
        prices = _HAIKU_LONG_PROMPT_PRICE
    return (usage.input_tokens / 1_000_000) * prices["input"] + (usage.output_tokens / 1_000_000) * prices["output"]


async def _log_call(db: AsyncSession, *, customer_id: uuid.UUID, prompt: str, version: str, purpose: str,
                     usage, latency_ms: int, context: dict, rejected_reason: str | None = None,
                     model: str | None = None) -> float:
    """
    Logs the AICall row and returns its `cost` so direct callers (currently
    research_topic, write_block and synthesize) can thread per-call cost up to
    the Generator's stage-cost accounting without either function's public
    signature growing new business-logic parameters — see the "Cost per
    stage" scope note on research_topic/write_block/synthesize below and in
    app/services/episode_generator.py's run_generation for why this (not a
    time-window AICall query) was chosen.
    """
    model = model or model_for(purpose)
    cost = _cost(usage, model)
    db.add(AICall(
        call_id=uuid.uuid4(),
        prompt=prompt,
        version=version,
        purpose=purpose,
        model=model,
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
    response = await _invoke(
        _client.messages.parse,
        model=model_for("structure_request"),
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
    # Deliberately untyped rather than list[dict]: this field holds two things
    # at two moments. Straight out of the model it is whatever the writer
    # claimed — the write_block prompt asks for bare url strings — and
    # list[dict] would fail validation there, sending a perfectly good block
    # down _parse_block_result's no_news fallback and losing the whole segment
    # silently. _resolve_sources then replaces it with the real, license-
    # labeled source records from Findings, so every consumer downstream still
    # sees list[dict]. Do not narrow this without also changing that prompt.
    sources: list
    no_news: bool
    # Not model output — see Findings.parse_failed.
    parse_failed: bool = False
    # Not part of the model's own JSON output (_parse_block_result never sees
    # it) — set by write_block after _log_call returns, so the Generator's
    # writing stage can accumulate real per-call cost across the
    # per-active-request loop without querying AICall back out of the DB.
    # Findings.cost carries the research half separately; the two are logged
    # and reported as distinct stages. See run_generation's "Cost per stage".
    cost: float = 0.0


RESEARCH_TOPIC_VERSION = "v1"
WRITE_BLOCK_VERSION = "v2"  # v2 adds the "Already told this listener" continuity section

_DEPTH_WORDS = {"brief": "about 50-70 words", "standard": "about 100-140 words", "deep": "about 180-240 words"}
_STYLE_DESCRIPTIONS = {
    "news": "a neutral, concise news-brief voice — just the facts, no personality",
    "story": "a narrative, storytelling voice that gives context and builds a small arc",
    "casual": "a casual, conversational voice, like a knowledgeable friend catching you up",
}

RESEARCH_TOPIC_SYSTEM = """You research one topic for a daily briefing. You do not write the briefing — another step does that. Your only job is to establish what is true and new, as plainly as possible.

Use the web_search tool to find what is genuinely new or notable today (or in the last 1-2 days) about the topic. Never invent facts; only report what your searches actually returned, and attribute every finding to the source it came from.

Write findings as neutral fact, not as narration: no style, no voice, no audience, no language other than English regardless of who asked. A later step renders them for a specific listener.

Respond with ONLY a single JSON object (no other text, no markdown fences) with these fields:
- "findings": a list of objects {{"headline": ..., "detail": ..., "source_urls": [...]}}, most important first. "headline" is one plain clause naming what happened. "detail" is the substance — figures, names, dates, what changed — in a few plain sentences, enough that someone could write from it without searching again. "source_urls" lists the urls this specific finding rests on.
- "sources": a list of objects {{"url": ..., "title": ..., "publisher": ...}} for every source cited by any finding.
- "no_news": true if your research found nothing new, notable, or researchable about this topic today — in that case "findings" and "sources" should be empty. Do not pad or speculate to avoid returning no_news; an honestly empty day is correct behavior, not a failure."""

WRITE_BLOCK_SYSTEM = """You write one spoken segment of a daily audio briefing for one listener, from research findings that have already been gathered for you.

You have no web access and you do not need it. Work only from the findings given. Never add a fact that is not in them, and never soften or inflate what they say. If the findings are thin, the segment is short — that is correct.

Write in {style_description}, in {language}, targeting {word_target}. It will be read aloud by a synthetic voice, so write for the ear: no headers, no bullet points, no markdown, no parenthetical asides, and spell out figures the way a person would say them.

You may be given "Already told this listener": one-line summaries of the most recent segments this same person heard on this same topic, newest first. When it is present, write today's segment as the next instalment for someone who heard those. Say what has changed or happened since, and refer back only when it genuinely helps them follow the story. Do not re-explain what they already heard, do not open by summarizing it, and never pad the segment with recap to reach the word target — if today adds little, today is short. When that section is absent or empty, write as if this is the first time they have heard about it, with no implied history.

Respond with ONLY a single JSON object (no other text, no markdown fences) with these fields:
- "summary": one sentence, plain text, summarizing the segment (for internal indexing, not read aloud).
- "script": the spoken segment itself.
- "sources": the list of source urls you actually used, copied exactly from the findings. Do not invent urls and do not include sources you did not draw on.
- "no_news": true only if the findings contain nothing worth saying to this listener — in that case "script" and "summary" are empty strings and "sources" empty."""


class Finding(BaseModel):
    headline: str
    detail: str
    source_urls: list[str] = []


class Findings(BaseModel):
    """
    Customer-neutral research output: what is true about a topic right now,
    with no listener, style, or language baked in.

    This is the half of block production that is *shareable and cacheable*.
    Two customers asking about the same topic want the same facts; they do
    not want the same segment. Keeping this type free of customer_id, style
    and language is what makes it storable under a (topic, freshness) key and
    reusable across customers and across days — see write_block for the half
    that is deliberately per-customer.

    Nothing caches these yet; splitting the call is the prerequisite, and the
    findings store is the next step (README, "Suggested next steps").
    """
    findings: list[Finding]
    sources: list[dict]
    no_news: bool
    # Not model output. True when `no_news` is the parser giving up rather than
    # the model reporting a quiet day. Those look identical downstream and mean
    # opposite things: one is the correct answer, the other is a lost block.
    parse_failed: bool = False
    # Not model output — set by research_topic after _log_call returns, so the
    # Generator's research stage can accumulate real cost without reading
    # AICall back out of the DB. BlockResult.cost carries the writing half.
    cost: float = 0.0


async def research_topic(
    db: AsyncSession,
    raw_text: str,
    topic: str,
    scope: str,
    geography: str | None,
    customer_id: uuid.UUID,
    request_id: uuid.UUID,
) -> Findings:
    """
    research_topic — the Episode Generator's research stage, now on its own.
    Uses Claude's server-side web_search tool (a general open-web, API-driven
    tool — not scraping — so it satisfies the PRD's "only licensed or API
    sources, no scraping" tenet at the mechanism level), so the whole research
    step is one request/response with no client-side tool loop.

    Why this is separate from write_block (it used to be one fused call,
    research_and_write_block): research is expensive and identical for
    everyone asking about a topic, while writing is cheap and must differ per
    listener. Fused, neither could be cached — every customer paid full price
    to re-research the same news, and the same model call that gathered facts
    also chose the words, so there was nothing customer-neutral to store.
    Split, the expensive half is a pure function of (topic, scope, geography,
    time) and the cheap half carries style, language and depth.

    `customer_id` and `request_id` are passed for cost attribution only — they
    are NOT part of the prompt and must not become part of it, or the output
    stops being shareable. That is the whole point of the split.

    Source catalogue / license labeling (PRD §5's "config file: source, API,
    license, language, topics" and §4's "every block stores its sources
    (url, title, publisher, license)"): app/models/source_catalogue.py holds
    that curated catalogue, and every source this function returns is passed
    through app.services.source_catalogue.attach_licenses, which best-effort
    matches the source's domain against it and adds an explicit "license" key
    (the matched license_name, or None if the domain isn't catalogued — never
    fabricated). Read that module's docstring before assuming more: this is a
    provenance/labeling layer applied AFTER web_search already ran — it does
    not and cannot restrict web_search itself to the catalogued domains, since
    the `web_search_20260209` tool used below is a general open-web tool with
    no API-level allowlist parameter this codebase uses.

    Attaching licenses here rather than in write_block is deliberate: it
    happens once per topic, not once per listener, and a cached Findings then
    carries its provenance with it.
    """
    system, version = await get_active_prompt(
        db, "research_topic",
        fallback_version=RESEARCH_TOPIC_VERSION, fallback_system_prompt=RESEARCH_TOPIC_SYSTEM,
    )

    user_content = f"Topic: {topic}\nScope: {scope}"
    if geography:
        user_content += f"\nGeography: {geography}"
    # The customer's own words are included because they carry intent the
    # structured fields lose ("how did Arsenal do" wants results, not
    # transfers) — not to personalize the findings, which stay neutral.
    user_content += f"\nWhat the person asked for, in their words: {raw_text}"

    def call(model: str):
        return _client.messages.create(
            model=model,
            max_tokens=4096,
            thinking={"type": "adaptive"},
            output_config={"effort": "medium"},
            system=system,
            messages=[{"role": "user", "content": user_content}],
            tools=[{"type": "web_search_20260209", "name": "web_search", "max_uses": 3}],
        )

    # Shared findings store — the cache the split was built for. Checked
    # BEFORE the model call, so a hit costs nothing at all rather than being
    # a cheaper call. See app/services/findings_store.py for the freshness
    # rules and for why an empty result expires much sooner than a full one.
    cached = await findings_store.lookup(db, topic=topic, scope=scope, geography=geography)
    if cached is not None:
        await findings_store.record_hit(db, cached)
        await emitir(
            db, "findings_cache_hit", customer_id=customer_id, source="ai_platform",
            request_id=str(request_id), topic=topic, saved=cached.original_cost,
        )
        hit = Findings(**cached.payload)
        hit.cost = 0.0  # the whole point: a hit is free, not merely cheaper
        return hit

    findings, cost = await _run_with_escalation(
        db, purpose="research_topic", version=version, call=call, parse=_parse_findings,
        customer_id=customer_id,
        context={"customer_id": str(customer_id), "request_id": str(request_id), "topic": topic},
    )
    findings.cost = cost
    findings.sources = await attach_licenses(db, findings.sources)

    # Write through — but never cache a parse failure. That is a lost block,
    # not a finding, and storing it would turn one malformed response into
    # every later customer's malformed response for the rest of the window.
    if not findings.parse_failed:
        await findings_store.store(
            db, topic=topic, scope=scope, geography=geography,
            payload=findings.model_dump(exclude={"cost", "parse_failed"}),
            no_news=findings.no_news, researched_from=raw_text, cost=cost,
        )

    return findings


async def write_block(
    db: AsyncSession,
    findings: Findings,
    raw_text: str,
    topic: str,
    depth: str,
    style: str,
    language: str,
    customer_id: uuid.UUID,
    request_id: uuid.UUID,
    previously_told: list[str] | None = None,
) -> BlockResult:
    """
    write_block — turns already-gathered Findings into this listener's spoken
    segment. No web access, so its input is small (findings, not raw search
    results) and it is the cheap half of the pair; see research_topic for why
    they are separate.

    Everything listener-specific lives here: style, language, depth, and the
    customer's own phrasing. Two customers sharing a topic share the findings
    and still get different segments, in their own style and language, voiced
    separately. Nothing about a shared briefing is implied by the split — the
    facts are shared, the episode never is.

    The returned `sources` are looked up from `findings.sources` by url rather
    than taken from the model's own output, so a writer that hallucinates a
    url contributes nothing: it can only select from what research actually
    found, and the license labels attached at research time survive intact.

    `previously_told` is what this listener already heard on this topic (see
    app/services/told_log.py). It belongs HERE, in the per-listener half, and
    must never move into research: the moment one customer's history shapes
    the findings, those findings stop being shareable and the whole split
    collapses. Findings are common; memory is personal.
    """
    depth = depth if depth in _DEPTH_WORDS else "standard"
    style = style if style in _STYLE_DESCRIPTIONS else "news"
    language_name = "Spanish" if language == "es" else "English"

    system_template, version = await get_active_prompt(
        db, "write_block",
        fallback_version=WRITE_BLOCK_VERSION, fallback_system_prompt=WRITE_BLOCK_SYSTEM,
    )
    system = system_template.format(
        style_description=_STYLE_DESCRIPTIONS[style],
        language=language_name,
        word_target=_DEPTH_WORDS[depth],
    )

    findings_json = json.dumps(
        [f.model_dump() for f in findings.findings], ensure_ascii=False, indent=2
    )
    user_content = (
        f"Topic: {topic}\n"
        f"What the person asked for, in their words: {raw_text}\n\n"
        f"Findings:\n{findings_json}"
    )
    if previously_told:
        # Newest first, matching told_log's own ordering, and labelled by
        # recency rather than by date: the model needs to know what came last,
        # not to recite calendar dates at the listener.
        history = "\n".join(f"- {summary}" for summary in previously_told)
        user_content += f"\n\nAlready told this listener (most recent first):\n{history}"

    def call(model: str):
        return _client.messages.create(
            model=model,
            max_tokens=4096,
            thinking={"type": "adaptive"},
            output_config={"effort": "medium"},
            system=system,
            messages=[{"role": "user", "content": user_content}],
        )

    result, cost = await _run_with_escalation(
        db, purpose="write_block", version=version, call=call, parse=_parse_block_result,
        customer_id=customer_id,
        context={"customer_id": str(customer_id), "request_id": str(request_id)},
    )
    result.cost = cost
    result.sources = _resolve_sources(result.sources, findings.sources)
    return result


def _resolve_sources(used: list, available: list[dict]) -> list[dict]:
    """
    Maps the writer's claimed source urls back onto the real source records
    research produced (already license-labeled), dropping anything it did not
    find there. A hallucinated url resolves to nothing rather than to a
    fabricated citation — "no source, no block" applied at the citation level.

    Tolerates the writer returning whole objects instead of bare url strings,
    which the prompt asks against but a model may still do.
    """
    by_url = {s.get("url"): s for s in available if s.get("url")}
    resolved: list[dict] = []
    for item in used:
        url = item.get("url") if isinstance(item, dict) else item
        source = by_url.get(url)
        if source and source not in resolved:
            resolved.append(source)
    return resolved


async def _run_with_escalation(db, *, purpose: str, version: str, call, parse,
                               customer_id: uuid.UUID, context: dict):
    """
    Runs `call` on the model `purpose` is routed to, and retries once on a
    stronger model if the answer could not be parsed.

    The retry trigger is deliberately narrow. It is not "the cheap model's
    answer looks weak" — nobody can judge that here, and a model that reports
    an honestly quiet day is giving the *correct* answer, which must not be
    second-guessed into a fabricated one. It is only `parse_failed`: the model
    returned something this code cannot read at all. That is unambiguous, it is
    rare, and before `parse_failed` existed it was silently indistinguishable
    from a quiet day, so a malformed response became an empty episode.

    Both attempts are logged as their own AICall rows with their own models and
    costs, so the dashboard shows what escalation actually costs rather than
    hiding the retry inside one row. The returned cost is the sum.
    """
    start = time.monotonic()
    # `call` stays an ordinary synchronous function — _invoke is what takes it
    # off the event loop and retries it. Keeping that here rather than inside
    # each closure means every escalating purpose gets both for free, and the
    # closures stay readable as "this is the request we send".
    response = await _invoke(call, model_for(purpose))
    latency_ms = int((time.monotonic() - start) * 1000)
    cost = await _log_call(
        db, customer_id=customer_id, prompt=purpose, version=version, purpose=purpose,
        usage=response.usage, latency_ms=latency_ms, context=context,
        model=model_for(purpose),
    )
    text = next((b.text for b in reversed(response.content) if b.type == "text"), "")
    result = parse(text)

    stronger = escalation_for(purpose)
    if not result.parse_failed or stronger is None:
        return result, cost

    logger.warning("ai_platform: %s returned unparseable output on %s, retrying on %s",
                   purpose, model_for(purpose), stronger)
    start = time.monotonic()
    retry = await _invoke(call, stronger)
    retry_latency_ms = int((time.monotonic() - start) * 1000)
    cost += await _log_call(
        db, customer_id=customer_id, prompt=purpose, version=version, purpose=purpose,
        usage=retry.usage, latency_ms=retry_latency_ms,
        context={**context, "escalated_from": model_for(purpose)},
        model=stronger,
    )
    retry_text = next((b.text for b in reversed(retry.content) if b.type == "text"), "")
    return parse(retry_text), cost


def _parse_findings(text: str) -> Findings:
    try:
        return Findings.model_validate_json(text)
    except Exception:
        pass
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if match:
        try:
            return Findings.model_validate(json.loads(match.group(0)))
        except Exception:
            pass
    # Model didn't return parseable JSON — treat as no_news rather than
    # writing from nothing (Generator tenet: "no source, no block"), and flag
    # it so the caller can retry on a stronger model instead of publishing an
    # empty day that nothing actually went wrong to produce.
    return Findings(findings=[], sources=[], no_news=True, parse_failed=True)


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
    # publishing garbage (Generator tenet: "no source, no block"), flagged so
    # the caller can retry on a stronger model.
    return BlockResult(summary="", script="", sources=[], no_news=True, parse_failed=True)


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
    response = await _invoke(
        _client.messages.parse,
        model=model_for("refine_request"),
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
