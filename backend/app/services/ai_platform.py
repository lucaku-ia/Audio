"""
AI Platform PRD (Andrés + Juan, Draft v1) — the one door every model call
goes through.

Scope note: this implements step 1 of the PRD's own delivery order (§9):
"Call wrapper with cost telemetry — unblocks Onboarding and Request
Management." Everything else in the PRD (a full prompt registry, the
shared semantic index for Home/Search, evals, multi-provider fallback,
budgets/rate limits, TTS synthesize()) is deliberately deferred — each
needs the epic that consumes it (Generator, Home, Search) to exist first.

Tenets followed here:
- How, never what: this module doesn't decide whether a request is worth
  pursuing, only whether it's safe and how to structure it. Callers
  (Request Management, Onboarding) decide what to do with a rejection.
- Every call has an id and a cost: every call writes an AICall row
  (app/models/instrumentation.py), matching the existing Instrumentation
  catalog.
- Prompts are versioned artifacts: STRUCTURE_REQUEST_VERSION is bumped
  whenever STRUCTURE_REQUEST_SYSTEM changes.
"""
import time
import uuid
from datetime import datetime

import anthropic
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.instrumentation import AICall

_client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from the environment

MODEL = "claude-opus-5"
PROVIDER = "anthropic"

# Per-1M-token prices (USD) — PRD §5: "per-provider price tables in config;
# cost computed at call time." Update here if pricing changes.
_PRICE_PER_1M = {"claude-opus-5": {"input": 5.00, "output": 25.00}}


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
    prices = _PRICE_PER_1M.get(MODEL, {"input": 0.0, "output": 0.0})
    cost = (response.usage.input_tokens / 1_000_000) * prices["input"] + (
        response.usage.output_tokens / 1_000_000
    ) * prices["output"]

    db.add(AICall(
        call_id=uuid.uuid4(),
        prompt="structure_request",
        version=STRUCTURE_REQUEST_VERSION,
        purpose="structure_request",
        model=MODEL,
        provider=PROVIDER,
        tokens_in=response.usage.input_tokens,
        tokens_out=response.usage.output_tokens,
        cost=cost,
        latency_ms=latency_ms,
        context={"customer_id": str(customer_id), "request_id": str(request_id) if request_id else None},
        rejected_reason=result.rejected_reason,
        creado_en=datetime.utcnow(),
    ))

    return result
