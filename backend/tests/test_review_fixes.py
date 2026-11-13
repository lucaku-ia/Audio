"""Regression tests for the combined-branch review fixes: DST-aware news days,
news cost accounting and the global daily ceiling, feedback vs manual pause,
and small endpoint hardening. Fakes only: nothing here reaches Anthropic."""
import logging
import uuid
from datetime import date, datetime, timedelta, timezone
from types import SimpleNamespace

import httpx
import pytest
from fastapi import FastAPI
from sqlalchemy import select, update

from app.api.deps import get_current_cliente
from app.api.routes import feedback as fb_routes
from app.api.routes import home, news, requests as req_routes
from app.db.session import get_db
from app.models.episode import Block, Episode, EpisodePath
from app.models.feedback import Feedback
from app.models.instrumentation import AICall
from app.models.news import NewsItem, NewsRun
from app.models.onboarding import OnboardingState
from app.models.profile import Profile
from app.models.request import Request, RequestStatus
from app.services import ai_platform
from app.services import news_pipeline as np_
from tests.news_helpers import NOW, draft, findings, make_customer, patch_news_ai


# --- 1. DST-aware day, identical in /home and /news --------------------------

@pytest.mark.asyncio
@pytest.mark.parametrize("tz,published,expected_day", [
    # New York left DST at 2026-11-01 06:00 UTC: 04:30 UTC is 00:30 EDT, Nov 1.
    # A fixed EST (-05:00) offset taken in November would say Oct 31.
    ("America/New_York", datetime(2026, 11, 1, 4, 30, tzinfo=timezone.utc), date(2026, 11, 1)),
    # Madrid left DST at 2026-10-25 01:00 UTC: Oct 24 22:30 UTC is 00:30 CEST, Oct 25.
    ("Europe/Madrid", datetime(2026, 10, 24, 22, 30, tzinfo=timezone.utc), date(2026, 10, 25)),
])
async def test_home_news_day_matches_news_endpoint_across_dst(full_db_session, monkeypatch, tz, published, expected_day):
    db = full_db_session
    monkeypatch.setattr(news, "_window_start", lambda: datetime(2026, 1, 1, tzinfo=timezone.utc))
    me = await make_customer(db, topic="Premier League")
    db.add(Profile(customer_id=me.id, delivery_timezone=tz))
    db.add(NewsItem(topic_key="premier league", category="sports", title="T", summary="s", short_version="s",
                    body="b", sources=[], published_at=published, slot="0500"))
    await db.commit()

    listed = await news.list_news(day=None, tz_offset_minutes=None, cursor=None, limit=30, scope="followed",
                                  cliente=me, db=db)
    out = await home.home(cliente=me, db=db)

    assert listed.items[0].day == expected_day
    assert out.news.items[0].day == listed.items[0].day == expected_day


# --- 2b. cost: web search surcharge, unknown model ---------------------------

def _usage(tin=1_000_000, tout=0, searches=None, as_dict=False):
    stu = None if searches is None else ({"web_search_requests": searches} if as_dict
                                         else SimpleNamespace(web_search_requests=searches))
    return SimpleNamespace(input_tokens=tin, output_tokens=tout, server_tool_use=stu)


def test_cost_adds_web_search_surcharge_and_reads_it_defensively():
    base = ai_platform._cost(_usage(), "claude-sonnet-5-5")
    assert base == pytest.approx(2.00)
    assert ai_platform._cost(_usage(searches=3), "claude-sonnet-5-5") == pytest.approx(2.03)
    assert ai_platform._cost(_usage(searches=3, as_dict=True), "claude-sonnet-5-5") == pytest.approx(2.03)
    assert ai_platform._cost(SimpleNamespace(input_tokens=1_000_000, output_tokens=0), "claude-sonnet-5-5") == pytest.approx(2.00)
    assert ai_platform._cost(_usage(searches="junk"), "claude-sonnet-5-5") == pytest.approx(2.00)


def test_unknown_model_is_priced_at_the_most_expensive_known_rate_and_logged(caplog):
    priciest = max(ai_platform._PRICE_PER_1M.values(), key=lambda p: p["input"] + p["output"])
    with caplog.at_level(logging.ERROR, logger=ai_platform.logger.name):
        cost = ai_platform._cost(_usage(tin=1_000_000, tout=1_000_000), "claude-future-9")
    assert cost == pytest.approx(priciest["input"] + priciest["output"]) and cost > 0
    assert any("claude-future-9" in r.getMessage() for r in caplog.records)


@pytest.mark.asyncio
async def test_logged_call_cost_is_nonzero_with_search_and_tagged_news(full_db_session):
    db = full_db_session
    cost = await ai_platform._log_call(
        db, customer_id=None, prompt="research_topic", version="v1", purpose="research_topic",
        usage=_usage(tin=50_000, tout=2_000, searches=3), latency_ms=5, context={"source": "news"},
    )
    await db.commit()
    row = (await db.execute(select(AICall))).scalar_one()
    expected = 50_000 / 1e6 * 2.00 + 2_000 / 1e6 * 10.00 + 0.03
    assert expected > 0
    assert cost == pytest.approx(expected) and float(row.cost) == pytest.approx(expected)
    assert row.context["source"] == "news"


# --- 2a. run cost accumulates and survives failures --------------------------

async def _run_row(db):
    # Plain column values: the pipeline's rollbacks/bulk updates expire ORM instances.
    return (await db.execute(select(NewsRun.status, NewsRun.cost, NewsRun.attempts))).one()


@pytest.mark.asyncio
async def test_research_cost_is_recorded_when_the_writer_fails_and_accumulates_on_retry(full_db_session, monkeypatch):
    db = full_db_session
    patch_news_ai(monkeypatch, found=findings())  # research costs 0.30, writer 0.02
    good_write = ai_platform.write_news_items
    state = {"fail": True}

    async def _flaky(*a, **kw):
        if state["fail"]:
            raise RuntimeError("writer down")
        return await good_write(*a, **kw)

    monkeypatch.setattr(ai_platform, "write_news_items", _flaky)

    with pytest.raises(RuntimeError):
        await np_.run_news_for_topic(db, "Premier League", slot="0500", now=NOW)
    run = await _run_row(db)
    assert run.status == "failed" and run.cost == pytest.approx(0.30)  # research spend not lost

    await db.execute(update(NewsRun).values(updated_at=datetime.now(timezone.utc) - timedelta(minutes=60)))
    await db.commit()
    state["fail"] = False
    result = await np_.run_news_for_topic(db, "Premier League", slot="0500", now=NOW)

    assert result.status == "done"
    run = await _run_row(db)
    assert run.attempts == 2 and run.cost == pytest.approx(0.30 + 0.30 + 0.02)  # added, not overwritten


@pytest.mark.asyncio
async def test_no_news_and_parse_failure_costs_are_recorded(full_db_session, monkeypatch):
    patch_news_ai(monkeypatch, found=findings(no_news=True))
    await np_.run_news_for_topic(full_db_session, "Premier League", slot="0500", now=NOW)
    assert (await _run_row(full_db_session)).cost == pytest.approx(0.30)


# --- 2c. one global daily ceiling, global max_topics -------------------------

def utc(day, hour, minute=0):
    return datetime(2026, 11, day, hour, minute, tzinfo=timezone.utc)


async def _follow(db, tz, topic, n=1):
    for _ in range(n):
        me = await make_customer(db, topic=topic)
        db.add(Profile(customer_id=me.id, delivery_timezone=tz))
    await db.commit()


@pytest.mark.asyncio
async def test_global_ceiling_stops_further_topics_across_timezone_groups(full_db_session, monkeypatch):
    db = full_db_session
    await _follow(db, "America/Bogota", "Premier League", n=2)  # 0500 group (12:30 UTC = 07:30 Bogota)
    await _follow(db, "Europe/Madrid", "Federal Reserve")        # 1300 group (13:30 Madrid)
    rec = patch_news_ai(monkeypatch)  # every research costs 0.30

    summary = await np_.run_scheduled_slot(db, now=utc(12, 12, 30), ceiling=0.30)

    assert summary["ceiling_hit"] is True
    assert rec.research_calls == ["Premier League"]  # the second group never started
    assert summary["topics"] == 1


@pytest.mark.asyncio
async def test_ceiling_counts_failed_run_spend(full_db_session, monkeypatch):
    db = full_db_session
    await _follow(db, "America/Bogota", "Premier League", n=2)
    await _follow(db, "America/Bogota", "Federal Reserve")
    patch_news_ai(monkeypatch)

    async def _boom(*a, **kw):
        raise RuntimeError("writer down")

    monkeypatch.setattr(ai_platform, "write_news_items", _boom)
    summary = await np_.run_scheduled_slot(db, now=utc(12, 12, 30), ceiling=0.30)

    assert summary["failed"] == 1 and summary["ceiling_hit"] is True  # research spend of the failure counted


@pytest.mark.asyncio
async def test_max_topics_is_global_and_finished_keys_do_not_starve_the_rest(full_db_session, monkeypatch):
    db = full_db_session
    await _follow(db, "America/Bogota", "Alpha League", n=3)   # 0500
    await _follow(db, "Europe/Madrid", "Beta League", n=2)     # 1300
    await _follow(db, "America/Bogota", "Gamma League", n=1)   # 0500
    rec = patch_news_ai(monkeypatch)
    now = utc(12, 12, 30)

    first = await np_.run_scheduled_slot(db, now=now, max_topics=2)
    assert first["topics"] == 2 and rec.research_calls == ["Alpha League", "Beta League"]

    # Next tick: the two finished keys are dropped BEFORE the cap, so Gamma runs.
    second = await np_.run_scheduled_slot(db, now=now, max_topics=2)
    assert rec.research_calls == ["Alpha League", "Beta League", "Gamma League"]
    assert second["topics"] == 1 and second["skipped"] == 2


# --- 3. feedback pause / manual resume / manual re-pause / toggle off -------

@pytest.mark.asyncio
async def test_manual_pause_survives_feedback_toggle_off_after_resume_and_repause(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="x")
    req = (await db.execute(select(Request).where(Request.customer_id == me.id))).scalars().first()
    ep = Episode(customer_id=me.id, shared=False, fecha=date(2026, 11, 12), path=EpisodePath.scheduled)
    db.add(ep)
    await db.flush()
    block = Block(episode_id=ep.id, request_id=req.id, start_s=0, end_s=30, summary="s", script="x")
    db.add(block)
    await db.commit()

    async def status():
        return (await db.get(Request, req.id, populate_existing=True)).status

    async def stop_topic():
        body = fb_routes.FeedbackIn(target_type="story", target_id=block.id, rating="not_quite", reasons=["stop_topic"])
        return await fb_routes.submit_feedback(body=body, cliente=me, db=db)

    await stop_topic()
    assert await status() == RequestStatus.paused
    await req_routes.reanudar_request(request_id=req.id, cliente=me, db=db)
    assert await status() == RequestStatus.active
    await req_routes.pausar_request(request_id=req.id, cliente=me, db=db)
    assert await status() == RequestStatus.paused

    await stop_topic()  # same payload again: toggles the feedback off
    assert await status() == RequestStatus.paused  # the manual pause is the user's, not feedback's
    assert (await db.execute(select(Feedback))).scalars().all() == []


# --- 4. GET /feedback bounds target_ids --------------------------------------

@pytest.mark.asyncio
async def test_get_feedback_rejects_oversized_target_ids(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="x")
    app = FastAPI()
    app.include_router(fb_routes.router, prefix="/api")

    async def _me():
        return me

    async def _db():
        return db

    app.dependency_overrides[get_current_cliente] = _me
    app.dependency_overrides[get_db] = _db
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        too_long = ",".join(str(uuid.uuid4()) for _ in range(120))  # > 4000 chars
        assert len(too_long) > 4000
        assert (await c.get("/api/feedback", params={"target_type": "story", "target_ids": too_long})).status_code == 422
        ok = ",".join(str(uuid.uuid4()) for _ in range(100))  # at the 100-id cap and under 4000 chars
        assert (await c.get("/api/feedback", params={"target_type": "story", "target_ids": ok})).status_code == 200


# --- 5. /home fetches the shared inventory once ------------------------------

@pytest.mark.asyncio
async def test_home_queries_latest_shared_by_tag_once(full_db_session, monkeypatch):
    db = full_db_session
    me = await make_customer(db, topic="Premier League")
    db.add(OnboardingState(customer_id=me.id, selected_interests=["sports"]))
    await db.commit()
    calls = []
    real = home._latest_shared_by_tag

    async def _counting(session):
        calls.append(1)
        return await real(session)

    monkeypatch.setattr(home, "_latest_shared_by_tag", _counting)
    await home.home(cliente=me, db=db)
    assert len(calls) == 1


# --- 6. no invalid escape sequences in history.py ---------------------------

def test_history_has_no_invalid_escape_sequences():
    import warnings
    from pathlib import Path

    src = (Path(home.__file__).parent / "history.py").read_text(encoding="utf-8")
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        compile(src, "history.py", "exec")
