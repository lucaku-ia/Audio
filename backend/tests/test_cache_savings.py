"""
The cache-savings endpoint.

The findings store's value was argued from design: research is the expensive
half, customers overlap on topics, therefore it pays. This endpoint reports
whether that is true in the data — an unmeasured cache is indistinguishable
from a cache that never hits.

Run with (from backend/):
TEST_DATABASE_URL=postgresql+asyncpg://localhost:5432/lucaku_audio_test pytest tests/test_cache_savings.py
"""
from datetime import datetime, timedelta, timezone

import pytest

from app.api.routes.instrumentation import cache_savings
from app.models.findings_cache import FindingsCache
from app.services.findings_store import EMPTY_TTL, FRESH_TTL


def _entry(topic, *, hits=0, cost=0.43, no_news=False, age=timedelta(0)):
    return FindingsCache(
        topic_key=topic, scope_key="", geography_key="",
        payload={"findings": [], "sources": [], "no_news": no_news},
        no_news=no_news, original_cost=cost, hit_count=hits,
        creado_en=datetime.now(timezone.utc) - age,
    )


@pytest.mark.asyncio
async def test_an_empty_cache_reports_zero_not_an_error(full_db_session):
    out = await cache_savings(db=full_db_session)
    assert out.entries == 0 and out.hits == 0
    assert out.estimated_saved == 0.0
    assert out.hit_rate == 0.0


@pytest.mark.asyncio
async def test_savings_are_hits_times_what_that_research_cost(full_db_session):
    full_db_session.add(_entry("premier league", hits=3, cost=0.40))
    full_db_session.add(_entry("colombian politics", hits=1, cost=0.60))
    await full_db_session.flush()

    out = await cache_savings(db=full_db_session)

    assert out.entries == 2
    assert out.hits == 4
    assert out.research_calls_avoided == 4
    assert out.estimated_saved == pytest.approx(3 * 0.40 + 1 * 0.60)


@pytest.mark.asyncio
async def test_hit_rate_compares_avoided_calls_against_paid_ones(full_db_session):
    full_db_session.add(_entry("a", hits=3, cost=0.4))
    await full_db_session.flush()
    out = await cache_savings(db=full_db_session)
    assert out.hit_rate == pytest.approx(3 / 4)  # 3 avoided, 1 paid


@pytest.mark.asyncio
async def test_expired_entries_are_counted_but_not_called_live(full_db_session):
    """An entry that exists but can no longer be served is still a record of
    research that was paid for — it just cannot save anyone anything now."""
    full_db_session.add(_entry("fresh", hits=1))
    full_db_session.add(_entry("stale", hits=1, age=FRESH_TTL + timedelta(minutes=1)))
    full_db_session.add(_entry("stale empty", hits=1, no_news=True,
                               age=EMPTY_TTL + timedelta(minutes=1)))
    await full_db_session.flush()

    out = await cache_savings(db=full_db_session)
    assert out.entries == 3
    assert out.live_entries == 1


@pytest.mark.asyncio
async def test_top_topics_show_where_customers_actually_overlap(full_db_session):
    full_db_session.add(_entry("premier league", hits=9, cost=0.4))
    full_db_session.add(_entry("niche topic", hits=0, cost=0.4))
    await full_db_session.flush()

    out = await cache_savings(db=full_db_session)

    assert [t["topic"] for t in out.top_shared_topics] == ["premier league"]
    assert out.top_shared_topics[0]["hits"] == 9
