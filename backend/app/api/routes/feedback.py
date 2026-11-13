"""
Feedback and signals API (backlog T-402).

  POST /feedback          upsert a rating; sending the SAME payload again toggles it off
  GET  /feedback          saved state for a set of targets (target_type + target_ids)
  POST /feedback/report   "Report a problem" (target + free text)

Rating rules:
  * One row per (customer, target_type, target_id), so useful / not_quite are exclusive.
  * Same rating + same reasons + same suggestion as what is stored = toggle OFF:
    the row is deleted and its signal contribution reversed.
  * Same rating with different reasons/suggestion = update (the "Not quite" sheet
    submits after the thumb was already sent). The other rating = switch.
  * Signal changes happen in the same transaction as the Feedback write.

Generation wiring is deliberately minimal: "stop covering this topic" on a story
pauses that story's request (reversed if the feedback is removed or changed).
Everything else (too_long, too_short, ...) is only stored in feedback_signals.
"""
import uuid
from datetime import datetime, timezone
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_cliente
from app.db.session import get_db
from app.models.cliente import Cliente
from app.models.episode import Block, Episode
from app.models.feedback import Feedback, FeedbackSignal, ProblemReport
from app.models.news import NewsItem
from app.models.request import Request, RequestStatus
from app.services.events import emitir

router = APIRouter(prefix="/feedback", tags=["Feedback"])

TargetType = Literal["story", "episode", "news"]
Rating = Literal["useful", "not_quite"]
Reason = Literal["too_long", "too_short", "not_relevant", "needs_more_detail", "too_technical", "stop_topic"]

MAX_TARGET_IDS = 100


class FeedbackIn(BaseModel):
    target_type: TargetType
    target_id: uuid.UUID
    rating: Rating
    reasons: list[Reason] = Field(default_factory=list, max_length=6)
    suggestion: str | None = Field(default=None, max_length=2000)

    @field_validator("reasons")
    @classmethod
    def _dedupe(cls, v):
        return sorted(set(v))

    @field_validator("suggestion")
    @classmethod
    def _strip(cls, v):
        v = (v or "").strip()
        return v or None


class FeedbackOut(BaseModel):
    target_type: str
    target_id: str
    rating: str
    reasons: list[str]
    suggestion: str | None
    updated_at: datetime


class FeedbackResult(BaseModel):
    removed: bool
    feedback: FeedbackOut | None


class ReportIn(BaseModel):
    target_type: TargetType
    target_id: uuid.UUID
    text: str = Field(min_length=1, max_length=2000)

    @field_validator("text")
    @classmethod
    def _strip(cls, v):
        v = v.strip()
        if not v:
            raise ValueError("text must not be blank")
        return v


class ReportOut(BaseModel):
    id: str


def _out(fb: Feedback) -> FeedbackOut:
    updated = fb.updated_at if fb.updated_at.tzinfo else fb.updated_at.replace(tzinfo=timezone.utc)
    return FeedbackOut(target_type=fb.target_type, target_id=str(fb.target_id), rating=fb.rating,
                       reasons=list(fb.reasons or []), suggestion=fb.suggestion, updated_at=updated)


async def _resolve_subjects(db: AsyncSession, cliente: Cliente, target_type: str, target_id: uuid.UUID) -> list[list[str]]:
    """Validate the target exists and is visible to the caller; return its signal subjects."""
    if target_type == "story":
        row = (await db.execute(
            select(Block.request_id, Episode.customer_id, Episode.shared)
            .join(Episode, Episode.id == Block.episode_id).where(Block.id == target_id)
        )).first()
        if row is None or not (row.customer_id == cliente.id or row.shared):
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Story not found")
        return [["request", str(row.request_id)]] if row.request_id else []
    if target_type == "episode":
        ep = (await db.execute(select(Episode).where(Episode.id == target_id))).scalar_one_or_none()
        if ep is None or not (ep.customer_id == cliente.id or ep.shared):
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Episode not found")
        rids = (await db.execute(
            select(Block.request_id).where(Block.episode_id == target_id, Block.request_id.is_not(None)).distinct()
        )).scalars().all()
        return [["request", str(r)] for r in sorted(rids, key=str)]
    item = (await db.execute(select(NewsItem).where(NewsItem.id == target_id))).scalar_one_or_none()
    if item is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "News item not found")
    return [["topic", item.topic_key]]


def _deltas(rating: str, reasons: list[str]) -> dict[str, int]:
    d = {rating: 1, "score": 1 if rating == "useful" else -1}
    for r in reasons:
        d[r] = 1
    return d


async def _bump(db: AsyncSession, cliente_id: uuid.UUID, subject: list[str], deltas: dict[str, int], sign: int) -> None:
    """Atomic counter update (INSERT .. ON CONFLICT DO UPDATE). Counters never go below zero."""
    cols = FeedbackSignal.__table__.c
    now = datetime.now(timezone.utc)
    inserts = {k: max(v * sign, 0) for k, v in deltas.items() if k != "score"}
    inserts["score"] = deltas.get("score", 0) * sign
    updates = {k: func.greatest(0, cols[k] + v * sign) for k, v in deltas.items() if k != "score"}
    if "score" in deltas:
        updates["score"] = cols.score + deltas["score"] * sign
    updates["updated_at"] = now
    stmt = pg_insert(FeedbackSignal).values(
        id=uuid.uuid4(), cliente_id=cliente_id, subject_type=subject[0], subject_key=subject[1],
        updated_at=now, **inserts,
    ).on_conflict_do_update(constraint="uq_feedback_signal_subject", set_=updates)
    await db.execute(stmt)


async def _apply(db: AsyncSession, cliente: Cliente, fb: Feedback, subjects: list[list[str]]) -> None:
    deltas = _deltas(fb.rating, list(fb.reasons or []))
    for s in subjects:
        await _bump(db, cliente.id, s, deltas, +1)
    paused: list[str] = []
    # "Stop covering this topic" on a story: pause that story's request.
    if fb.target_type == "story" and "stop_topic" in (fb.reasons or []):
        for s in subjects:
            if s[0] != "request":
                continue
            req = (await db.execute(select(Request).where(
                Request.id == uuid.UUID(s[1]), Request.customer_id == cliente.id))).scalar_one_or_none()
            if req is not None and req.status == RequestStatus.active:
                req.status = RequestStatus.paused
                paused.append(s[1])
                await emitir(db, "request_paused", customer_id=cliente.id, source="feedback", request_id=s[1])
    fb.effects = {"subjects": subjects, "paused_requests": paused}


async def _other_stop_topic_feedback(db: AsyncSession, cliente: Cliente, fb: Feedback, rid: str) -> Feedback | None:
    rows = (await db.execute(
        select(Feedback)
        .join(Block, Block.id == Feedback.target_id)
        .where(Feedback.cliente_id == cliente.id, Feedback.target_type == "story",
               Feedback.id != fb.id, Block.request_id == uuid.UUID(rid))
        .order_by(Feedback.created_at, Feedback.id)
    )).scalars().all()
    return next((r for r in rows if "stop_topic" in (r.reasons or [])), None)


async def _reverse(db: AsyncSession, cliente: Cliente, fb: Feedback) -> None:
    effects = fb.effects or {}
    deltas = _deltas(fb.rating, list(fb.reasons or []))
    for s in effects.get("subjects", []):
        await _bump(db, cliente.id, s, deltas, -1)
    for rid in effects.get("paused_requests", []):
        req = (await db.execute(select(Request).where(
            Request.id == uuid.UUID(rid), Request.customer_id == cliente.id))).scalar_one_or_none()
        if req is not None and req.status == RequestStatus.paused:
            # Another stop_topic story feedback for this request still stands:
            # it inherits the pause, so the request stays paused until that
            # one is removed too.
            heir = await _other_stop_topic_feedback(db, cliente, fb, rid)
            if heir is not None:
                heir.effects = {**(heir.effects or {}),
                                "paused_requests": [*(heir.effects or {}).get("paused_requests", []), rid]}
                continue
            req.status = RequestStatus.active
            await emitir(db, "request_resumed", customer_id=cliente.id, source="feedback", request_id=rid)
    fb.effects = {}


async def _lock_existing(db: AsyncSession, cliente_id: uuid.UUID, body: FeedbackIn) -> Feedback | None:
    return (await db.execute(
        select(Feedback).where(Feedback.cliente_id == cliente_id, Feedback.target_type == body.target_type,
                               Feedback.target_id == body.target_id).with_for_update()
    )).scalar_one_or_none()


@router.post("", response_model=FeedbackResult)
async def submit_feedback(
    body: FeedbackIn,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    subjects = await _resolve_subjects(db, cliente, body.target_type, body.target_id)
    existing = await _lock_existing(db, cliente.id, body)

    if existing is not None:
        same = (existing.rating == body.rating and sorted(existing.reasons or []) == body.reasons
                and (existing.suggestion or None) == body.suggestion)
        await _reverse(db, cliente, existing)
        if same:  # toggle off
            await db.delete(existing)
            await emitir(db, "feedback_submitted", customer_id=cliente.id, source="feedback",
                         target_type=body.target_type, rating=body.rating, reasons=body.reasons,
                         has_suggestion=body.suggestion is not None, action="removed")
            await db.commit()
            return FeedbackResult(removed=True, feedback=None)
        existing.rating, existing.reasons, existing.suggestion = body.rating, body.reasons, body.suggestion
        existing.updated_at = datetime.now(timezone.utc)
        fb, action = existing, "updated"
    else:
        fb = Feedback(cliente_id=cliente.id, target_type=body.target_type, target_id=body.target_id,
                      rating=body.rating, reasons=body.reasons, suggestion=body.suggestion)
        try:
            async with db.begin_nested():
                db.add(fb)
                await db.flush()
        except IntegrityError:
            # A concurrent request created the row first: treat ours as an update of it.
            existing = await _lock_existing(db, cliente.id, body)
            if existing is None:
                raise
            await _reverse(db, cliente, existing)
            existing.rating, existing.reasons, existing.suggestion = body.rating, body.reasons, body.suggestion
            existing.updated_at = datetime.now(timezone.utc)
            fb, action = existing, "updated"
        else:
            action = "created"

    await _apply(db, cliente, fb, subjects)
    await emitir(db, "feedback_submitted", customer_id=cliente.id, source="feedback",
                 target_type=body.target_type, rating=body.rating, reasons=body.reasons,
                 has_suggestion=body.suggestion is not None, action=action)
    await db.commit()
    await db.refresh(fb)
    return FeedbackResult(removed=False, feedback=_out(fb))


@router.get("", response_model=list[FeedbackOut])
async def get_feedback(
    target_type: TargetType,
    target_ids: str = Query(..., max_length=4000, description="Comma-separated target ids (max 100)"),
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    try:
        ids = list({uuid.UUID(p.strip()) for p in target_ids.split(",") if p.strip()})
    except ValueError:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "target_ids must be comma-separated UUIDs")
    if not ids:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "target_ids is required")
    if len(ids) > MAX_TARGET_IDS:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"At most {MAX_TARGET_IDS} target_ids")
    rows = (await db.execute(
        select(Feedback).where(Feedback.cliente_id == cliente.id, Feedback.target_type == target_type,
                               Feedback.target_id.in_(ids))
    )).scalars().all()
    return [_out(r) for r in rows]


@router.post("/report", response_model=ReportOut, status_code=status.HTTP_201_CREATED)
async def report_problem(
    body: ReportIn,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    await _resolve_subjects(db, cliente, body.target_type, body.target_id)  # 404 on a bad target
    report = ProblemReport(cliente_id=cliente.id, target_type=body.target_type, target_id=body.target_id, text=body.text)
    db.add(report)
    await db.flush()
    await emitir(db, "problem_reported", customer_id=cliente.id, source="feedback",
                 target_type=body.target_type, report_id=str(report.id))
    await db.commit()
    return ReportOut(id=str(report.id))
