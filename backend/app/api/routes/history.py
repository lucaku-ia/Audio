"""
Episode history (iOS "History" screen).

  GET /episodes?before=&q=&limit=   the caller's past episodes, newest first

Only the caller's own published episodes are listed (shared-inventory samples
are not history). `GET /episodes/{id}` is NOT duplicated here: use the existing
`GET /generation/episodes/{id}` (own episode or shared sample, 404 otherwise).

Pagination is keyset-based on (published_at, id). `before` accepts either the
opaque `next_cursor` from a previous page, or a plain ISO date (YYYY-MM-DD:
episodes of strictly earlier days) / ISO datetime (published strictly before it).

`q` is a case-insensitive substring search (ILIKE with bound, escaped
parameters) over the episode headline and its blocks' one-line summaries.
"""
import base64
import uuid
from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import func, or_, select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_cliente
from app.db.session import get_db
from app.models.cliente import Cliente
from app.models.episode import Block, Episode

router = APIRouter(prefix="/episodes", tags=["History"])

_CURSOR_PREFIX = "c1."


class HistoryEpisodeOut(BaseModel):
    id: str
    date: date
    headline: str | None
    duration_s: int | None
    style: str | None
    state: str  # always "completed": only published episodes are listed
    blocks_count: int
    published_at: datetime  # timezone-aware (UTC)


class HistoryOut(BaseModel):
    items: list[HistoryEpisodeOut]
    next_cursor: str | None


def _aware(ts: datetime) -> datetime:
    return ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)


def _encode_cursor(ep: Episode) -> str:
    raw = f"{_aware(ep.published_at).isoformat()}|{ep.id}"
    return _CURSOR_PREFIX + base64.urlsafe_b64encode(raw.encode()).decode()


def _before_clause(before: str):
    if before.startswith(_CURSOR_PREFIX):
        try:
            raw = base64.urlsafe_b64decode(before[len(_CURSOR_PREFIX):].encode()).decode()
            ts, ep_id = raw.split("|", 1)
            return tuple_(Episode.published_at, Episode.id) < tuple_(_aware(datetime.fromisoformat(ts)), uuid.UUID(ep_id))
        except Exception:
            raise HTTPException(422, "Invalid cursor")
    try:
        if len(before) == 10:
            return Episode.fecha < date.fromisoformat(before)
        return Episode.published_at < _aware(datetime.fromisoformat(before))
    except ValueError:
        raise HTTPException(422, "Invalid 'before': expected a cursor, YYYY-MM-DD or an ISO datetime")


def _like_pattern(q: str) -> str:
    escaped = q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


@router.get("", response_model=HistoryOut)
async def list_episodes(
    before: str | None = Query(default=None, max_length=200),
    q: str | None = Query(default=None, max_length=200),
    limit: int = Query(default=20, ge=1, le=50),
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    blocks_count = (
        select(func.count(Block.id)).where(Block.episode_id == Episode.id).correlate(Episode).scalar_subquery()
    )
    stmt = select(Episode, blocks_count).where(
        Episode.customer_id == cliente.id, Episode.published_at.is_not(None)
    )
    if before:
        stmt = stmt.where(_before_clause(before))
    if q and q.strip():
        pattern = _like_pattern(q.strip())
        stmt = stmt.where(or_(
            Episode.headline.ilike(pattern, escape="\\"),
            select(Block.id).where(Block.episode_id == Episode.id, Block.summary.ilike(pattern, escape="\\"))
            .correlate(Episode).exists(),
        ))
    rows = (await db.execute(
        stmt.order_by(Episode.published_at.desc(), Episode.id.desc()).limit(limit + 1)
    )).all()
    page = rows[:limit]
    return HistoryOut(
        items=[
            HistoryEpisodeOut(
                id=str(ep.id), date=ep.fecha, headline=ep.headline, duration_s=ep.duration_s, style=ep.style,
                state="completed", blocks_count=count or 0, published_at=_aware(ep.published_at),
            )
            for ep, count in page
        ],
        next_cursor=_encode_cursor(page[-1][0]) if len(rows) > limit and page else None,
    )
