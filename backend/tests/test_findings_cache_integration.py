"""
End-to-end: does the cache actually stop the second customer paying for
research the first customer already did?

The unit tests in test_findings_store.py cover the store itself. This covers
the wiring — that research_topic consults it before calling a model, writes
through after, and that an episode built from cached findings is still
written fresh for its own listener.

The founder's constraint is the thing most worth protecting here: "I don't
want the same podcast for everyone. never." Shared facts, bespoke episodes.

Run with (from backend/):
TEST_DATABASE_URL=postgresql+asyncpg://localhost:5432/lucaku_audio_test pytest tests/test_findings_cache_integration.py
"""
import uuid

import pytest
from sqlalchemy import select

from app.models.findings_cache import FindingsCache
from app.services import ai_platform
from tests.fakes import fake_findings


async def _research(db, *, topic="Premier League", scope="results", raw_text="how did the title race go"):
    return await ai_platform.research_topic(
        db, raw_text=raw_text, topic=topic, scope=scope, geography=None,
        customer_id=uuid.uuid4(), request_id=uuid.uuid4(),
    )


def _count_model_calls(monkeypatch) -> list:
    """Replace the escalation runner — the single point every real model call
    for research goes through — and record each invocation."""
    calls: list = []

    async def _fake_run(db, *, purpose, version, call, parse, customer_id, context):
        calls.append(purpose)
        return fake_findings(), 0.43

    monkeypatch.setattr(ai_platform, "_run_with_escalation", _fake_run)
    monkeypatch.setattr(ai_platform, "attach_licenses", lambda db, s: _identity(s))
    return calls


async def _identity(sources):
    return sources


@pytest.mark.asyncio
async def test_the_second_customer_pays_nothing_for_the_same_research(full_db_session, monkeypatch):
    calls = _count_model_calls(monkeypatch)

    first = await _research(full_db_session)
    assert len(calls) == 1
    assert first.cost == 0.43

    # A different customer, different wording, same normalized topic.
    second = await _research(full_db_session, raw_text="give me the premier league title race")

    assert len(calls) == 1, "the second customer re-researched a topic already in the store"
    assert second.cost == 0.0, "a cache hit must be free, not merely cheaper"
    assert second.findings[0].headline == first.findings[0].headline


@pytest.mark.asyncio
async def test_a_different_topic_still_costs(full_db_session, monkeypatch):
    calls = _count_model_calls(monkeypatch)
    await _research(full_db_session, topic="Premier League")
    await _research(full_db_session, topic="Colombian politics")
    assert len(calls) == 2, "two genuinely different topics must both be researched"


@pytest.mark.asyncio
async def test_a_parse_failure_is_never_cached(full_db_session, monkeypatch):
    """A parse failure is a lost block, not a finding. Caching it would turn
    one malformed model response into every later customer's malformed
    response for the rest of the freshness window."""
    async def _fake_broken(db, *, purpose, version, call, parse, customer_id, context):
        broken = fake_findings(no_news=True)
        broken.parse_failed = True
        return broken, 0.43

    monkeypatch.setattr(ai_platform, "_run_with_escalation", _fake_broken)
    monkeypatch.setattr(ai_platform, "attach_licenses", lambda db, s: _identity(s))

    await _research(full_db_session)

    rows = (await full_db_session.execute(select(FindingsCache))).scalars().all()
    assert rows == [], "a parse failure was written to the shared cache"


@pytest.mark.asyncio
async def test_the_cache_holds_nothing_that_would_make_episodes_identical(full_db_session, monkeypatch):
    """The split's whole premise. If style/language/depth or a customer id
    ever reach the stored payload, two listeners start getting the same
    episode — which the founder ruled out explicitly."""
    _count_model_calls(monkeypatch)
    await _research(full_db_session)

    row = (await full_db_session.execute(select(FindingsCache))).scalars().one()
    serialized = str(row.payload)
    for forbidden in ("style", "language", "depth", "voice", "customer"):
        assert forbidden not in serialized.lower(), f"{forbidden} leaked into shared research"
