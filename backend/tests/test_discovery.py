"""
Discovery audio (news item voiced on tap) and the news <-> capsule link.

Fakes only: ai_platform.synthesize is replaced by FakeTTS. Nothing reaches
Anthropic or ElevenLabs. Concurrency tests give every request its OWN session.
"""
import asyncio
import itertools
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi import FastAPI
from sqlalchemy import event, select, update
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.api.deps import get_current_cliente
from app.api.routes import account, home, news
from app.db.session import get_db
from app.main import app
from app.models.discovery import DiscoveryVoicingLog, NewsItemAudio
from app.models.episode import Block, Episode, EpisodePath
from app.models.news import NewsItem
from app.models.profile import Profile
from app.models.request import Request
from app.services import ai_platform, discovery
from tests.news_helpers import make_customer

pytestmark = pytest.mark.asyncio


class FakeTTS:
    def __init__(self, *, fail: int = 0, delay: float = 0.0, cost: float = 0.1, guard: bool = False):
        self.calls: list[tuple[str, str | None, uuid.UUID]] = []
        self.fail, self.delay, self.cost, self.guard = fail, delay, cost, guard

    async def __call__(self, db, text, voice_id, customer_id, request_id=None, episode_id=None, with_timestamps=True):
        if self.guard:
            await ai_platform.guard_paid_call(db, customer_id, "synthesize")
        self.calls.append((text, voice_id, customer_id))
        if self.delay:
            await asyncio.sleep(self.delay)
        if self.fail > 0:
            self.fail -= 1
            raise RuntimeError("provider 503")
        return b"AUDIO", self.cost, [{"word": "w", "start_s": 0.0, "end_s": 7.0}]


def _item(topic_key="premier league", *, age_h=1, language="en", cluster_id=None, title="Arsenal win", short="Short text."):
    return NewsItem(topic_key=topic_key, category="sports", title=title, summary="s", short_version=short,
                    body="Long body.", sources=[], published_at=datetime.now(timezone.utc) - timedelta(hours=age_h),
                    slot="0500", language=language, cluster_id=cluster_id)


@asynccontextmanager
async def _client(db, *customers, own_sessions=False, monkeypatch=None):
    maker = async_sessionmaker(db.bind, expire_on_commit=False)
    cycle = itertools.cycle(customers)

    async def _db():
        if own_sessions:
            async with maker() as s:
                yield s
        else:
            yield db

    app.dependency_overrides[get_db] = _db
    app.dependency_overrides[get_current_cliente] = lambda: next(cycle)
    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            yield c
    finally:
        app.dependency_overrides.clear()


@pytest.fixture
def tts(monkeypatch):
    fake = FakeTTS()
    monkeypatch.setattr(ai_platform, "synthesize", fake)
    return fake


@pytest.fixture(autouse=True)
def _own_sessions_for_background(full_db_session, monkeypatch, tmp_path):
    monkeypatch.setattr(discovery, "session_factory", async_sessionmaker(full_db_session.bind, expire_on_commit=False))
    from app.core.config import settings
    monkeypatch.setattr(settings, "MEDIA_DIR", tmp_path)


async def _setup(db, n_items=1, **item_kw):
    me = await make_customer(db, topic="Premier League")
    items = [_item(**{"title": f"Story {i}", **item_kw}) for i in range(n_items)]
    db.add_all(items)
    await db.commit()
    return me, items


async def _post(c, item, **body):
    return await c.post(f"/api/news/{item.id}/audio", json=body or None)


# ── single flight / cache ────────────────────────────────────────────────────

async def test_concurrent_taps_pay_once_and_second_tap_is_free(full_db_session, monkeypatch):
    tts = FakeTTS(delay=0.2)
    monkeypatch.setattr(ai_platform, "synthesize", tts)
    db = full_db_session
    me, (item,) = await _setup(db)
    others = [await make_customer(db, topic="x") for _ in range(2)]
    async with _client(db, me, *others, own_sessions=True) as c:
        results = await asyncio.gather(*[_post(c, item) for _ in range(8)])
        assert {r.status_code for r in results} <= {200, 202}
        assert all(r.json()["status"] in ("voicing", "voiced") for r in results)
        await discovery.drain()
        assert len(tts.calls) == 1  # exactly one paid synthesis for (item, voice)
        got = await c.get(f"/api/news/{item.id}/audio")
        body = got.json()
        assert got.status_code == 200 and body["status"] == "voiced" and body["url"] and body["duration_s"] == 7
        again = await _post(c, item)
        assert again.status_code == 200 and again.json()["url"] == body["url"]
        assert len(tts.calls) == 1
    # Ledger: exactly one claim, cost committed.
    logs = (await db.execute(select(DiscoveryVoicingLog))).scalars().all()
    assert len(logs) == 1 and logs[0].cost == pytest.approx(0.1)
    rows = (await db.execute(select(NewsItemAudio))).scalars().all()
    assert len(rows) == 1 and rows[0].status == "voiced" and rows[0].attempts == 1


async def test_synthesis_is_attributed_to_the_discovery_sentinel_and_text_has_no_user_data(full_db_session, tts):
    db = full_db_session
    me, (item,) = await _setup(db, title="Arsenal win", short="Short text.")
    async with _client(db, me) as c:
        r = await _post(c, item)
        await discovery.drain()
        body = (await c.get(f"/api/news/{item.id}/audio")).json()
    text, voice, customer = tts.calls[0]
    assert customer == ai_platform.DISCOVERY_SENTINEL and customer != uuid.UUID(int=0)
    assert text == "Arsenal win. Short text."
    assert me.email not in text and (me.nombre or "###") not in text and "my topic" not in text
    name = body["url"].rsplit("/", 1)[1]
    assert name.startswith("discovery-") and str(item.id) not in name and "arsenal" not in name.lower()


async def test_get_never_spends_or_starts(full_db_session, tts):
    db = full_db_session
    me, (item,) = await _setup(db)
    async with _client(db, me) as c:
        r = await c.get(f"/api/news/{item.id}/audio")
    assert r.status_code == 200 and r.json()["status"] == "none"
    assert tts.calls == [] and (await db.execute(select(NewsItemAudio))).scalars().all() == []


# ── voice / language ─────────────────────────────────────────────────────────

async def test_voice_validation_default_and_profile_voice(full_db_session, tts):
    db = full_db_session
    me, (item,) = await _setup(db)  # customer and item are English
    async with _client(db, me) as c:
        bad = await _post(c, item, voice="valentina")  # a Spanish voice for an English item
        assert bad.status_code == 422 and bad.json()["code"] == "voice_not_allowed"
        assert (await c.get(f"/api/news/{item.id}/audio?voice=nope")).status_code == 422
        ok = await _post(c, item, voice="en_voice_male_1")
        assert ok.json()["voice"] == "en_voice_male_1"
        await discovery.drain()
        db.add(Profile(customer_id=me.id, voice_id="en_voice_male_1"))
        await db.commit()
        default = await c.get(f"/api/news/{item.id}/audio")
        assert default.json()["voice"] == "en_voice_male_1" and default.json()["status"] == "voiced"
    assert tts.calls[0][1] == "en_voice_male_1"


async def test_unknown_item_404_and_requires_auth(full_db_session, tts):
    db = full_db_session
    me, _ = await _setup(db)
    async with _client(db, me) as c:
        assert (await c.post(f"/api/news/{uuid.uuid4()}/audio")).status_code == 404
    bare = FastAPI()
    bare.include_router(news.router, prefix="/api")
    nid = uuid.uuid4()
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=bare), base_url="http://t") as c:
        assert (await c.post(f"/api/news/{nid}/audio")).status_code == 401
        assert (await c.get(f"/api/news/{nid}/audio")).status_code == 401


# ── guards ───────────────────────────────────────────────────────────────────

async def test_per_user_daily_rate_limit_only_counts_new_voicings(full_db_session, tts, monkeypatch):
    monkeypatch.setenv("DISCOVERY_MAX_VOICINGS_PER_USER_DAY", "2")
    db = full_db_session
    me, items = await _setup(db, n_items=3)
    async with _client(db, me) as c:
        for item in items[:2]:
            assert (await _post(c, item)).json()["status"] == "voicing"
            await discovery.drain()
        third = await _post(c, items[2])
        assert third.status_code == 200
        assert third.json()["status"] == "blocked" and third.json()["code"] == "discovery_rate_limited"
        assert "límite" in third.json()["message"] or "limit" in third.json()["message"]
        assert (await _post(c, items[0])).json()["status"] == "voiced"  # replaying a voiced item is free
        # Another customer is not affected, and sees the already-voiced item for free.
        other = await make_customer(db, topic="x")
    async with _client(db, other) as c2:
        assert (await _post(c2, items[2])).json()["status"] == "voicing"
        await discovery.drain()
    assert len(tts.calls) == 3


async def test_item_age_limit(full_db_session, tts):
    db = full_db_session
    me, (old,) = await _setup(db, age_h=72)
    async with _client(db, me) as c:
        r = await _post(c, old)
    assert r.json()["status"] == "blocked" and r.json()["code"] == "discovery_too_old" and tts.calls == []
    # Already voiced audio of an item that has since aged out still plays.
    db.add(NewsItemAudio(news_item_id=old.id, voice_key="en_voice_female_1", language="en", status="voiced",
                         audio_url="http://x/media/a.mp3", duration_s=5, attempts=1))
    await db.commit()
    async with _client(db, me) as c:
        assert (await _post(c, old)).json()["status"] == "voiced"


@pytest.mark.budget_guard
async def test_daily_ceiling_from_committed_ledger(full_db_session, monkeypatch):
    monkeypatch.setenv("DISCOVERY_DAILY_CEILING_USD", "0.2")
    tts = FakeTTS(cost=0.15, guard=True)
    monkeypatch.setattr(ai_platform, "synthesize", tts)
    db = full_db_session
    me, items = await _setup(db, n_items=3)
    async with _client(db, me) as c:
        for item in items[:2]:
            assert (await _post(c, item)).json()["status"] == "voicing"
            await discovery.drain()
        third = await _post(c, items[2])
    assert third.json()["status"] == "blocked" and third.json()["code"] == "discovery_ceiling"
    assert len(tts.calls) == 2
    spent = await ai_platform.discovery_spent_today(db)
    assert spent == pytest.approx(0.3)  # committed ledger, no AICall rows involved
    # The sentinel is its own branch: it neither bypasses the ceiling like news nor charges a customer.
    with pytest.raises(ai_platform.DiscoveryCeilingError):
        await ai_platform.guard_paid_call(db, ai_platform.DISCOVERY_SENTINEL, "x", emit=False)
    await ai_platform.guard_paid_call(db, uuid.UUID(int=0), "x", emit=False)  # news sentinel unaffected


@pytest.mark.budget_guard
async def test_kill_switch_blocks_new_voicing_but_not_playback(full_db_session, monkeypatch):
    tts = FakeTTS(guard=True)
    monkeypatch.setattr(ai_platform, "synthesize", tts)
    db = full_db_session
    me, items = await _setup(db, n_items=2)
    async with _client(db, me) as c:
        assert (await _post(c, items[0])).json()["status"] == "voicing"
        await discovery.drain()
        monkeypatch.setenv("AI_GLOBAL_KILL_SWITCH", "1")
        blocked = await _post(c, items[1])
        assert blocked.json()["status"] == "blocked" and blocked.json()["code"] == "ai_paused"
        assert (await _post(c, items[0])).json()["status"] == "voiced"
    with pytest.raises(ai_platform.AIKillSwitchError):
        await ai_platform.guard_paid_call(db, ai_platform.DISCOVERY_SENTINEL, "x", emit=False)
    assert len(tts.calls) == 1


@pytest.mark.budget_guard
async def test_guard_refusal_inside_the_paid_call_refunds_the_attempt(full_db_session, monkeypatch):
    class Refusing(FakeTTS):
        async def __call__(self, db, text, voice_id, customer_id, **kw):
            raise ai_platform.AIKillSwitchError("synthesize")

    monkeypatch.setattr(ai_platform, "synthesize", Refusing())
    db = full_db_session
    me, (item,) = await _setup(db)
    async with _client(db, me) as c:
        await _post(c, item)
        await discovery.drain()
        r = await c.get(f"/api/news/{item.id}/audio")
    assert r.json()["status"] == "blocked" and r.json()["code"] == "ai_paused"
    row = (await db.execute(select(NewsItemAudio))).scalar_one()
    assert row.attempts == 0 and row.status == "pending"


# ── failure, retry cap, stale lease ──────────────────────────────────────────

async def test_failure_backoff_and_attempt_cap(full_db_session, monkeypatch):
    tts = FakeTTS(fail=99)
    monkeypatch.setattr(ai_platform, "synthesize", tts)
    db = full_db_session
    me, (item,) = await _setup(db)

    async def _age_row():
        await db.execute(update(NewsItemAudio).values(updated_at=datetime.now(timezone.utc) - timedelta(minutes=46)))
        await db.commit()

    async with _client(db, me) as c:
        assert (await _post(c, item)).json()["status"] == "voicing"
        await discovery.drain()
        r = (await c.get(f"/api/news/{item.id}/audio")).json()
        assert r["status"] == "failed" and r["code"] == "discovery_failed" and r["retry_after_s"] > 0 and r["message"]
        assert (await _post(c, item)).json()["status"] == "failed" and len(tts.calls) == 1  # inside the backoff
        for expected_calls in (2, 3):
            await _age_row()
            assert (await _post(c, item)).json()["status"] == "voicing"
            await discovery.drain()
            assert len(tts.calls) == expected_calls
        await _age_row()
        final = (await _post(c, item)).json()
        assert final["status"] == "failed" and final["retry_after_s"] is None and len(tts.calls) == 3  # cap
    row = (await db.execute(select(NewsItemAudio))).scalar_one()
    assert row.attempts == 3 and row.audio_url is None


async def test_stale_lease_is_reclaimed_and_fresh_lease_is_not(full_db_session, tts):
    db = full_db_session
    me, (item,) = await _setup(db)
    row = NewsItemAudio(news_item_id=item.id, voice_key="en_voice_female_1", language="en", status="voicing",
                        attempts=1, voicing_started_at=datetime.now(timezone.utc) - timedelta(minutes=5))
    db.add(row)
    await db.commit()
    async with _client(db, me) as c:
        r = await _post(c, item)
        assert r.status_code == 202 and r.json()["status"] == "voicing" and tts.calls == []  # live lease: do not pay twice
        await db.execute(update(NewsItemAudio).values(
            voicing_started_at=datetime.now(timezone.utc) - timedelta(minutes=31)))
        await db.commit()
        assert (await _post(c, item)).json()["status"] == "voicing"
        await discovery.drain()
    assert len(tts.calls) == 1
    got = (await db.execute(select(NewsItemAudio))).scalar_one()
    await db.refresh(got)
    assert got.status == "voiced" and got.attempts == 2


# ── link: related capsule ────────────────────────────────────────────────────

async def _capsule(db, customer, topic, *, age_h=1, published=True, audio_status="voiced"):
    req = (await db.execute(select(Request).where(Request.customer_id == customer.id))).scalars().first()
    req.structured = {"topic": topic}
    ts = datetime.now(timezone.utc) - timedelta(hours=age_h)
    ep = Episode(customer_id=customer.id, fecha=ts.date(), path=EpisodePath.scheduled, headline="h", style="news",
                 duration_s=60, published_at=ts if published else None)
    db.add(ep)
    await db.flush()
    block = Block(episode_id=ep.id, request_id=req.id, start_s=0, end_s=30, summary="s", script="x",
                  audio_status=audio_status, audio_url="http://x/media/c.mp3" if audio_status == "voiced" else None,
                  sequence=0)
    db.add(block)
    await db.commit()
    return ep, block


async def test_related_capsule_matches_own_topic_only(full_db_session, tts):
    db = full_db_session
    me = await make_customer(db, topic="Premier League")
    other = await make_customer(db, topic="Premier League")
    cluster = uuid.uuid4()
    same = _item("premier league", title="Same topic")
    diff = _item("federal reserve", title="Other topic")
    mate_a = _item("premier league", title="Cluster A", cluster_id=cluster)
    mate_b = _item("football transfers", title="Cluster B", cluster_id=cluster)
    db.add_all([same, diff, mate_a, mate_b])
    await db.commit()
    ep, block = await _capsule(db, me, "  Premier  LEAGUE ")  # normalised like findings_store
    async with _client(db, me) as c:
        items = {i["title"]: i for i in (await c.get("/api/news?scope=all")).json()["items"]}
        one = (await c.get(f"/api/news/{same.id}")).json()
    assert items["Same topic"]["related_capsule"] == {
        "episode_id": str(ep.id), "block_id": str(block.id), "audio_status": "voiced",
        "audio_url": "http://x/media/c.mp3"}
    assert one["related_capsule"]["block_id"] == str(block.id)
    assert items["Other topic"]["related_capsule"] is None
    assert items["Cluster A"]["related_capsule"]["block_id"] == str(block.id)
    assert items["Cluster B"]["related_capsule"]["block_id"] == str(block.id)  # secondary hint: same cluster_id
    async with _client(db, other) as c:  # the other customer never sees my capsule
        theirs = (await c.get("/api/news?scope=all")).json()["items"]
    assert all(i["related_capsule"] is None for i in theirs)


async def test_related_capsule_window_and_publication(full_db_session, tts):
    db = full_db_session
    me = await make_customer(db, topic="Premier League")
    item = _item("premier league")
    db.add(item)
    await db.commit()
    await _capsule(db, me, "Premier League", age_h=60)  # older than 2 days
    async with _client(db, me) as c:
        assert (await c.get(f"/api/news/{item.id}")).json()["related_capsule"] is None
    await _capsule(db, me, "Premier League", age_h=1, published=False)  # not published
    async with _client(db, me) as c:
        assert (await c.get(f"/api/news/{item.id}")).json()["related_capsule"] is None


async def test_item_audio_field_reflects_caller_voice_without_spend(full_db_session, tts):
    db = full_db_session
    me, (item,) = await _setup(db)
    async with _client(db, me) as c:
        assert (await c.get(f"/api/news/{item.id}")).json()["audio"] is None
        await _post(c, item)
        await discovery.drain()
        audio = (await c.get(f"/api/news/{item.id}")).json()["audio"]
        listed = (await c.get("/api/news?scope=all")).json()["items"][0]["audio"]
    assert audio["status"] == "voiced" and audio["url"] and audio["duration_s"] == 7
    assert audio["voice"] == "en_voice_female_1" and listed == audio
    assert len(tts.calls) == 1


# ── no N+1, include_news ─────────────────────────────────────────────────────

def _counter(db):
    counts = []
    sync_engine = db.bind.sync_engine
    fn = lambda *_a, **_k: counts.append(1)  # noqa: E731
    event.listen(sync_engine, "before_cursor_execute", fn)
    return counts, lambda: event.remove(sync_engine, "before_cursor_execute", fn)


async def test_news_list_query_count_is_constant(full_db_session, tts):
    db = full_db_session
    me = await make_customer(db, topic="Premier League")
    cluster = uuid.uuid4()
    db.add_all([_item(title="a", cluster_id=cluster), _item("fed", title="b", cluster_id=cluster)])
    await db.commit()
    await _capsule(db, me, "Premier League")
    counts, stop = _counter(db)
    try:
        await news.list_news(day=None, tz_offset_minutes=0, cursor=None, limit=30, scope="all", cliente=me, db=db)
        small = len(counts)
        db.add_all([_item(f"t{i}", title=f"n{i}", cluster_id=uuid.uuid4()) for i in range(25)])
        await db.commit()
        counts.clear()
        out = await news.list_news(day=None, tz_offset_minutes=0, cursor=None, limit=30, scope="all", cliente=me, db=db)
        big = len(counts)
    finally:
        stop()
    assert len(out.items) == 27
    assert big == small and big <= 12


async def test_home_include_news_false_skips_news(full_db_session, tts):
    db = full_db_session
    me, _ = await _setup(db)
    with_news = await home.home(cliente=me, db=db)
    assert with_news.news is not None and len(with_news.news.items) == 1
    counts, stop = _counter(db)
    try:
        without = await home.home(include_news=False, cliente=me, db=db)
        skipped = len(counts)
        counts.clear()
        await home.home(include_news=True, cliente=me, db=db)
        full = len(counts)
    finally:
        stop()
    assert without.news is None and skipped < full
    async with _client(db, me) as c:
        assert (await c.get("/api/home?include_news=false")).json()["news"] is None
        assert (await c.get("/api/home")).json()["news"] is not None


# ── account ──────────────────────────────────────────────────────────────────

async def test_account_export_and_deletion_anonymise_the_ledger(full_db_session, tts):
    db = full_db_session
    me, (item,) = await _setup(db)
    async with _client(db, me) as c:
        await _post(c, item)
        await discovery.drain()
        exported = (await c.get("/api/account/export")).json()
        assert [v["news_item_id"] for v in exported["discovery_voicings"]] == [str(item.id)]
        assert (await c.delete("/api/account")).status_code == 200
    db.expire_all()
    log = (await db.execute(select(DiscoveryVoicingLog))).scalar_one()
    assert log.customer_id is None and log.cost == pytest.approx(0.1)  # nothing personal; spend kept
    assert (await db.execute(select(NewsItemAudio))).scalar_one().status == "voiced"  # shared, kept
