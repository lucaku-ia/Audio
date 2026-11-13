"""
Feedback, FeedbackSignal and ProblemReport (backlog T-402, adapted to FastAPI).

Feedback is the per-target record ("Useful" / "Not quite" + reasons +
suggestion), unique per (cliente, target_type, target_id), so useful and
not_quite are exclusive per target by construction.

FeedbackSignal is the aggregate the generator can read cheaply: one row per
(cliente, subject) where the subject is a request (stories, episodes) or a
news topic_key. It is updated in the SAME transaction as the Feedback row, and
every contribution is reversible: Feedback.effects remembers exactly which
subjects were bumped (and which requests were paused), so toggling off or
changing a rating undoes precisely what was applied.
"""
import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, DateTime, ForeignKey, Index, Integer, String, Text, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.session import Base


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Feedback(Base):
    __tablename__ = "feedback"
    __table_args__ = (
        UniqueConstraint("cliente_id", "target_type", "target_id", name="uq_feedback_cliente_target"),
    )

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    cliente_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), ForeignKey("clientes.id", ondelete="CASCADE"), index=True)
    target_type: Mapped[str] = mapped_column(String(20))  # story | episode | news
    target_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True))  # block id | episode id | news item id
    rating: Mapped[str] = mapped_column(String(20))  # useful | not_quite
    reasons: Mapped[list] = mapped_column(JSON, default=lambda: [])
    suggestion: Mapped[str | None] = mapped_column(Text, nullable=True)
    # {"subjects": [["request", "<id>"] | ["topic", "<key>"], ...], "paused_requests": ["<id>", ...]}
    effects: Mapped[dict] = mapped_column(JSON, default=lambda: {})
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, onupdate=_utcnow)


class FeedbackSignal(Base):
    __tablename__ = "feedback_signals"
    __table_args__ = (
        UniqueConstraint("cliente_id", "subject_type", "subject_key", name="uq_feedback_signal_subject"),
    )

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    cliente_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), ForeignKey("clientes.id", ondelete="CASCADE"), index=True)
    subject_type: Mapped[str] = mapped_column(String(20))  # request | topic
    subject_key: Mapped[str] = mapped_column(String(300))  # request id | news topic_key
    useful: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    not_quite: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    too_long: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    too_short: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    not_relevant: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    needs_more_detail: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    too_technical: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    stop_topic: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    score: Mapped[int] = mapped_column(Integer, default=0, server_default="0")  # useful - not_quite
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, onupdate=_utcnow)


class ProblemReport(Base):
    __tablename__ = "problem_reports"
    __table_args__ = (Index("ix_problem_reports_target", "target_type", "target_id"),)

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    cliente_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), ForeignKey("clientes.id", ondelete="CASCADE"), index=True)
    target_type: Mapped[str] = mapped_column(String(20))
    target_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True))
    text: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)
