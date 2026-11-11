"""
Tests for the shared findings store.

The founder's requirement, in his words: "if 2 people are researching for
same thing, then the info is there and no need to research again" — and,
emphatically, "I don't want the same podcast for everyone. never." So the
contract under test is: research is shared, episodes are not.

Most of these are about when caching is WRONG. A cache that only ever
returns hits is easy; the failure modes that matter are serving stale news,
serving a quiet-day answer after the news broke, and persisting a parse
failure so one bad model response becomes everyone's.

Run with (from backend/):
TEST_DATABASE_URL=postgresql+asyncpg://localhost:5432/lucaku_audio_test pytest tests/test_findings_store.py
"""
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select, update

from app.models.findings_cache import FindingsCache
from app.services import findings_store
from app.services.findings_store import EMPTY_TTL, FRESH_TTL, normalize


def _payload(headline: str = "Something happened") -> dict:
    return {
        "findings": [{"headline": headline, "detail": "Detail.", "source_urls": ["https://example.com"]}],
        "sources": [{"url": "https://example.com", "title": "A story"}],
        "no_news": False,
    }


async def _store(db, *, topic="Premier League", scope="results", geography=None,
                 payload=None, no_news=False, cost=0.43, age=timedelta(0)):
    await findings_store.store(
        db, topic=topic, scope=scope, geography=geography,
        payload=payload or _payload(), no_news=no_news,
        researched_from="how did the title race go", cost=cost,
    )
    await db.flush()
    if age:
        # Backdate through the table, not the ORM object: store() may have
        # just assigned creado_en on an existing instance, and re-assigning
        # it on the same in-session object is easy to get silently wrong.
        # Aware UTC, and forced back through Postgres — a naive value here
        # would be reinterpreted in the session timezone, and reading from
        # the identity map instead of the DB would hide that entirely. Both
        # of those masked a real expiry bug in this module once already.
        await db.execute(
            update(FindingsCache).values(creado_en=datetime.now(timezone.utc) - age)
        )
        db.expire_all()


# --------------------------------------------------------------------------
# Normalization — a false MISS costs one research call; a false HIT serves a
# customer findings about something they did not ask about.
# --------------------------------------------------------------------------

def test_casing_and_whitespace_collapse_to_one_entry():
    assert normalize("Premier League") == normalize("  premier   league ") == "premier league"


def test_accents_fold_because_customers_write_in_spanish():
    assert normalize("Elecciones Bogotá") == normalize("elecciones bogota")


def test_different_topics_do_not_collide():
    assert normalize("Premier League") != normalize("Champions League")


def test_missing_optional_parts_normalize_to_empty_string_not_none():
    # NULL != NULL in Postgres, so a nullable key column silently stops
    # deduplicating. The store must never write None into a key part.
    assert normalize(None) == ""


# --------------------------------------------------------------------------
# Hit / miss
# --------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_a_second_customer_asking_the_same_thing_gets_a_hit(full_db_session):
    await _store(full_db_session, topic="Premier League", scope="results")

    hit = await findings_store.lookup(
        full_db_session, topic="  PREMIER league ", scope="results", geography=None
    )
    assert hit is not None, "the same topic worded differently missed the cache"
    assert hit.payload["findings"][0]["headline"] == "Something happened"


@pytest.mark.asyncio
async def test_a_different_topic_is_a_miss(full_db_session):
    await _store(full_db_session, topic="Premier League")
    assert await findings_store.lookup(
        full_db_session, topic="Colombian politics", scope="results", geography=None
    ) is None


@pytest.mark.asyncio
async def test_geography_is_part_of_the_key(full_db_session):
    """"Local news" for Bogotá and for Madrid are not the same research."""
    await _store(full_db_session, topic="local news", scope="", geography="Bogota")
    assert await findings_store.lookup(
        full_db_session, topic="local news", scope="", geography="Madrid"
    ) is None


# --------------------------------------------------------------------------
# Freshness — the part that actually matters
# --------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_stale_findings_are_a_miss(full_db_session):
    await _store(full_db_session, age=FRESH_TTL + timedelta(minutes=1))
    assert await findings_store.lookup(
        full_db_session, topic="Premier League", scope="results", geography=None
    ) is None, "served research older than its freshness window"


@pytest.mark.asyncio
async def test_an_empty_result_expires_much_sooner_than_a_full_one(full_db_session):
    """A quiet topic at 7am can be the day's big story by 10am. Caching
    'nothing happened' for hours would reintroduce the empty-day lockout
    that PR #31 just fixed, by the back door."""
    assert EMPTY_TTL < FRESH_TTL

    await _store(full_db_session, payload={"findings": [], "sources": [], "no_news": True},
                 no_news=True, age=EMPTY_TTL + timedelta(minutes=1))

    assert await findings_store.lookup(
        full_db_session, topic="Premier League", scope="results", geography=None
    ) is None, "a stale 'no news' locked out a topic that may since have news"


@pytest.mark.asyncio
async def test_a_recent_empty_result_is_still_a_hit(full_db_session):
    """Short, but not zero — otherwise a quiet topic is re-researched by
    every customer in the same minute."""
    await _store(full_db_session, payload={"findings": [], "sources": [], "no_news": True},
                 no_news=True, age=EMPTY_TTL / 2)
    assert await findings_store.lookup(
        full_db_session, topic="Premier League", scope="results", geography=None
    ) is not None


# --------------------------------------------------------------------------
# Bookkeeping and upsert
# --------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_re_storing_replaces_rather_than_duplicates(full_db_session):
    await _store(full_db_session)
    await _store(full_db_session, payload=_payload("Something else happened"))

    rows = (await full_db_session.execute(select(FindingsCache))).scalars().all()
    assert len(rows) == 1, "the same key accumulated duplicate rows"
    assert rows[0].payload["findings"][0]["headline"] == "Something else happened"


@pytest.mark.asyncio
async def test_re_storing_restarts_the_freshness_window(full_db_session):
    await _store(full_db_session, age=FRESH_TTL + timedelta(minutes=1))
    await _store(full_db_session)  # fresh research for the same key
    assert await findings_store.lookup(
        full_db_session, topic="Premier League", scope="results", geography=None
    ) is not None


@pytest.mark.asyncio
async def test_hits_are_counted_so_the_saving_is_measurable(full_db_session):
    await _store(full_db_session, cost=0.43)
    row = await findings_store.lookup(
        full_db_session, topic="Premier League", scope="results", geography=None
    )
    await findings_store.record_hit(full_db_session, row)
    await findings_store.record_hit(full_db_session, row)

    assert row.hit_count == 2
    assert row.last_hit_at is not None
    assert row.original_cost == 0.43  # what each of those hits avoided paying


@pytest.mark.asyncio
async def test_nothing_customer_specific_is_stored(full_db_session):
    """If customer_id, style, language or depth ever reach this table, the
    research/write split has been undone and episodes stop being bespoke."""
    await _store(full_db_session)
    row = (await full_db_session.execute(select(FindingsCache))).scalars().one()

    columns = set(FindingsCache.__table__.columns.keys())
    for forbidden in ("customer_id", "style", "language", "depth", "voice_id"):
        assert forbidden not in columns, f"{forbidden} must never be part of shared research"
    assert "style" not in row.payload and "language" not in row.payload
