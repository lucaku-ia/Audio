"""Event and AICall — System Contracts v0.1, Instrumentation section."""
import uuid
from datetime import datetime
from sqlalchemy import String, DateTime, Integer, Numeric, JSON, ForeignKey
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column
from app.db.session import Base


class Event(Base):
    """Event envelope — v1 catalog (see Instrumentation & Cost PRD, section 5)."""
    __tablename__ = "events"

    event_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(100), index=True)  # from the Instrumentation catalog
    ts: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow, index=True)
    customer_id: Mapped[uuid.UUID | None] = mapped_column(PGUUID(as_uuid=True), nullable=True, index=True)  # anonymized on account deletion
    session_id: Mapped[str | None] = mapped_column(String(100), nullable=True)
    source: Mapped[str] = mapped_column(String(50))  # app | service name
    context: Mapped[dict] = mapped_column(JSON, default=lambda: {})  # {request_id?, episode_id?, block_id?, job_id?, call_id?}
    payload: Mapped[dict] = mapped_column(JSON, default=lambda: {})  # event-specific, no free text


class AICall(Base):
    """Every model call goes through the AI Platform and is logged here."""
    __tablename__ = "ai_calls"

    call_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    prompt: Mapped[str] = mapped_column(String(200))  # versioned prompt name
    version: Mapped[str] = mapped_column(String(50))
    purpose: Mapped[str] = mapped_column(String(100))  # structure_request, research, answer_from_history, ...
    model: Mapped[str] = mapped_column(String(100))
    provider: Mapped[str] = mapped_column(String(50))
    tokens_in: Mapped[int | None] = mapped_column(Integer, nullable=True)
    tokens_out: Mapped[int | None] = mapped_column(Integer, nullable=True)
    characters: Mapped[int | None] = mapped_column(Integer, nullable=True)  # for TTS calls
    cost: Mapped[float] = mapped_column(Numeric(10, 6), default=0)
    latency_ms: Mapped[int] = mapped_column(Integer)
    context: Mapped[dict] = mapped_column(JSON, default=lambda: {})  # {customer_id, request_id?, episode_id?, job_id?}
    rejected_reason: Mapped[str | None] = mapped_column(String(200), nullable=True)
    creado_en: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow, index=True)
