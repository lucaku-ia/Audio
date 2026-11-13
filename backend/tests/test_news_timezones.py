"""News slots per customer timezone: local 05:00/13:00 bands, local dates,
dedupe on (topic, date, slot), UTC fallback. Fakes only; see tests/news_helpers.py."""
from datetime import date, datetime, timezone

import pytest
from sqlalchemy import select

from app.models.news import NewsRun
from app.models.profile import Profile
from app.services import news_pipeline as np_
from tests.news_helpers import make_customer, patch_news_ai

TOPIC = "Premier League"


def utc(day, hour, minute=0):
    return datetime(2026, 11, day, hour, minute, tzinfo=timezone.utc)


async def _follower(db, tz: str | None, topic: str = TOPIC):
    cliente = await make_customer(db, topic=topic)
    if tz is not None:
        db.add(Profile(customer_id=cliente.id, delivery_timezone=tz))
        await db.commit()
    return cliente


async def _keys(db):
    runs = (await db.execute(select(NewsRun))).scalars().all()
    return sorted((r.topic_key, r.run_date, r.slot) for r in runs)


@pytest.mark.asyncio
async def test_bogota_and_madrid_get_their_own_local_slot(full_db_session, monkeypatch):
    db = full_db_session
    await _follower(db, "America/Bogota")
    await _follower(db, "Europe/Madrid")
    rec = patch_news_ai(monkeypatch)

    # 12:30 UTC = 07:30 Bogota (0500 band) and 13:30 Madrid (1300 band).
    await np_.run_scheduled_slot(db, now=utc(12, 12, 30))

    key = np_.normalize(TOPIC)
    assert await _keys(db) == [(key, date(2026, 11, 12), "0500"), (key, date(2026, 11, 12), "1300")]
    assert len(rec.research_calls) == 2


@pytest.mark.asyncio
async def test_run_date_is_the_local_date_of_the_zone(full_db_session, monkeypatch):
    db = full_db_session
    await _follower(db, "America/Bogota")
    await _follower(db, "Pacific/Auckland")
    patch_news_ai(monkeypatch)

    # 23:30 UTC Nov 12 = 18:30 Bogota Nov 12 (1300) and 12:30 Auckland Nov 13 (0500).
    await np_.run_scheduled_slot(db, now=utc(12, 23, 30))

    key = np_.normalize(TOPIC)
    assert await _keys(db) == [(key, date(2026, 11, 12), "1300"), (key, date(2026, 11, 13), "0500")]


@pytest.mark.asyncio
async def test_fifty_customers_in_one_timezone_research_once(full_db_session, monkeypatch):
    db = full_db_session
    for _ in range(50):
        await _follower(db, "America/Bogota")
    rec = patch_news_ai(monkeypatch)

    summary = await np_.run_scheduled_slot(db, now=utc(12, 12, 0))
    again = await np_.run_scheduled_slot(db, now=utc(12, 12, 10))  # next tick

    assert summary["topics"] == 1 and len(rec.research_calls) == 1 and len(rec.write_calls) == 1
    assert again["skipped"] == 1 and len(rec.research_calls) == 1


@pytest.mark.asyncio
async def test_quiet_local_hours_schedule_nothing(full_db_session, monkeypatch):
    db = full_db_session
    await _follower(db, "America/Bogota")
    rec = patch_news_ai(monkeypatch)

    # 07:00 UTC = 02:00 Bogota (quiet), even though 07:00 UTC is a morning band in UTC.
    summary = await np_.run_scheduled_slot(db, now=utc(12, 7, 0))

    assert summary["topics"] == 0 and summary["slots"] == []
    assert rec.research_calls == [] and await _keys(db) == []


@pytest.mark.asyncio
async def test_zones_landing_on_the_same_date_and_slot_run_once(full_db_session, monkeypatch):
    db = full_db_session
    await _follower(db, "America/Bogota")
    await _follower(db, "Europe/Madrid")
    await _follower(db, "America/Mexico_City")
    rec = patch_news_ai(monkeypatch)

    # 11:00 UTC = 06:00 Bogota, 12:00 Madrid, 05:00 Mexico City: all 0500 on Nov 12.
    summary = await np_.run_scheduled_slot(db, now=utc(12, 11, 0))

    assert summary["topics"] == 1 and len(rec.research_calls) == 1
    assert await _keys(db) == [(np_.normalize(TOPIC), date(2026, 11, 12), "0500")]


@pytest.mark.asyncio
async def test_invalid_or_missing_timezone_falls_back_to_utc(full_db_session, monkeypatch):
    db = full_db_session
    await _follower(db, "Mars/Olympus_Mons", topic="Premier League")
    await _follower(db, None, topic="Federal Reserve")  # no Profile row at all
    rec = patch_news_ai(monkeypatch)

    await np_.run_scheduled_slot(db, now=utc(12, 6, 0))  # 06:00 UTC -> 0500 for UTC

    assert sorted(k[1:] for k in await _keys(db)) == [(date(2026, 11, 12), "0500")] * 2
    assert len(rec.research_calls) == 2


def test_resolve_tz_and_local_slot_helpers():
    assert np_.resolve_tz("nope/zone")[0] == "UTC" and np_.resolve_tz(None)[0] == "UTC"
    assert np_.resolve_tz("America/Bogota")[0] == "America/Bogota"
    assert np_.local_slot(utc(12, 9, 59), "America/Bogota") is None  # 04:59 local
    assert np_.local_slot(utc(12, 10, 0), "America/Bogota") == ("0500", date(2026, 11, 12))
    assert np_.local_slot(utc(12, 18, 0), "America/Bogota") == ("1300", date(2026, 11, 12))
    assert np_.local_slot(utc(12, 6, 0), "bad") == ("0500", date(2026, 11, 12))
