"""
Continuity between episodes — the product half of what the founder asked for.

"I want the cache as this is also good for the customer no? like having a
connection from the previous episode?"

The shared findings store makes episodes cheaper. This makes them feel like a
series: today's segment knows what this listener heard yesterday on the same
topic, so it can move the story forward instead of restarting it.

The asymmetry with the findings cache is the point and is load-bearing:
findings are SHARED across customers and keyed by topic; the told-log is PER
CUSTOMER and keyed by their own request. If one listener's history ever
reached the research half, findings would stop being shareable and the split
would collapse. Findings are common; memory is personal.

Run with (from backend/):
TEST_DATABASE_URL=postgresql+asyncpg://localhost:5432/lucaku_audio_test pytest tests/test_told_log.py
"""
import uuid
from datetime import date, datetime, timedelta, timezone

import pytest

from app.models.cliente import AuthProvider, Cliente
from app.models.episode import Block, Episode, EpisodePath
from app.models.request import CreatedFrom, Request, RequestKind, RequestStatus
from app.services import told_log


async def _customer(db) -> Cliente:
    c = Cliente(email=f"{uuid.uuid4()}@example.com", auth_provider=AuthProvider.email,
                hashed_password=None, nombre="T", idioma="es")
    db.add(c)
    await db.flush()
    return c


async def _request(db, cliente) -> Request:
    r = Request(customer_id=cliente.id, kind=RequestKind.standing, raw_text="markets",
                structured={}, status=RequestStatus.active, created_from=CreatedFrom.onboarding)
    db.add(r)
    await db.flush()
    return r


async def _episode_with_block(db, cliente, req, *, summary, days_ago=0,
                              published=True, no_news=False):
    when = datetime.now(timezone.utc) - timedelta(days=days_ago)
    ep = Episode(
        customer_id=cliente.id, shared=False, fecha=date.today() - timedelta(days=days_ago),
        path=EpisodePath.scheduled, language="es", style="news",
        audio_url="https://example.com/a.mp3" if published else None,
        published_at=when if published else None, cost={},
    )
    db.add(ep)
    await db.flush()
    db.add(Block(episode_id=ep.id, request_id=req.id, start_s=0, end_s=60,
                 summary=summary, script="...", sources=[], no_news=no_news))
    await db.flush()
    return ep


@pytest.mark.asyncio
async def test_previous_segments_come_back_newest_first(full_db_session):
    c = await _customer(full_db_session)
    r = await _request(full_db_session, c)
    await _episode_with_block(full_db_session, c, r, summary="Day one", days_ago=2)
    await _episode_with_block(full_db_session, c, r, summary="Day two", days_ago=1)

    told = await told_log.recent_for_request(full_db_session, customer_id=c.id, request_id=r.id)
    assert told == ["Day two", "Day one"]


@pytest.mark.asyncio
async def test_an_unpublished_episode_was_never_heard(full_db_session):
    """The correctness property this module exists around. An episode that
    died in voicing has finished scripts in the database and reached nobody.
    Counting it as 'told' would open tomorrow's episode with "yesterday we
    covered the rate decision" to a listener who heard silence."""
    c = await _customer(full_db_session)
    r = await _request(full_db_session, c)
    await _episode_with_block(full_db_session, c, r, summary="Never aired",
                              days_ago=1, published=False)

    told = await told_log.recent_for_request(full_db_session, customer_id=c.id, request_id=r.id)
    assert told == [], "an episode that was never published was treated as heard"


@pytest.mark.asyncio
async def test_a_quiet_day_is_not_something_they_were_told(full_db_session):
    c = await _customer(full_db_session)
    r = await _request(full_db_session, c)
    await _episode_with_block(full_db_session, c, r, summary="", days_ago=1, no_news=True)

    assert await told_log.recent_for_request(
        full_db_session, customer_id=c.id, request_id=r.id
    ) == []


@pytest.mark.asyncio
async def test_continuity_does_not_cross_topics(full_db_session):
    """Carrying yesterday's football into today's markets segment would be
    noise, and would spend tokens producing it."""
    c = await _customer(full_db_session)
    markets = await _request(full_db_session, c)
    football = await _request(full_db_session, c)
    await _episode_with_block(full_db_session, c, football, summary="Arsenal won", days_ago=1)

    assert await told_log.recent_for_request(
        full_db_session, customer_id=c.id, request_id=markets.id
    ) == []


@pytest.mark.asyncio
async def test_continuity_does_not_cross_customers(full_db_session):
    """Memory is personal. One listener's history must never surface in
    another's episode — that is the line the findings cache deliberately
    does not cross either."""
    a, b = await _customer(full_db_session), await _customer(full_db_session)
    req_a = await _request(full_db_session, a)
    await _episode_with_block(full_db_session, a, req_a, summary="A's briefing", days_ago=1)

    assert await told_log.recent_for_request(
        full_db_session, customer_id=b.id, request_id=req_a.id
    ) == []


@pytest.mark.asyncio
async def test_history_is_capped(full_db_session):
    """Unbounded history would cost tokens on every block and dilute today's
    findings with last month's."""
    c = await _customer(full_db_session)
    r = await _request(full_db_session, c)
    for i in range(6):
        await _episode_with_block(full_db_session, c, r, summary=f"Day {i}", days_ago=6 - i)

    told = await told_log.recent_for_request(full_db_session, customer_id=c.id, request_id=r.id)
    assert len(told) == told_log.DEFAULT_LIMIT


@pytest.mark.asyncio
async def test_an_intro_block_has_no_history(full_db_session):
    c = await _customer(full_db_session)
    assert await told_log.recent_for_request(
        full_db_session, customer_id=c.id, request_id=None
    ) == []
