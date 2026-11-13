"""
News feed API (backs the iOS Home news section).

  GET    /news?day=&cursor=&limit=&scope=   items for the caller, last 7 days
  GET    /news/{id}                         one item
  PUT    /news/{id}/read                    mark read   (idempotent)
  DELETE /news/{id}/read                    mark unread (idempotent)
  POST   /news/read-all                     mark every visible item read

Items are shared (topic-keyed); only read state is per customer. "Visible"
means published in the last 7 days AND matching the caller's followed topics
(topic_key) or followed categories (inferred from topics, same rules as the
app). When nothing matches, the list is empty and `no_follow_match` is true so
the app can fall back to the whole feed, which it requests with `scope=all`.
"""
import base64
import uuid
from datetime import date, datetime, time, timedelta, timezone, tzinfo

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import and_, delete, func, or_, select, tuple_
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_cliente
from app.db.session import get_db
from app.models.cliente import Cliente
from app.models.news import NewsItem, NewsReadState
from app.models.profile import Profile
from app.services.news_pipeline import followed_topics_for, resolve_tz

router = APIRouter(prefix="/news", tags=["News"])

WINDOW_DAYS = 7


class NewsSourceOut(BaseModel):
    name: str
    url: str


class NewsItemOut(BaseModel):
    id: str
    topic_key: str
    category: str
    title: str
    summary: str
    short_version: str
    body: str
    sources: list[NewsSourceOut]
    image_hint: str | None
    published_at: datetime
    day: date  # calendar day in the caller's tz (tz_offset_minutes, default UTC), for grouping
    read_minutes: int  # estimate from body word count at ~200 wpm, min 1
    slot: str
    cluster_id: str | None
    read: bool


class NewsListOut(BaseModel):
    items: list[NewsItemOut]
    next_cursor: str | None
    # True when the caller follows nothing that matches any item in the window
    # (items is then empty unless scope=all): the app falls back to scope=all.
    no_follow_match: bool
    followed_topics: list[str]
    followed_categories: list[str]


async def _caller_tz(db: AsyncSession, cliente: Cliente, tz_offset_minutes: int | None) -> tzinfo:
    """An explicit tz_offset_minutes wins (fixed offset). Without it, the
    caller's stored Profile.delivery_timezone (IANA, DST-aware), else UTC."""
    if tz_offset_minutes is not None:
        return timezone(timedelta(minutes=tz_offset_minutes))
    name = (await db.execute(select(Profile.delivery_timezone).where(Profile.customer_id == cliente.id))).scalar_one_or_none()
    return resolve_tz(name)[1]


def _out(item: NewsItem, read_at, tz: tzinfo = timezone.utc) -> NewsItemOut:
    published = item.published_at if item.published_at.tzinfo else item.published_at.replace(tzinfo=timezone.utc)
    return NewsItemOut(
        id=str(item.id), topic_key=item.topic_key, category=item.category, title=item.title,
        summary=item.summary, short_version=item.short_version, body=item.body,
        sources=[NewsSourceOut(**s) for s in (item.sources or [])],
        image_hint=item.image_hint, published_at=published, day=published.astimezone(tz).date(),
        read_minutes=max(1, -(-len(item.body.split()) // 200)),
        slot=item.slot, cluster_id=str(item.cluster_id) if item.cluster_id else None,
        read=read_at is not None,
    )


def _encode_cursor(item: NewsItem) -> str:
    published = item.published_at if item.published_at.tzinfo else item.published_at.replace(tzinfo=timezone.utc)
    return base64.urlsafe_b64encode(f"{published.isoformat()}|{item.id}".encode()).decode()


def _decode_cursor(cursor: str) -> tuple[datetime, uuid.UUID]:
    try:
        raw = base64.urlsafe_b64decode(cursor.encode()).decode()
        ts, item_id = raw.split("|", 1)
        return datetime.fromisoformat(ts), uuid.UUID(item_id)
    except Exception:
        raise HTTPException(422, "Invalid cursor")


def _window_start() -> datetime:
    return datetime.now(timezone.utc) - timedelta(days=WINDOW_DAYS)


def _follow_filter(keys: set[str], cats: set[str]):
    clauses = []
    if keys:
        clauses.append(NewsItem.topic_key.in_(keys))
    if cats:
        clauses.append(NewsItem.category.in_(cats))
    return or_(*clauses) if clauses else None


async def _visible_filters(db: AsyncSession, cliente: Cliente, scope: str):
    """(where-clauses, no_follow_match, keys, cats) for the caller's feed."""
    keys, cats = await followed_topics_for(db, cliente.id)
    base = [NewsItem.published_at >= _window_start()]
    follow = _follow_filter(keys, cats)
    matched = 0
    if follow is not None:
        matched = (await db.execute(select(func.count()).select_from(NewsItem).where(*base, follow))).scalar_one()
    no_match = matched == 0
    if scope == "all":
        return base, no_match, keys, cats
    if no_match:
        # Impossible clause: an empty list plus the explicit flag.
        return base + [NewsItem.id.is_(None)], True, keys, cats
    return base + [follow], False, keys, cats


@router.get("", response_model=NewsListOut)
async def list_news(
    day: date | None = Query(default=None, description="Only this day (YYYY-MM-DD) in the caller's tz."),
    tz_offset_minutes: int | None = Query(default=None, ge=-840, le=840, description="Caller's UTC offset in minutes (e.g. -300 for Bogota). When absent, the stored profile timezone is used (UTC if none)."),
    cursor: str | None = None,
    limit: int = Query(default=30, ge=1, le=100),
    scope: str = Query(default="followed", pattern="^(followed|all)$"),
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    where, no_match, keys, cats = await _visible_filters(db, cliente, scope)
    tz = await _caller_tz(db, cliente, tz_offset_minutes)
    if day is not None:
        start = datetime(day.year, day.month, day.day, tzinfo=tz).astimezone(timezone.utc)
        end = datetime.combine(day + timedelta(days=1), time.min, tzinfo=tz).astimezone(timezone.utc)
        where += [NewsItem.published_at >= start, NewsItem.published_at < end]
    if cursor:
        ts, item_id = _decode_cursor(cursor)
        where.append(tuple_(NewsItem.published_at, NewsItem.id) < tuple_(ts, item_id))

    rows = (await db.execute(
        select(NewsItem, NewsReadState.read_at)
        .outerjoin(NewsReadState, and_(NewsReadState.news_id == NewsItem.id, NewsReadState.cliente_id == cliente.id))
        .where(*where)
        .order_by(NewsItem.published_at.desc(), NewsItem.id.desc())
        .limit(limit + 1)
    )).all()
    page = rows[:limit]
    return NewsListOut(
        items=[_out(item, read_at, tz) for item, read_at in page],
        next_cursor=_encode_cursor(page[-1][0]) if len(rows) > limit and page else None,
        no_follow_match=no_match,
        followed_topics=sorted(keys),
        followed_categories=sorted(cats),
    )


@router.post("/read-all")
async def read_all(
    scope: str = Query(default="followed", pattern="^(followed|all)$"),
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    where, no_match, _, _ = await _visible_filters(db, cliente, scope)
    if no_match and scope != "all":
        # Mirrors the app: with nothing matching, "the feed" is everything.
        where, _, _, _ = await _visible_filters(db, cliente, "all")
    already = select(NewsReadState.news_id).where(NewsReadState.cliente_id == cliente.id)
    ids = (await db.execute(select(NewsItem.id).where(*where, NewsItem.id.not_in(already)))).scalars().all()
    if ids:
        await db.execute(
            pg_insert(NewsReadState).values([{"id": uuid.uuid4(), "cliente_id": cliente.id, "news_id": i} for i in ids])
            .on_conflict_do_nothing(constraint="uq_news_read_cliente_news")
        )
        await db.commit()
    return {"marked": len(ids)}


async def _get_item(db: AsyncSession, news_id: uuid.UUID) -> NewsItem:
    item = (await db.execute(select(NewsItem).where(NewsItem.id == news_id))).scalar_one_or_none()
    if item is None:
        raise HTTPException(404, "News item not found")
    return item


@router.get("/{news_id}", response_model=NewsItemOut)
async def get_news(
    news_id: uuid.UUID,
    tz_offset_minutes: int | None = Query(default=None, ge=-840, le=840),
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    item = await _get_item(db, news_id)
    read_at = (await db.execute(
        select(NewsReadState.read_at).where(NewsReadState.news_id == news_id, NewsReadState.cliente_id == cliente.id)
    )).scalar_one_or_none()
    return _out(item, read_at, await _caller_tz(db, cliente, tz_offset_minutes))


@router.put("/{news_id}/read")
async def mark_read(
    news_id: uuid.UUID,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    await _get_item(db, news_id)
    await db.execute(
        pg_insert(NewsReadState).values(id=uuid.uuid4(), cliente_id=cliente.id, news_id=news_id)
        .on_conflict_do_nothing(constraint="uq_news_read_cliente_news")
    )
    await db.commit()
    return {"id": str(news_id), "read": True}


@router.delete("/{news_id}/read")
async def mark_unread(
    news_id: uuid.UUID,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    await _get_item(db, news_id)
    await db.execute(delete(NewsReadState).where(NewsReadState.news_id == news_id, NewsReadState.cliente_id == cliente.id))
    await db.commit()
    return {"id": str(news_id), "read": False}
