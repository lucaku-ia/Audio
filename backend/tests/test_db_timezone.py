"""
Pins the DB session timezone to UTC.

This codebase stores every timestamp as naive datetime.utcnow() into columns
declared DateTime(timezone=True). Postgres reads a naive value as the
SESSION's timezone and converts it to UTC, so that convention is correct only
while the session timezone IS UTC — and it is not by default. This machine's
Postgres reports America/Los_Angeles, which stored a row stamped "now" eight
hours in the future and made every age computed against utcnow() negative.

Nothing about that failure is loud. A clock that reads eight hours ahead
doesn't raise; it makes freshness checks, the late-job watchdog, token expiry
and the login rate limiter quietly wrong in whichever direction the offset
points, while every test that never round-trips through Postgres keeps
passing. These tests are the round-trip.

Run with (from backend/):
TEST_DATABASE_URL=postgresql+asyncpg://localhost:5432/lucaku_audio_test pytest tests/test_db_timezone.py
"""
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select, text

from app.models.findings_cache import FindingsCache


@pytest.mark.asyncio
async def test_the_session_timezone_is_utc(db_session):
    tz = (await db_session.execute(text("SHOW timezone"))).scalar()
    assert tz == "UTC", (
        f"DB session timezone is {tz!r}. Every naive utcnow() this codebase "
        "stores will be reinterpreted in that zone and shifted on the way in."
    )


@pytest.mark.asyncio
async def test_a_naive_utcnow_round_trips_to_the_same_instant(full_db_session):
    """The property that actually matters: what the app writes with utcnow()
    must come back meaning the same moment, not shifted by the machine's
    offset. Without the UTC pin this fails by hours, in whichever direction
    the developer happens to live."""
    stamped = datetime.utcnow()
    full_db_session.add(FindingsCache(
        topic_key="tz-probe", scope_key="", geography_key="",
        payload={"findings": [], "sources": [], "no_news": False},
        no_news=False, creado_en=stamped,
    ))
    await full_db_session.flush()
    full_db_session.expire_all()  # force a real read back, not the identity map

    row = (await full_db_session.execute(
        select(FindingsCache).where(FindingsCache.topic_key == "tz-probe")
    )).scalar_one()

    read_back_utc = row.creado_en.astimezone(timezone.utc).replace(tzinfo=None)
    drift = abs(read_back_utc - stamped)
    assert drift < timedelta(seconds=1), (
        f"a naive utcnow() came back shifted by {drift} — the session timezone "
        "is not UTC, so stored times do not mean what the code thinks"
    )


@pytest.mark.asyncio
async def test_a_freshly_stored_row_is_not_in_the_future(full_db_session):
    """The specific symptom that hid the findings-cache expiry bug: rows
    stamped 'now' landed in the future, so every age was negative and nothing
    ever expired — while looking like it worked perfectly."""
    full_db_session.add(FindingsCache(
        topic_key="tz-future-probe", scope_key="", geography_key="",
        payload={"findings": [], "sources": [], "no_news": False}, no_news=False,
    ))
    await full_db_session.flush()
    full_db_session.expire_all()

    row = (await full_db_session.execute(
        select(FindingsCache).where(FindingsCache.topic_key == "tz-future-probe")
    )).scalar_one()

    age = datetime.now(timezone.utc) - row.creado_en.astimezone(timezone.utc)
    assert age >= timedelta(0), f"a row stamped 'now' is {-age} in the future"
