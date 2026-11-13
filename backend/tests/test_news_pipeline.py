"""News pipeline: caps, grounding, summary length, cost independence, idempotency.
Fakes only; see tests/news_helpers.py."""
from datetime import datetime, timezone

import pytest
from sqlalchemy import select

from app.models.news import NewsItem, NewsRun
from app.services import ai_platform
from app.services import news_pipeline as np_
from tests.news_helpers import NOW, draft, findings, make_customer, patch_news_ai


async def _items(db):
    return (await db.execute(select(NewsItem))).scalars().all()


@pytest.mark.asyncio
async def test_writes_at_most_three_items(full_db_session, monkeypatch):
    heads = ["Striker signs record contract", "Stadium roof collapses during storm", "Manager sacked after defeat",
             "Referee suspended over error", "Fixture list changes for winter"]
    drafts = [draft(title=h, urls=(f"https://example.com/{i}",)) for i, h in enumerate(heads)]
    patch_news_ai(monkeypatch, found=findings(heads), drafts=drafts)

    result = await np_.run_news_for_topic(full_db_session, "Premier League", slot="0500", now=NOW)

    assert result.status == "done"
    assert len(await _items(full_db_session)) == 3


@pytest.mark.asyncio
async def test_item_without_a_grounded_source_is_rejected(full_db_session, monkeypatch):
    drafts = [
        draft(title="No sources at all", urls=()),
        draft(title="Invented source only", urls=("https://made-up.example/x",)),
        draft(title="Properly sourced story", urls=("https://example.com/0", "https://made-up.example/x")),
    ]
    patch_news_ai(monkeypatch, found=findings(["Properly sourced story"]), drafts=drafts)

    await np_.run_news_for_topic(full_db_session, "Premier League", slot="0500", now=NOW)

    items = await _items(full_db_session)
    assert [i.title for i in items] == ["Properly sourced story"]
    assert items[0].sources == [{"name": "Source 0", "url": "https://example.com/0"}]  # invented url dropped


@pytest.mark.asyncio
async def test_summary_is_never_longer_than_70_chars(full_db_session, monkeypatch):
    long_summary = "This summary is far too long for two lines on a phone screen and keeps going and going"
    patch_news_ai(monkeypatch, drafts=[draft(summary=long_summary)])

    await np_.run_news_for_topic(full_db_session, "Premier League", slot="0500", now=NOW)

    (item,) = await _items(full_db_session)
    assert 0 < len(item.summary) <= np_.SUMMARY_MAX
    assert len(np_.clamp_summary("x" * 200)) <= 70


@pytest.mark.asyncio
async def test_fifty_followers_cost_one_research_and_one_write(full_db_session, monkeypatch):
    for _ in range(50):
        await make_customer(full_db_session, topic="Premier League")
    rec = patch_news_ai(monkeypatch)

    summary = await np_.run_scheduled_slot(full_db_session, now=NOW)

    assert summary["topics"] == 1  # 50 followers collapse to one topic
    assert len(rec.research_calls) == 1
    assert len(rec.write_calls) == 1
    assert len(await _items(full_db_session)) == 1


@pytest.mark.asyncio
async def test_rerun_of_the_same_topic_date_slot_is_a_noop(full_db_session, monkeypatch):
    rec = patch_news_ai(monkeypatch)

    first = await np_.run_news_for_topic(full_db_session, "Premier League", slot="0500", now=NOW)
    again = await np_.run_news_for_topic(full_db_session, "premier league ", slot="0500", now=NOW)

    assert first.status == "done" and again.status == "skipped"
    assert len(rec.research_calls) == 1
    assert len(await _items(full_db_session)) == 1
    runs = (await full_db_session.execute(select(NewsRun))).scalars().all()
    assert len(runs) == 1 and runs[0].status == "done"


@pytest.mark.asyncio
async def test_next_slot_runs_but_does_not_republish_the_same_story(full_db_session, monkeypatch):
    rec = patch_news_ai(monkeypatch)
    await np_.run_news_for_topic(full_db_session, "Premier League", slot="0500", now=NOW)

    later = await np_.run_news_for_topic(full_db_session, "Premier League", slot="1300", now=NOW.replace(hour=13))

    assert len(rec.research_calls) == 2  # a new slot is a new run
    assert later.status == "no_news"  # novelty check dropped the duplicate before the writer
    assert len(rec.write_calls) == 1
    assert len(await _items(full_db_session)) == 1


@pytest.mark.asyncio
async def test_near_duplicate_findings_are_clustered_before_writing(full_db_session, monkeypatch):
    rec = patch_news_ai(
        monkeypatch,
        found=findings(["Arsenal beat Spurs 2-1 in derby", "Arsenal beat Spurs 2-1 in the derby", "Fed holds rates steady"]),
    )
    await np_.run_news_for_topic(full_db_session, "Premier League", slot="0500", now=NOW)
    assert len(rec.write_calls[0]["findings"]) == 2


@pytest.mark.asyncio
async def test_failed_run_can_be_retried(full_db_session, monkeypatch):
    async def _boom(*a, **kw):
        raise RuntimeError("provider down")

    monkeypatch.setattr(ai_platform, "research_topic", _boom)
    with pytest.raises(RuntimeError):
        await np_.run_news_for_topic(full_db_session, "Premier League", slot="0500", now=NOW)
    run = (await full_db_session.execute(select(NewsRun))).scalar_one()
    assert run.status == "failed"

    # Immediately after a failure the backoff blocks a retry (see the backoff test below).
    patch_news_ai(monkeypatch)
    retry = await np_.run_news_for_topic(full_db_session, "Premier League", slot="0500", now=NOW)
    assert retry.status == "skipped"


@pytest.mark.asyncio
async def test_quiet_day_publishes_nothing(full_db_session, monkeypatch):
    rec = patch_news_ai(monkeypatch, found=findings(no_news=True))
    result = await np_.run_news_for_topic(full_db_session, "Premier League", slot="0500", now=NOW)
    assert result.status == "no_news" and rec.write_calls == []


def test_slot_bands():
    assert np_.slot_for(datetime(2026, 11, 12, 4, 59, tzinfo=timezone.utc)) is None
    assert np_.slot_for(datetime(2026, 11, 12, 5, 0, tzinfo=timezone.utc)) == "0500"
    assert np_.slot_for(datetime(2026, 11, 12, 13, 0, tzinfo=timezone.utc)) == "1300"


# --- claim / retry safety ---------------------------------------------------

from datetime import timedelta  # noqa: E402

from sqlalchemy import update  # noqa: E402

from app.models.findings_cache import FindingsCache  # noqa: E402


async def _age(db, minutes: int, **extra):
    await db.execute(update(NewsRun).values(
        updated_at=datetime.now(timezone.utc) - timedelta(minutes=minutes), **extra))
    await db.commit()


async def _run(db):
    return (await db.execute(select(NewsRun))).scalar_one()


@pytest.mark.asyncio
async def test_research_parse_failure_is_failed_publishes_nothing_and_is_not_cached(full_db_session, monkeypatch):
    async def _fake_run(db, *, purpose, version, call, parse, customer_id, context):
        return ai_platform.Findings(findings=[], sources=[], no_news=True, parse_failed=True), 0.4

    async def _identity(db, sources):
        return sources

    monkeypatch.setattr(ai_platform, "_run_with_escalation", _fake_run)
    monkeypatch.setattr(ai_platform, "attach_licenses", _identity)
    rec = patch_writer_only(monkeypatch)

    result = await np_.run_news_for_topic(full_db_session, "Premier League", slot="0500", now=NOW)

    assert result.status == "failed"
    assert await _items(full_db_session) == [] and rec.write_calls == []
    assert (await _run(full_db_session)).status == "failed"
    assert (await full_db_session.execute(select(FindingsCache))).scalars().all() == []


def patch_writer_only(monkeypatch):
    from tests.news_helpers import Recorder
    rec = Recorder()

    async def _write(*a, **kw):
        rec.write_calls.append(1)
        return ai_platform.NewsDrafts(items=[], cost=0.0)

    monkeypatch.setattr(ai_platform, "write_news_items", _write)
    return rec


@pytest.mark.asyncio
async def test_failed_retry_needs_backoff_and_is_capped(full_db_session, monkeypatch):
    db = full_db_session

    async def _boom(*a, **kw):
        raise RuntimeError("provider down")

    monkeypatch.setattr(ai_platform, "research_topic", _boom)
    with pytest.raises(RuntimeError):
        await np_.run_news_for_topic(db, "Premier League", slot="0500", now=NOW)
    assert (await _run(db)).attempts == 1

    # Inside the 45 min backoff: not re-claimed.
    await _age(db, 10)
    assert (await np_.run_news_for_topic(db, "Premier League", slot="0500", now=NOW)).status == "skipped"
    assert (await _run(db)).attempts == 1

    # Past backoff: retried (attempt 2 and 3 fail again), then the cap stops it.
    for expected in (2, 3):
        await _age(db, 60)
        with pytest.raises(RuntimeError):
            await np_.run_news_for_topic(db, "Premier League", slot="0500", now=NOW)
        assert (await _run(db)).attempts == expected
    await _age(db, 600)
    assert (await np_.run_news_for_topic(db, "Premier League", slot="0500", now=NOW)).status == "skipped"
    assert (await _run(db)).attempts == 3

    # After a backoff, a success on retry still works when under the cap.


@pytest.mark.asyncio
async def test_failed_run_succeeds_on_retry_after_backoff(full_db_session, monkeypatch):
    db = full_db_session

    async def _boom(*a, **kw):
        raise RuntimeError("provider down")

    monkeypatch.setattr(ai_platform, "research_topic", _boom)
    with pytest.raises(RuntimeError):
        await np_.run_news_for_topic(db, "Premier League", slot="0500", now=NOW)
    await _age(db, 60)
    patch_news_ai(monkeypatch)
    assert (await np_.run_news_for_topic(db, "Premier League", slot="0500", now=NOW)).status == "done"


@pytest.mark.asyncio
async def test_stale_running_is_reclaimed_once_and_fresh_running_is_not(full_db_session, monkeypatch):
    db = full_db_session
    key = np_.normalize("Premier League")
    first = await np_._claim_run(db, key, NOW.date(), "0500")
    assert first is not None

    # Fresh running claim held elsewhere: lost.
    assert await np_._claim_run(db, key, NOW.date(), "0500") is None

    # Stale running claim: exactly one of two successive claimers wins.
    await _age(db, 31)
    won = await np_._claim_run(db, key, NOW.date(), "0500")
    lost = await np_._claim_run(db, key, NOW.date(), "0500")
    assert won == first and lost is None
    assert (await _run(db)).attempts == 2


@pytest.mark.asyncio
async def test_daily_cost_ceiling_stops_the_slot(full_db_session, monkeypatch):
    db = full_db_session
    await make_customer(db, topic="Premier League")
    await make_customer(db, topic="Federal Reserve")
    rec = patch_news_ai(monkeypatch)
    db.add(NewsRun(topic_key="other", run_date=NOW.date(), slot="0500", status="done", cost=20.0))
    await db.commit()

    summary = await np_.run_scheduled_slot(db, now=NOW, ceiling=15.0)

    assert summary["ceiling_hit"] is True and rec.research_calls == []
