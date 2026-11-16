"""Integration tests that only make sense on the COMBINED code: news slots per
timezone (#62) + GET /home and GET /episodes (#63) + feedback and signals (#64).

Conventions (see the sibling suites): real Postgres, handlers called directly,
aware datetimes only. NOTHING here can reach Anthropic or ElevenLabs: an
autouse fixture replaces the SDK client and the TTS call with guards that fail
the test, and the tests that need model output install a fake SDK client UNDER
ai_platform (research_topic / write_news_items / _log_call all run for real).
"""
import asyncio
import json
import time
import types
import uuid
from datetime import date, datetime, timedelta, timezone

import pytest
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.api.routes import feedback as fb_routes
from app.api.routes import history, home, news
from app.api.routes import requests as req_routes
from app.db.session import DATABASE_URL, ENGINE_CONNECT_ARGS
from app.models.episode import Block, Episode, EpisodePath
from app.models.feedback import Feedback, FeedbackSignal
from app.models.instrumentation import AICall
from app.models.news import NewsItem, NewsRun
from app.models.profile import Profile
from app.models.request import Request, RequestStatus
from app.services import ai_platform
from app.services import news_pipeline as np_
from tests.news_helpers import NOW, make_customer, patch_news_ai

TOPIC = "Premier League"
RUN_DATE = date(2026, 11, 12)


def utc(*args) -> datetime:
    return datetime(*args, tzinfo=timezone.utc)


# ---------------------------------------------------------------------------
# Provider guards + a fake SDK client (the layer UNDER ai_platform)
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def _no_real_providers(monkeypatch):
    def _forbidden(*a, **k):
        raise AssertionError("a test reached a real model/TTS provider")

    monkeypatch.setattr(ai_platform, "_client", types.SimpleNamespace(
        messages=types.SimpleNamespace(create=_forbidden, parse=_forbidden)))
    monkeypatch.setattr(ai_platform, "synthesize", _forbidden)


class FakeSDK:
    """Stands in for anthropic.Anthropic(). Records every call (model + tools)
    and returns realistic responses with token usage. `create` serves research,
    `parse` serves the news writer."""

    def __init__(self, *, research_usage=(50_000, 1_000), write_usage=(3_000, 800), research_text=None,
                 write_error: Exception | None = None, delay_s: float = 0.0):
        self.research_usage, self.write_usage = research_usage, write_usage
        self.write_error, self.delay_s = write_error, delay_s
        self.research_text = research_text if research_text is not None else json.dumps({
            "findings": [{"headline": "Arsenal beat Spurs 2-1", "detail": "A late winner.",
                          "source_urls": ["https://example.com/0"]}],
            "sources": [{"url": "https://example.com/0", "title": "Source 0"}],
            "no_news": False,
        })
        self.create_models: list[str] = []
        self.create_tools: list = []
        self.parse_models: list[str] = []
        self.messages = types.SimpleNamespace(create=self._create, parse=self._parse)

    def _create(self, **kw):  # runs in a worker thread (ai_platform._invoke)
        self.create_models.append(kw["model"])
        self.create_tools.append(kw.get("tools"))
        if self.delay_s:
            time.sleep(self.delay_s)
        return types.SimpleNamespace(
            content=[types.SimpleNamespace(type="text", text=self.research_text)],
            usage=types.SimpleNamespace(input_tokens=self.research_usage[0], output_tokens=self.research_usage[1]))

    def _parse(self, **kw):
        self.parse_models.append(kw["model"])
        if self.write_error:
            raise self.write_error
        drafts = ai_platform.NewsDrafts(items=[ai_platform.NewsDraft(
            category="sports", title="Arsenal beat Spurs", summary="Arsenal win the derby 2-1.",
            short_version="Short.", body="Full write-up.", source_urls=["https://example.com/0"])])
        return types.SimpleNamespace(
            parsed_output=drafts,
            usage=types.SimpleNamespace(input_tokens=self.write_usage[0], output_tokens=self.write_usage[1]))


def install_sdk(monkeypatch, **kw) -> FakeSDK:
    sdk = FakeSDK(**kw)
    monkeypatch.setattr(ai_platform, "_client", sdk)
    return sdk


# Prices from ai_platform._PRICE_PER_1M: research on sonnet-5-5 ($2/$10 per 1M),
# writing on haiku-5-5 ($0.10/$0.50 per 1M).
RESEARCH_COST = 50_000 / 1e6 * 2.00 + 1_000 / 1e6 * 10.00   # 0.11
WRITE_COST = 3_000 / 1e6 * 0.10 + 800 / 1e6 * 0.50          # 0.0007


async def _follower(db, topic: str = TOPIC, tz: str | None = None):
    cliente = await make_customer(db, topic=topic)
    if tz is not None:
        db.add(Profile(customer_id=cliente.id, delivery_timezone=tz))
        await db.commit()
    return cliente


async def _runs(db):
    return (await db.execute(select(NewsRun).order_by(NewsRun.created_at))).scalars().all()


async def _count(db, model):
    return (await db.execute(select(func.count()).select_from(model))).scalar_one()


# ---------------------------------------------------------------------------
# (a) GET /home news block == GET /news page 1, using the profile timezone
# ---------------------------------------------------------------------------

class _FrozenDatetime(datetime):
    """home.py's `datetime.now(...)`, frozen at 2026-11-12 12:00 UTC."""
    @classmethod
    def now(cls, tz=None):
        frozen = datetime(2026, 11, 12, 12, 0, tzinfo=timezone.utc)
        return frozen.astimezone(tz) if tz else frozen.replace(tzinfo=None)


def _item(title, published_at, topic_key="premier league", category="sports"):
    return NewsItem(topic_key=topic_key, category=category, title=title, summary="s", short_version="s", body="b",
                    sources=[], published_at=published_at, slot="0500")


async def _news_page(db, me, **kw):
    args = dict(day=None, tz_offset_minutes=None, cursor=None, limit=30, scope="followed")
    args.update(kw)
    return await news.list_news(cliente=me, db=db, **args)


@pytest.fixture
def frozen_window(monkeypatch):
    """Deterministic clock for the feed: 7-day window anchored at 2026-11-12 and
    home.py's `now` frozen. (Items below are dated relative to those.)"""
    monkeypatch.setattr(news, "_window_start", lambda: utc(2026, 10, 1))
    monkeypatch.setattr(home, "datetime", _FrozenDatetime)


# i2 then i1 (newest first). Bogota is UTC-5 all year; Madrid is UTC+1 in November.
_I1 = utc(2026, 11, 10, 3, 30)    # Bogota Nov 9 22:30 | Madrid Nov 10 04:30 | UTC Nov 10
_I2 = utc(2026, 11, 11, 23, 30)   # Bogota Nov 11 18:30 | Madrid Nov 12 00:30 | UTC Nov 11


@pytest.mark.asyncio
@pytest.mark.parametrize("tz,expected_days", [
    ("America/Bogota", [date(2026, 11, 11), date(2026, 11, 9)]),
    ("Europe/Madrid", [date(2026, 11, 12), date(2026, 11, 10)]),
    ("Mars/Olympus_Mons", [date(2026, 11, 11), date(2026, 11, 10)]),  # invalid zone -> UTC in both endpoints
    (None, [date(2026, 11, 11), date(2026, 11, 10)]),                  # no Profile row -> UTC
])
async def test_home_news_block_equals_news_page_one_in_the_profile_timezone(full_db_session, frozen_window, tz, expected_days):
    db = full_db_session
    me = await _follower(db, tz=tz)
    db.add_all([_item("First", _I1), _item("Second", _I2), _item("Not mine", _I2, topic_key="fed", category="markets")])
    await db.commit()

    out = await home.home(cliente=me, db=db)
    page = await _news_page(db, me)  # tz_offset_minutes absent -> profile timezone

    assert out.news.model_dump() == page.model_dump()
    assert [i.title for i in page.items] == ["Second", "First"]
    assert [i.day for i in page.items] == expected_days
    assert page.no_follow_match is False


@pytest.mark.asyncio
async def test_explicit_offset_overrides_profile_timezone_on_news_only(full_db_session, frozen_window):
    db = full_db_session
    me = await _follower(db, tz="Europe/Madrid")
    db.add(_item("Second", _I2))
    await db.commit()

    assert (await _news_page(db, me)).items[0].day == date(2026, 11, 12)                          # Madrid profile
    assert (await _news_page(db, me, tz_offset_minutes=-300)).items[0].day == date(2026, 11, 11)  # explicit wins


@pytest.mark.asyncio
async def test_news_feed_day_is_dst_aware_per_item_for_the_profile_zone(full_db_session, frozen_window):
    """Madrid left summer time at 01:00 UTC on 2026-10-25, so the SAME wall-clock
    UTC hour maps to different local days depending on the item's own date."""
    db = full_db_session
    madrid = await _follower(db, tz="Europe/Madrid")
    bogota = await _follower(db, tz="America/Bogota")
    db.add_all([_item("Before the change", utc(2026, 10, 24, 22, 30)),   # CEST (+2): Oct 25 00:30
                _item("After the change", utc(2026, 10, 25, 23, 30))])   # CET  (+1): Oct 26 00:30
    await db.commit()

    by_title = {i.title: i.day for i in (await _news_page(db, madrid)).items}
    assert by_title == {"Before the change": date(2026, 10, 25), "After the change": date(2026, 10, 26)}
    by_title = {i.title: i.day for i in (await _news_page(db, bogota)).items}
    assert by_title == {"Before the change": date(2026, 10, 24), "After the change": date(2026, 10, 25)}  # no DST in Bogota

    # And the `day=` filter uses the same zone rules.
    only = await _news_page(db, madrid, day=date(2026, 10, 25))
    assert [i.title for i in only.items] == ["Before the change"]


@pytest.mark.asyncio
async def test_home_news_day_matches_news_across_a_dst_change(full_db_session, frozen_window):
    db = full_db_session
    me = await _follower(db, tz="Europe/Madrid")
    db.add(_item("Before the change", utc(2026, 10, 24, 22, 30)))
    await db.commit()

    out = await home.home(cliente=me, db=db)
    page = await _news_page(db, me)

    assert page.items[0].day == date(2026, 10, 25)
    assert out.news.model_dump() == page.model_dump()


@pytest.mark.asyncio
async def test_home_falls_back_to_all_exactly_like_news_scope_all(full_db_session, frozen_window):
    db = full_db_session
    me = await _follower(db, topic="Gardening", tz="America/Bogota")
    db.add(_item("Rates", _I2, topic_key="fed", category="markets"))
    await db.commit()

    out = await home.home(cliente=me, db=db)
    assert (await _news_page(db, me)).items == [] and (await _news_page(db, me)).no_follow_match is True
    assert out.news.model_dump() == (await _news_page(db, me, scope="all")).model_dump()


# ---------------------------------------------------------------------------
# (b) feedback on news / story, GET /feedback, and stop_topic vs the pipeline
# ---------------------------------------------------------------------------

async def _story(db, cliente):
    req = (await db.execute(select(Request).where(Request.customer_id == cliente.id))).scalars().first()
    ep = Episode(customer_id=cliente.id, fecha=date(2026, 11, 12), path=EpisodePath.scheduled)
    db.add(ep)
    await db.flush()
    block = Block(episode_id=ep.id, request_id=req.id, start_s=0, end_s=30, summary="s", script="x")
    db.add(block)
    await db.commit()
    return block, req


async def _send(db, cliente, target_type, target_id, rating, reasons=(), suggestion=None):
    body = fb_routes.FeedbackIn(target_type=target_type, target_id=target_id, rating=rating,
                                reasons=list(reasons), suggestion=suggestion)
    return await fb_routes.submit_feedback(body=body, cliente=cliente, db=db)


async def _get(db, cliente, target_type, *ids):
    return await fb_routes.get_feedback(target_type=target_type, target_ids=",".join(str(i) for i in ids),
                                        cliente=cliente, db=db)


async def _signal(db, cliente, subject_type, key):
    return (await db.execute(select(FeedbackSignal).where(
        FeedbackSignal.cliente_id == cliente.id, FeedbackSignal.subject_type == subject_type,
        FeedbackSignal.subject_key == key).execution_options(populate_existing=True))).scalar_one_or_none()


async def _status(db, request_id):
    return (await db.get(Request, request_id, populate_existing=True)).status


@pytest.mark.asyncio
async def test_feedback_on_a_news_item_from_the_feed_is_reflected_by_get_feedback(full_db_session):
    db = full_db_session
    me = await _follower(db)
    other = await _follower(db)
    db.add(_item("Mine", datetime.now(timezone.utc) - timedelta(hours=1)))
    await db.commit()
    item_id = uuid.UUID((await _news_page(db, me, tz_offset_minutes=0)).items[0].id)

    await _send(db, me, "news", item_id, "not_quite", ["not_relevant"], "less of this")

    mine = await _get(db, me, "news", item_id)
    assert [(f.target_id, f.rating, f.reasons, f.suggestion) for f in mine] == [
        (str(item_id), "not_quite", ["not_relevant"], "less of this")]
    assert await _get(db, me, "story", item_id) == [] and await _get(db, me, "episode", item_id) == []
    assert await _get(db, other, "news", item_id) == []                       # per caller
    assert (await _signal(db, me, "topic", "premier league")).not_relevant == 1
    # feedback never hides the item from the feed or from /home
    assert [i.title for i in (await home.home(cliente=me, db=db)).news.items] == ["Mine"]

    await _send(db, me, "news", item_id, "not_quite", ["not_relevant"], "less of this")  # same payload: off
    assert await _get(db, me, "news", item_id) == []
    assert (await _signal(db, me, "topic", "premier league")).score == 0


@pytest.mark.asyncio
async def test_story_feedback_switch_is_reflected_and_scoped_to_target_type(full_db_session):
    db = full_db_session
    me = await _follower(db)
    block, req = await _story(db, me)

    await _send(db, me, "story", block.id, "useful")
    assert [f.rating for f in await _get(db, me, "story", block.id)] == ["useful"]
    await _send(db, me, "story", block.id, "not_quite", ["too_long"])
    assert [(f.rating, f.reasons) for f in await _get(db, me, "story", block.id)] == [("not_quite", ["too_long"])]
    assert await _get(db, me, "news", block.id) == []
    sig = await _signal(db, me, "request", str(req.id))
    assert (sig.useful, sig.not_quite, sig.too_long, sig.score) == (0, 1, 1, -1)


@pytest.mark.asyncio
async def test_stop_topic_pauses_the_request_and_the_news_scheduler_and_home_follow(full_db_session, monkeypatch):
    db = full_db_session
    me = await _follower(db, tz="America/Bogota")
    block, req = await _story(db, me)
    rec = patch_news_ai(monkeypatch)
    now = utc(2026, 11, 12, 12, 30)  # 07:30 in Bogota: 0500 band

    assert [t.topic for t in (await home.home(cliente=me, db=db)).followed_topics] == [TOPIC]

    await _send(db, me, "story", block.id, "not_quite", ["stop_topic"])
    assert await _status(db, req.id) == RequestStatus.paused
    assert (await db.get(Feedback, (await db.execute(select(Feedback.id))).scalar_one())).effects["paused_requests"] == [str(req.id)]
    assert (await home.home(cliente=me, db=db)).followed_topics == []
    assert await np_.topics_with_followers(db) == []
    summary = await np_.run_scheduled_slot(db, now=now)
    assert summary["topics"] == 0 and rec.research_calls == []

    await _send(db, me, "story", block.id, "not_quite", ["stop_topic"])  # toggled off: resumed
    assert await _status(db, req.id) == RequestStatus.active
    assert [t.topic for t in (await home.home(cliente=me, db=db)).followed_topics] == [TOPIC]
    summary = await np_.run_scheduled_slot(db, now=now)
    assert summary["topics"] == 1 and rec.research_calls == [TOPIC]


@pytest.mark.asyncio
async def test_manual_pause_is_not_auto_resumed_when_stop_topic_is_toggled_off(full_db_session, monkeypatch):
    db = full_db_session
    me = await _follower(db)
    block, req = await _story(db, me)
    rec = patch_news_ai(monkeypatch)
    req.status = RequestStatus.paused  # the user paused it themselves
    await db.commit()

    await _send(db, me, "story", block.id, "not_quite", ["stop_topic"])
    fb = (await db.execute(select(Feedback))).scalar_one()
    assert fb.effects["paused_requests"] == []          # nothing was paused BY feedback
    assert (await _signal(db, me, "request", str(req.id))).stop_topic == 1  # but the signal is recorded

    await _send(db, me, "story", block.id, "not_quite", ["stop_topic"])  # off
    assert await _status(db, req.id) == RequestStatus.paused
    assert await _count(db, Feedback) == 0
    assert (await np_.run_scheduled_slot(db, now=NOW))["topics"] == 0 and rec.research_calls == []


@pytest.mark.asyncio
async def test_changing_the_reason_away_from_stop_topic_resumes_a_feedback_pause(full_db_session):
    """Actual behaviour: an update re-runs reverse+apply, so the feedback pause is undone."""
    db = full_db_session
    me = await _follower(db)
    block, req = await _story(db, me)

    await _send(db, me, "story", block.id, "not_quite", ["stop_topic"])
    assert await _status(db, req.id) == RequestStatus.paused
    await _send(db, me, "story", block.id, "not_quite", ["too_long"])
    assert await _status(db, req.id) == RequestStatus.active
    assert (await _signal(db, me, "request", str(req.id))).stop_topic == 0


@pytest.mark.asyncio
async def test_stop_topic_on_an_episode_or_news_target_never_pauses(full_db_session):
    db = full_db_session
    me = await _follower(db)
    block, req = await _story(db, me)
    news_item = _item("N", datetime.now(timezone.utc) - timedelta(hours=1))
    db.add(news_item)
    await db.commit()
    ep_id = block.episode_id

    await _send(db, me, "episode", ep_id, "not_quite", ["stop_topic"])
    await _send(db, me, "news", news_item.id, "not_quite", ["stop_topic"])

    assert await _status(db, req.id) == RequestStatus.active
    assert (await _signal(db, me, "request", str(req.id))).stop_topic == 1
    assert (await _signal(db, me, "topic", "premier league")).stop_topic == 1


@pytest.mark.asyncio
async def test_two_stop_topic_stories_for_one_request_resume_only_when_none_remain(full_db_session):
    """The request stays paused while any stop_topic story feedback for it stands;
    removing the first hands the pause to the second, removing the last resumes."""
    db = full_db_session
    me = await _follower(db)
    block1, req = await _story(db, me)
    ep2 = Episode(customer_id=me.id, fecha=date(2026, 11, 11), path=EpisodePath.scheduled)
    db.add(ep2)
    await db.flush()
    block2 = Block(episode_id=ep2.id, request_id=req.id, start_s=0, end_s=30, summary="s", script="x")
    db.add(block2)
    await db.commit()

    await _send(db, me, "story", block1.id, "not_quite", ["stop_topic"])
    await _send(db, me, "story", block2.id, "not_quite", ["stop_topic"])
    assert await _status(db, req.id) == RequestStatus.paused

    await _send(db, me, "story", block1.id, "not_quite", ["stop_topic"])  # first off
    assert await _status(db, req.id) == RequestStatus.paused  # second stop_topic still stands
    assert (await _signal(db, me, "request", str(req.id))).stop_topic == 1  # second still counted

    await _send(db, me, "story", block2.id, "not_quite", ["stop_topic"])  # last off
    assert await _status(db, req.id) == RequestStatus.active


@pytest.mark.asyncio
async def test_manual_repause_after_feedback_pause_survives_feedback_toggle_off(full_db_session):
    db = full_db_session
    me = await _follower(db)
    block, req = await _story(db, me)

    await _send(db, me, "story", block.id, "not_quite", ["stop_topic"])   # paused by feedback
    await req_routes.reanudar_request(request_id=req.id, cliente=me, db=db)  # user resumes in the app...
    await req_routes.pausar_request(request_id=req.id, cliente=me, db=db)    # ...then pauses it themselves

    await _send(db, me, "story", block.id, "not_quite", ["stop_topic"])   # feedback off
    assert await _status(db, req.id) == RequestStatus.paused


# ---------------------------------------------------------------------------
# (c) NewsRun cost accounting through the REAL research_topic / write_news_items
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_news_run_cost_is_recorded_from_real_provider_usage(full_db_session, monkeypatch):
    db = full_db_session
    sdk = install_sdk(monkeypatch)

    result = await np_.run_news_for_topic(db, TOPIC, slot="0500", run_date=RUN_DATE, now=NOW)

    assert result.status == "done" and len(result.items) == 1
    assert result.cost == pytest.approx(RESEARCH_COST + WRITE_COST)
    run = (await _runs(db))[0]
    assert run.status == "done" and run.items_count == 1 and run.cost > 0
    assert run.cost == pytest.approx(RESEARCH_COST + WRITE_COST)
    calls = (await db.execute(select(AICall).order_by(AICall.creado_en))).scalars().all()
    assert sorted(c.purpose for c in calls) == ["news_write", "research_topic"]
    assert sum(float(c.cost) for c in calls) == pytest.approx(run.cost)
    assert sdk.create_models == [ai_platform.model_for("research_topic")]
    assert sdk.parse_models == [ai_platform.model_for("news_write")]
    assert sdk.create_tools[0][0]["name"] == "web_search"


@pytest.mark.asyncio
async def test_daily_cost_ceiling_stops_further_topics_with_real_cost(full_db_session, monkeypatch):
    db = full_db_session
    for topic in ("Premier League", "La Liga", "Serie A"):
        await _follower(db, topic=topic)
    sdk = install_sdk(monkeypatch)

    summary = await np_.run_scheduled_slot(db, now=NOW, ceiling=0.10)  # one run costs ~0.11

    assert summary["ceiling_hit"] is True and summary["ran"] == 1 and summary["topics"] == 1
    assert len(sdk.create_models) == 1
    runs = await _runs(db)
    assert len(runs) == 1 and runs[0].cost == pytest.approx(RESEARCH_COST + WRITE_COST)

    again = await np_.run_scheduled_slot(db, now=NOW + timedelta(minutes=10), ceiling=0.10)  # next tick, same day
    assert again["ceiling_hit"] is True and again["topics"] == 0 and len(sdk.create_models) == 1


@pytest.mark.asyncio
async def test_below_the_ceiling_every_topic_runs(full_db_session, monkeypatch):
    db = full_db_session
    for topic in ("Premier League", "La Liga", "Serie A"):
        await _follower(db, topic=topic)
    sdk = install_sdk(monkeypatch)

    summary = await np_.run_scheduled_slot(db, now=NOW, ceiling=5.0)

    assert summary["ceiling_hit"] is False and summary["ran"] == 3 and len(sdk.create_models) == 3
    assert sum(r.cost for r in await _runs(db)) == pytest.approx(3 * (RESEARCH_COST + WRITE_COST))


@pytest.mark.asyncio
async def test_failed_research_parse_still_counts_both_paid_attempts_toward_the_ceiling(full_db_session, monkeypatch):
    db = full_db_session
    await _follower(db, topic="Premier League")
    await _follower(db, topic="La Liga")
    sdk = install_sdk(monkeypatch, research_text="this is not json")

    summary = await np_.run_scheduled_slot(db, now=NOW, ceiling=0.20)

    # sonnet attempt (0.11) + the opus retry (50K in / 1K out at $4/$20 = 0.22)
    assert sdk.create_models == ["claude-sonnet-5-5", "claude-opus-5-5"]
    run = (await _runs(db))[0]
    assert run.status == "failed" and run.error == "research parse failed"
    assert run.cost == pytest.approx(RESEARCH_COST + 0.22)
    assert summary["ceiling_hit"] is True and summary["failed"] == 1 and len(await _runs(db)) == 1


@pytest.mark.asyncio
async def test_paid_research_followed_by_a_write_failure_is_still_counted(full_db_session, monkeypatch):
    db = full_db_session
    install_sdk(monkeypatch, write_error=RuntimeError("writer exploded"))

    with pytest.raises(RuntimeError):
        await np_.run_news_for_topic(db, TOPIC, slot="0500", run_date=RUN_DATE, now=NOW)

    run = (await _runs(db))[0]
    assert run.status == "failed"
    assert run.cost > 0


# ---------------------------------------------------------------------------
# (d) two replicas claiming the same (topic, date, slot)
# ---------------------------------------------------------------------------

class _Replicas:
    """N independent sessions (own engine/connections), like N app replicas."""
    def __init__(self, n: int):
        self.n = n

    async def __aenter__(self):
        self.engine = create_async_engine(DATABASE_URL, echo=False, connect_args=ENGINE_CONNECT_ARGS)
        factory = async_sessionmaker(self.engine, expire_on_commit=False)
        self.sessions = [factory() for _ in range(self.n)]
        return self.sessions

    async def __aexit__(self, *exc):
        for s in self.sessions:
            await s.close()
        await self.engine.dispose()


@pytest.mark.asyncio
@pytest.mark.parametrize("replicas", [2, 4])
async def test_concurrent_replicas_publish_a_slot_exactly_once(full_db_session, monkeypatch, replicas):
    db = full_db_session
    await _follower(db)
    sdk = install_sdk(monkeypatch, delay_s=0.4)  # keep every replica's research in flight at once

    async with _Replicas(replicas) as sessions:
        results = await asyncio.gather(*[
            np_.run_news_for_topic(s, TOPIC, slot="0500", run_date=RUN_DATE, now=NOW) for s in sessions])

    assert sorted(r.status for r in results) == ["done"] + ["skipped"] * (replicas - 1)
    assert len(sdk.create_models) == 1 and len(sdk.parse_models) == 1   # one paid research, one paid write
    runs = await _runs(db)
    assert len(runs) == 1 and runs[0].status == "done" and runs[0].attempts == 1
    assert runs[0].cost == pytest.approx(RESEARCH_COST + WRITE_COST)
    assert await _count(db, NewsItem) == 1


@pytest.mark.asyncio
async def test_concurrent_replicas_reclaiming_a_stale_run_only_one_wins(full_db_session, monkeypatch):
    db = full_db_session
    await _follower(db)
    stale = datetime.now(timezone.utc) - timedelta(hours=1)
    db.add(NewsRun(topic_key=np_.normalize(TOPIC), run_date=RUN_DATE, slot="0500", status="running", attempts=1,
                   created_at=stale, updated_at=stale))
    await db.commit()
    sdk = install_sdk(monkeypatch, delay_s=0.4)

    async with _Replicas(2) as sessions:
        results = await asyncio.gather(*[
            np_.run_news_for_topic(s, TOPIC, slot="0500", run_date=RUN_DATE, now=NOW) for s in sessions])

    assert sorted(r.status for r in results) == ["done", "skipped"]
    assert len(sdk.create_models) == 1
    run = (await _runs(db))[0]
    assert run.status == "done" and run.attempts == 2
    assert await _count(db, NewsItem) == 1


@pytest.mark.asyncio
async def test_concurrent_scheduler_ticks_run_each_topic_slot_once(full_db_session, monkeypatch):
    db = full_db_session
    await _follower(db, topic="Premier League", tz="America/Bogota")
    await _follower(db, topic="La Liga", tz="America/Bogota")
    sdk = install_sdk(monkeypatch, delay_s=0.2)
    now = utc(2026, 11, 12, 12, 30)  # Bogota 07:30

    async with _Replicas(2) as sessions:
        await asyncio.gather(*[np_.run_scheduled_slot(s, now=now, ceiling=100) for s in sessions])

    assert len(sdk.create_models) == 2                       # one research per topic, not per replica
    runs = await _runs(db)
    assert sorted(r.topic_key for r in runs) == ["la liga", "premier league"]
    assert {(r.run_date, r.slot, r.status) for r in runs} == {(RUN_DATE, "0500", "done")}
    assert await _count(db, NewsItem) == 2


# ---------------------------------------------------------------------------
# (e) history search with literal % and _, isolation once feedback exists
# ---------------------------------------------------------------------------

def _episode(cid, headline, age_h, *, shared=False):
    ts = datetime.now(timezone.utc) - timedelta(hours=age_h)
    return Episode(customer_id=cid, shared=shared, fecha=ts.date(), path=EpisodePath.scheduled, headline=headline,
                   style="news", duration_s=300, published_at=ts)


async def _hist(db, me, **kw):
    args = dict(before=None, q=None, limit=20)
    args.update(kw)
    return await history.list_episodes(cliente=me, db=db, **args)


def _headlines(page):
    return sorted(i.headline for i in page.items)


@pytest.mark.asyncio
async def test_history_search_treats_percent_underscore_and_backslash_literally(full_db_session):
    db = full_db_session
    me = await _follower(db)
    eps = {h: _episode(me.id, h, i + 1) for i, h in enumerate([
        "100% sure", "1000 sure", "snake_case post", "snakeXcase post", r"path\to file", "pathXto file", "plain"])}
    db.add_all(eps.values())
    await db.commit()
    db.add(Block(episode_id=eps["plain"].id, start_s=0, end_s=5, summary="50% off today", script="x"))
    db.add(Block(episode_id=eps["1000 sure"].id, start_s=0, end_s=5, summary="500 off today", script="x"))
    await db.commit()

    assert _headlines(await _hist(db, me, q="%")) == ["100% sure", "plain"]          # plain: via block summary "50% off"
    assert _headlines(await _hist(db, me, q="100%")) == ["100% sure"]
    assert _headlines(await _hist(db, me, q="50%")) == ["plain"]
    assert _headlines(await _hist(db, me, q="_")) == ["snake_case post"]
    assert _headlines(await _hist(db, me, q="snake_case")) == ["snake_case post"]
    assert _headlines(await _hist(db, me, q="e_c")) == ["snake_case post"]
    assert _headlines(await _hist(db, me, q="\\")) == [r"path\to file"]
    assert _headlines(await _hist(db, me, q="%%")) == []
    assert _headlines(await _hist(db, me, q="___")) == []


@pytest.mark.asyncio
async def test_history_stays_per_customer_once_feedback_exists(full_db_session):
    db = full_db_session
    me = await _follower(db)
    other = await _follower(db)
    mine = _episode(me.id, "100% Arsenal", 3)
    theirs = _episode(other.id, "100% Arsenal secret", 2)
    shared = _episode(None, "100% shared Arsenal", 1, shared=True)
    db.add_all([mine, theirs, shared])
    await db.commit()
    block_other = Block(episode_id=theirs.id, request_id=None, start_s=0, end_s=5, summary="100% theirs", script="x")
    db.add(block_other)
    await db.commit()

    # Feedback from both customers on what each may see (a shared episode is visible to both).
    await _send(db, me, "episode", mine.id, "useful")
    await _send(db, me, "episode", shared.id, "useful")
    await _send(db, other, "episode", theirs.id, "not_quite", ["too_long"])
    await _send(db, other, "episode", shared.id, "not_quite")
    await _send(db, other, "story", block_other.id, "useful")
    assert await _count(db, Feedback) == 5

    for q in (None, "%", "100%", "arsenal", "theirs", "secret"):
        got = await _hist(db, me, q=q)
        assert _headlines(got) == (["100% Arsenal"] if q != "theirs" and q != "secret" else []), q
    assert _headlines(await _hist(db, other, q="%")) == ["100% Arsenal secret"]
    assert _headlines(await _hist(db, other, q="theirs")) == ["100% Arsenal secret"]  # via its block summary
    # Removing the feedback changes nothing about what history lists.
    await _send(db, me, "episode", mine.id, "useful")
    assert _headlines(await _hist(db, me)) == ["100% Arsenal"]
