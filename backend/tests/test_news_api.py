"""News endpoints. Handlers are called directly (repo convention); the 401 check
goes through a minimal ASGI app so the real auth dependency runs."""
import uuid
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi import FastAPI, HTTPException

from app.api.routes import news
from app.models.news import NewsItem
from tests.news_helpers import make_customer


def _item(topic_key="premier league", category="sports", title="T", *, age_h=1):
    return NewsItem(
        topic_key=topic_key, category=category, title=title, summary="Short summary", short_version="s", body="b",
        sources=[{"name": "BBC", "url": "https://bbc.example/1"}],
        published_at=datetime.now(timezone.utc) - timedelta(hours=age_h), slot="0500",
    )


async def _list(db, cliente, **kw):
    args = dict(day=None, tz_offset_minutes=0, cursor=None, limit=30, scope="followed")
    args.update(kw)
    return await news.list_news(cliente=cliente, db=db, **args)


@pytest.mark.asyncio
async def test_requires_auth():
    app = FastAPI()
    app.include_router(news.router, prefix="/api")
    nid = "00000000-0000-0000-0000-000000000001"
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        for method, path in [("GET", "/api/news"), ("GET", f"/api/news/{nid}"),
                             ("PUT", f"/api/news/{nid}/read"), ("DELETE", f"/api/news/{nid}/read"),
                             ("POST", "/api/news/read-all")]:
            assert (await c.request(method, path)).status_code == 401, (method, path)


@pytest.mark.asyncio
async def test_list_filters_by_followed_topic_and_category(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="Premier League")
    db.add_all([
        _item(title="Mine by topic"),
        _item(topic_key="la liga", category="sports", title="Mine by category"),
        _item(topic_key="fed", category="markets", title="Not mine"),
        _item(title="Too old", age_h=24 * 8),
    ])
    await db.commit()

    out = await _list(db, me)

    assert {i.title for i in out.items} == {"Mine by topic", "Mine by category"}
    assert out.no_follow_match is False
    assert out.items[0].sources[0].url == "https://bbc.example/1" and out.items[0].read is False


@pytest.mark.asyncio
async def test_nothing_matching_returns_empty_with_flag_and_scope_all_falls_back(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="Gardening", raw_text="gardening tips")
    db.add(_item(topic_key="fed", category="markets", title="Rates"))
    await db.commit()

    out = await _list(db, me)
    assert out.items == [] and out.no_follow_match is True

    fallback = await _list(db, me, scope="all")
    assert [i.title for i in fallback.items] == ["Rates"]


@pytest.mark.asyncio
async def test_read_unread_roundtrip_is_per_customer_and_idempotent(full_db_session):
    db = full_db_session
    a = await make_customer(db, topic="Premier League")
    b = await make_customer(db, topic="Premier League")
    item = _item()
    db.add(item)
    await db.commit()

    assert (await news.mark_read(item.id, cliente=a, db=db))["read"] is True
    await news.mark_read(item.id, cliente=a, db=db)  # idempotent, no unique violation
    assert (await _list(db, a)).items[0].read is True
    assert (await _list(db, b)).items[0].read is False  # other customer unaffected
    assert (await news.get_news(item.id, tz_offset_minutes=0, cliente=a, db=db)).read is True

    assert (await news.mark_unread(item.id, cliente=a, db=db))["read"] is False
    assert (await _list(db, a)).items[0].read is False


@pytest.mark.asyncio
async def test_read_all_marks_visible_items_only(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="Premier League")
    db.add_all([_item(title="a"), _item(title="b"), _item(topic_key="fed", category="markets", title="other")])
    await db.commit()

    assert (await news.read_all(scope="followed", cliente=me, db=db))["marked"] == 2
    assert all(i.read for i in (await _list(db, me)).items)
    assert (await news.read_all(scope="followed", cliente=me, db=db))["marked"] == 0
    everything = (await _list(db, me, scope="all")).items
    assert [i.title for i in everything if not i.read] == ["other"]


@pytest.mark.asyncio
async def test_unknown_item_is_404(full_db_session):
    me = await make_customer(full_db_session, topic="Premier League")
    with pytest.raises(HTTPException) as e:
        await news.mark_read(uuid.uuid4(), cliente=me, db=full_db_session)
    assert e.value.status_code == 404


@pytest.mark.asyncio
async def test_cursor_pagination_and_day_filter(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="Premier League")
    db.add_all([_item(title=f"n{i}", age_h=i + 1) for i in range(5)])
    await db.commit()

    first = await _list(db, me, limit=2)
    second = await _list(db, me, limit=2, cursor=first.next_cursor)
    third = await _list(db, me, limit=2, cursor=second.next_cursor)

    titles = [i.title for p in (first, second, third) for i in p.items]
    assert titles == ["n0", "n1", "n2", "n3", "n4"] and third.next_cursor is None

    assert len((await _list(db, me, day=first.items[0].day)).items) >= 1


@pytest.mark.asyncio
async def test_cursor_pagination_with_identical_published_at(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="Premier League")
    same = datetime.now(timezone.utc) - timedelta(hours=2)
    items = [_item(title=f"same{i}") for i in range(5)]
    for it in items:
        it.published_at = same
    db.add_all(items)
    await db.commit()

    seen, cursor = [], None
    for _ in range(5):
        page = await _list(db, me, limit=2, cursor=cursor)
        seen += [i.id for i in page.items]
        cursor = page.next_cursor
        if cursor is None:
            break
    assert len(seen) == 5 and len(set(seen)) == 5  # tie broken by id: nothing skipped or repeated


@pytest.mark.asyncio
async def test_tz_offset_shifts_day_and_read_minutes(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="Premier League")
    it = _item()
    it.published_at = datetime(2026, 11, 12, 2, 0, tzinfo=timezone.utc)  # Nov 11 21:00 in Bogota
    it.body = " ".join(["word"] * 450)
    db.add(it)
    await db.commit()
    got = await news.get_news(it.id, tz_offset_minutes=0, cliente=me, db=db)
    local = await news.get_news(it.id, tz_offset_minutes=-300, cliente=me, db=db)
    assert str(got.day) == "2026-11-12" and str(local.day) == "2026-11-11"
    assert got.read_minutes == 3


@pytest.mark.asyncio
async def test_internal_news_run_auth_and_bad_slot(monkeypatch):
    from app.api.routes import internal
    from app.core.config import settings

    app = FastAPI()
    app.include_router(internal.router, prefix="/api")
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        monkeypatch.setattr(settings, "INTERNAL_DASHBOARD_KEY", None)
        assert (await c.post("/api/internal/news/run", params={"topic": "x"})).status_code in (401, 404, 503)
        monkeypatch.setattr(settings, "INTERNAL_DASHBOARD_KEY", "secret")
        wrong = await c.post("/api/internal/news/run", params={"topic": "x"}, headers={"X-Internal-Dashboard-Key": "nope"})
        assert wrong.status_code == 401
        bad = await c.post("/api/internal/news/run", params={"topic": "x", "slot": "9999"},
                           headers={"X-Internal-Dashboard-Key": "secret"})
        assert bad.status_code == 422
