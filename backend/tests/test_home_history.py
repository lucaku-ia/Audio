"""Extended GET /home (next_delivery, followed_topics, news) and GET /episodes (history).
Handlers are called directly (repo convention). No model calls anywhere."""
from datetime import datetime, time, timedelta, timezone

import pytest
from fastapi import HTTPException
from sqlalchemy import event

from app.api.routes import history, home
from app.models.episode import Block, Episode, EpisodePath
from app.models.news import NewsItem
from app.models.profile import Profile
from tests.news_helpers import make_customer


def _news(topic_key="premier league", category="sports", title="T", age_h=1):
    return NewsItem(topic_key=topic_key, category=category, title=title, summary="s", short_version="s", body="b",
                    sources=[], published_at=datetime.now(timezone.utc) - timedelta(hours=age_h), slot="0500")


def _episode(cid, headline, age_h, shared=False):
    ts = datetime.now(timezone.utc) - timedelta(hours=age_h)
    return Episode(customer_id=cid, shared=shared, fecha=ts.date(), path=EpisodePath.scheduled, headline=headline,
                   style="news", duration_s=300, published_at=ts)


def test_next_delivery_today_and_tomorrow():
    perfil = Profile(customer_id=None, delivery_time=time(7, 0), delivery_timezone="America/Bogota")
    now = datetime(2026, 11, 12, 10, 0, tzinfo=timezone.utc)  # 05:00 in Bogota
    nd = home.compute_next_delivery(perfil, now)
    assert nd.is_today and nd.local_time == "07:00" and nd.at == datetime(2026, 11, 12, 12, 0, tzinfo=timezone.utc)
    nd = home.compute_next_delivery(perfil, datetime(2026, 11, 12, 13, 0, tzinfo=timezone.utc))
    assert not nd.is_today and nd.at == datetime(2026, 11, 13, 12, 0, tzinfo=timezone.utc)
    assert nd.at.tzinfo is not None and nd.timezone == "America/Bogota"
    assert home.compute_next_delivery(None) is None
    assert home.compute_next_delivery(Profile(customer_id=None, delivery_time=None)) is None


@pytest.mark.asyncio
async def test_home_returns_extras_with_constant_query_count(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="Premier League")
    db.add(Profile(customer_id=me.id, delivery_time=time(7, 0), delivery_timezone="America/Bogota"))
    db.add_all([_news(title="Mine"), _news(topic_key="fed", category="markets", title="Other")])
    await db.commit()

    counts = []
    sync_engine = db.bind.sync_engine

    def _count(*_a, **_k):
        counts.append(1)

    event.listen(sync_engine, "before_cursor_execute", _count)
    try:
        out = await home.home(cliente=me, db=db)
        small = len(counts)
        # Many more rows must not add queries.
        db.add_all([_news(title=f"n{i}") for i in range(15)])
        for i in range(5):
            db.add(_episode(me.id, f"ep{i}", i + 1))
        await db.commit()
        counts.clear()
        await home.home(cliente=me, db=db)
        big = len(counts)
    finally:
        event.remove(sync_engine, "before_cursor_execute", _count)

    assert out.next_delivery.local_time == "07:00" and out.next_delivery.at.tzinfo is not None
    assert [t.topic for t in out.followed_topics] == ["Premier League"]
    assert out.followed_topics[0].category == "sports" and out.followed_topics[0].icon == "sports"
    assert [i.title for i in out.news.items] == ["Mine"] and out.news.no_follow_match is False
    assert big == small and big <= 20


@pytest.mark.asyncio
async def test_home_news_falls_back_to_all_and_is_backward_compatible(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="Gardening", raw_text="gardening tips")
    db.add(_news(topic_key="fed", category="markets", title="Rates"))
    await db.commit()
    out = await home.home(cliente=me, db=db)
    assert [i.title for i in out.news.items] == ["Rates"]
    assert out.next_delivery is None
    assert out.banner.state and out.recent == [] and out.shared_inventory == []


async def _list(db, me, **kw):
    args = dict(before=None, q=None, limit=20)
    args.update(kw)
    return await history.list_episodes(cliente=me, db=db, **args)


@pytest.mark.asyncio
async def test_history_order_pagination_and_isolation(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="A")
    other = await make_customer(db, topic="B")
    mine = [_episode(me.id, f"mine{i}", i + 1) for i in range(5)]
    db.add_all(mine + [_episode(other.id, "theirs", 1), _episode(None, "shared", 1, shared=True)])
    db.add(Episode(customer_id=me.id, fecha=datetime.now(timezone.utc).date(), path=EpisodePath.scheduled,
                   headline="unpublished", published_at=None))
    await db.commit()
    db.add_all([Block(episode_id=mine[0].id, start_s=0, end_s=10, summary="s1", script="x"),
                Block(episode_id=mine[0].id, start_s=10, end_s=20, summary="s2", script="x")])
    await db.commit()

    p1 = await _list(db, me, limit=2)
    assert [i.headline for i in p1.items] == ["mine0", "mine1"] and p1.next_cursor
    assert p1.items[0].blocks_count == 2 and p1.items[1].blocks_count == 0
    assert p1.items[0].published_at.tzinfo is not None and p1.items[0].state == "completed"
    p2 = await _list(db, me, limit=2, before=p1.next_cursor)
    assert [i.headline for i in p2.items] == ["mine2", "mine3"]
    p3 = await _list(db, me, limit=2, before=p2.next_cursor)
    assert [i.headline for i in p3.items] == ["mine4"] and p3.next_cursor is None
    everything = await _list(db, me)
    assert {i.headline for i in everything.items} == {f"mine{i}" for i in range(5)}  # no other customer, shared or draft

    by_date = await _list(db, me, before=(datetime.now(timezone.utc) + timedelta(days=1)).date().isoformat())
    assert len(by_date.items) == 5
    with pytest.raises(HTTPException) as e:
        await _list(db, me, before="garbage")
    assert e.value.status_code == 422


@pytest.mark.asyncio
async def test_history_search_is_case_insensitive_and_safe(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="A")
    other = await make_customer(db, topic="B")
    e1, e2, e3 = _episode(me.id, "Arsenal win the derby", 3), _episode(me.id, "Markets quiet", 2), _episode(me.id, "100% sure", 1)
    theirs = _episode(other.id, "Arsenal secret", 1)
    db.add_all([e1, e2, e3, theirs])
    await db.commit()
    db.add(Block(episode_id=e2.id, start_s=0, end_s=5, summary="Spurs lose again", script="x"))
    await db.commit()

    assert [i.headline for i in (await _list(db, me, q="ARSENAL")).items] == ["Arsenal win the derby"]
    assert [i.headline for i in (await _list(db, me, q="spurs")).items] == ["Markets quiet"]
    assert [i.headline for i in (await _list(db, me, q="100%")).items] == ["100% sure"]
    assert [i.headline for i in (await _list(db, me, q="%")).items] == ["100% sure"]
    assert (await _list(db, me, q="x'; DROP TABLE episodes;--")).items == []
    assert len((await _list(db, me)).items) == 3
