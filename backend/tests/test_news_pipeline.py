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

    patch_news_ai(monkeypatch)
    retry = await np_.run_news_for_topic(full_db_session, "Premier League", slot="0500", now=NOW)
    assert retry.status == "done"


@pytest.mark.asyncio
async def test_quiet_day_publishes_nothing(full_db_session, monkeypatch):
    rec = patch_news_ai(monkeypatch, found=findings(no_news=True))
    result = await np_.run_news_for_topic(full_db_session, "Premier League", slot="0500", now=NOW)
    assert result.status == "no_news" and rec.write_calls == []


def test_slot_bands():
    assert np_.slot_for(datetime(2026, 11, 12, 4, 59, tzinfo=timezone.utc)) is None
    assert np_.slot_for(datetime(2026, 11, 12, 5, 0, tzinfo=timezone.utc)) == "0500"
    assert np_.slot_for(datetime(2026, 11, 12, 13, 0, tzinfo=timezone.utc)) == "1300"
