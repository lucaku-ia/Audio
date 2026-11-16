"""Feedback + signals. Real Postgres, no model calls; handlers are called directly
(repo convention) and the 401 check goes through a minimal ASGI app."""
import uuid
from datetime import date, datetime, timezone

import httpx
import pytest
from fastapi import FastAPI, HTTPException
from pydantic import ValidationError
from sqlalchemy import func, select

from app.api.routes import feedback as fb_routes
from app.models.episode import Block, Episode, EpisodePath
from app.models.feedback import Feedback, FeedbackSignal, ProblemReport
from app.models.instrumentation import Event
from app.models.news import NewsItem
from app.models.request import Request, RequestStatus
from tests.news_helpers import make_customer


async def _story(db, cliente, *, shared=False, owner=True):
    """An episode with one story block tied to a fresh request. Returns (block, request)."""
    req = (await db.execute(select(Request).where(Request.customer_id == cliente.id))).scalars().first()
    ep = Episode(customer_id=cliente.id if owner else None, shared=shared, fecha=date(2026, 11, 12),
                 path=EpisodePath.scheduled)
    db.add(ep)
    await db.flush()
    block = Block(episode_id=ep.id, request_id=req.id, start_s=0, end_s=30, summary="s", script="x")
    db.add(block)
    await db.commit()
    return block, req, ep


async def _send(db, cliente, target_type, target_id, rating, reasons=(), suggestion=None):
    body = fb_routes.FeedbackIn(target_type=target_type, target_id=target_id, rating=rating,
                                reasons=list(reasons), suggestion=suggestion)
    return await fb_routes.submit_feedback(body=body, cliente=cliente, db=db)


async def _signal(db, cliente, subject_type, key):
    return (await db.execute(select(FeedbackSignal).where(
        FeedbackSignal.cliente_id == cliente.id, FeedbackSignal.subject_type == subject_type,
        FeedbackSignal.subject_key == key)
        .execution_options(populate_existing=True))).scalar_one_or_none()


async def _count(db, model):
    return (await db.execute(select(func.count()).select_from(model))).scalar_one()


@pytest.mark.asyncio
async def test_requires_auth():
    app = FastAPI()
    app.include_router(fb_routes.router, prefix="/api")
    tid = "00000000-0000-0000-0000-000000000001"
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        for method, path, kw in [
            ("POST", "/api/feedback", {"json": {"target_type": "story", "target_id": tid, "rating": "useful"}}),
            ("GET", f"/api/feedback?target_type=story&target_ids={tid}", {}),
            ("POST", "/api/feedback/report", {"json": {"target_type": "story", "target_id": tid, "text": "x"}}),
        ]:
            assert (await c.request(method, path, **kw)).status_code == 401, (method, path)


@pytest.mark.asyncio
async def test_create_then_update_with_reasons_and_signals(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="Premier League")
    block, req, _ = await _story(db, me)

    out = await _send(db, me, "story", block.id, "not_quite", ["too_long", "too_long", "too_technical"], "  shorter please ")
    assert out.removed is False
    assert out.feedback.rating == "not_quite"
    assert out.feedback.reasons == ["too_long", "too_technical"] and out.feedback.suggestion == "shorter please"
    assert out.feedback.updated_at.tzinfo is not None

    sig = await _signal(db, me, "request", str(req.id))
    assert (sig.not_quite, sig.useful, sig.too_long, sig.too_technical, sig.score) == (1, 0, 1, 1, -1)

    # same rating, different reasons = update, not toggle: old contribution is replaced
    await _send(db, me, "story", block.id, "not_quite", ["too_short"])
    sig = await _signal(db, me, "request", str(req.id))
    assert (sig.not_quite, sig.too_long, sig.too_technical, sig.too_short, sig.score) == (1, 0, 0, 1, -1)
    assert await _count(db, Feedback) == 1


@pytest.mark.asyncio
async def test_useful_and_not_quite_are_exclusive(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="x")
    block, req, _ = await _story(db, me)

    await _send(db, me, "story", block.id, "useful")
    out = await _send(db, me, "story", block.id, "not_quite", ["not_relevant"])

    assert out.feedback.rating == "not_quite"
    assert await _count(db, Feedback) == 1
    sig = await _signal(db, me, "request", str(req.id))
    assert (sig.useful, sig.not_quite, sig.not_relevant, sig.score) == (0, 1, 1, -1)


@pytest.mark.asyncio
async def test_sending_same_rating_twice_toggles_off_and_reverses_signals(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="x")
    block, req, _ = await _story(db, me)

    await _send(db, me, "story", block.id, "useful")
    out = await _send(db, me, "story", block.id, "useful")

    assert out.removed is True and out.feedback is None
    assert await _count(db, Feedback) == 0
    sig = await _signal(db, me, "request", str(req.id))
    assert (sig.useful, sig.not_quite, sig.score) == (0, 0, 0)

    got = await fb_routes.get_feedback(target_type="story", target_ids=str(block.id), cliente=me, db=db)
    assert got == []

    # and a third send brings it back
    out = await _send(db, me, "story", block.id, "useful")
    assert out.removed is False and (await _signal(db, me, "request", str(req.id))).useful == 1


@pytest.mark.asyncio
async def test_signal_and_feedback_commit_together(full_db_session):
    """If the signal write fails, no Feedback row survives (single transaction)."""
    db = full_db_session
    me = await make_customer(db, topic="x")
    block, req, _ = await _story(db, me)

    orig = fb_routes._bump

    async def boom(*a, **k):
        raise RuntimeError("signal write failed")

    fb_routes._bump = boom
    try:
        with pytest.raises(RuntimeError):
            await _send(db, me, "story", block.id, "useful")
    finally:
        fb_routes._bump = orig
    await db.rollback()  # what the request-scoped session does when the handler raises

    assert await _count(db, Feedback) == 0 and await _count(db, FeedbackSignal) == 0


@pytest.mark.asyncio
async def test_stop_topic_pauses_request_and_toggle_off_resumes(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="x")
    block, req, _ = await _story(db, me)

    await _send(db, me, "story", block.id, "not_quite", ["stop_topic"])
    assert (await db.get(Request, req.id, populate_existing=True)).status == RequestStatus.paused
    assert (await _signal(db, me, "request", str(req.id))).stop_topic == 1

    await _send(db, me, "story", block.id, "not_quite", ["stop_topic"])  # toggle off
    assert (await db.get(Request, req.id, populate_existing=True)).status == RequestStatus.active
    assert (await _signal(db, me, "request", str(req.id))).stop_topic == 0


@pytest.mark.asyncio
async def test_stop_topic_does_not_resume_a_request_the_user_paused_themselves(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="x")
    block, req, _ = await _story(db, me)
    req.status = RequestStatus.paused
    await db.commit()

    await _send(db, me, "story", block.id, "not_quite", ["stop_topic"])
    await _send(db, me, "story", block.id, "not_quite", ["stop_topic"])  # off

    assert (await db.get(Request, req.id, populate_existing=True)).status == RequestStatus.paused


@pytest.mark.asyncio
async def test_episode_and_news_targets(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="x")
    block, req, ep = await _story(db, me)
    item = NewsItem(topic_key="premier league", category="sports", title="T", summary="S", short_version="s",
                    body="b", sources=[], published_at=datetime.now(timezone.utc), slot="0500")
    db.add(item)
    await db.commit()

    await _send(db, me, "episode", ep.id, "useful")
    assert (await _signal(db, me, "request", str(req.id))).useful == 1

    await _send(db, me, "news", item.id, "not_quite", ["not_relevant"])
    sig = await _signal(db, me, "topic", "premier league")
    assert (sig.not_quite, sig.not_relevant) == (1, 1)


@pytest.mark.asyncio
async def test_get_returns_saved_state_only_for_the_caller(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="x")
    other = await make_customer(db, topic="x")
    block, _, ep = await _story(db, me, shared=True)

    await _send(db, me, "story", block.id, "useful")
    await _send(db, other, "story", block.id, "not_quite")  # shared episode: visible to others

    mine = await fb_routes.get_feedback(target_type="story", target_ids=f"{block.id},{uuid.uuid4()}", cliente=me, db=db)
    assert [(f.target_id, f.rating) for f in mine] == [(str(block.id), "useful")]


@pytest.mark.asyncio
async def test_bad_targets_and_validation(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="x")
    other = await make_customer(db, topic="x")
    block, _, _ = await _story(db, other)  # someone else's private episode

    for ttype, tid in [("story", uuid.uuid4()), ("episode", uuid.uuid4()), ("news", uuid.uuid4()), ("story", block.id)]:
        with pytest.raises(HTTPException) as e:
            await _send(db, me, ttype, tid, "useful")
        assert e.value.status_code == 404
    assert await _count(db, Feedback) == 0

    with pytest.raises(ValidationError):
        fb_routes.FeedbackIn(target_type="podcast", target_id=uuid.uuid4(), rating="useful")
    with pytest.raises(ValidationError):
        fb_routes.FeedbackIn(target_type="story", target_id=uuid.uuid4(), rating="meh")
    with pytest.raises(ValidationError):
        fb_routes.FeedbackIn(target_type="story", target_id=uuid.uuid4(), rating="useful", reasons=["bogus"])
    with pytest.raises(HTTPException) as e:
        await fb_routes.get_feedback(target_type="story", target_ids="not-a-uuid", cliente=me, db=db)
    assert e.value.status_code == 422


@pytest.mark.asyncio
async def test_report_problem_stores_and_emits_event(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="x")
    block, _, _ = await _story(db, me)

    out = await fb_routes.report_problem(
        body=fb_routes.ReportIn(target_type="story", target_id=block.id, text="  audio cuts off  "), cliente=me, db=db)

    row = (await db.execute(select(ProblemReport))).scalar_one()
    assert str(row.id) == out.id and row.text == "audio cuts off" and row.cliente_id == me.id
    names = (await db.execute(select(Event.name))).scalars().all()
    assert "problem_reported" in names

    with pytest.raises(ValidationError):
        fb_routes.ReportIn(target_type="story", target_id=block.id, text="   ")
    with pytest.raises(HTTPException) as e:
        await fb_routes.report_problem(
            body=fb_routes.ReportIn(target_type="story", target_id=uuid.uuid4(), text="x"), cliente=me, db=db)
    assert e.value.status_code == 404


@pytest.mark.asyncio
async def test_feedback_submitted_event_has_no_free_text(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="x")
    block, _, _ = await _story(db, me)

    await _send(db, me, "story", block.id, "not_quite", ["too_long"], "secret words")

    ev = (await db.execute(select(Event).where(Event.name == "feedback_submitted"))).scalar_one()
    assert ev.payload["action"] == "created" and ev.payload["has_suggestion"] is True
    assert "secret words" not in str(ev.payload)
