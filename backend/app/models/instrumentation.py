"""Event y AICall — System Contracts v0.1, sección de Instrumentación."""
import uuid
from datetime import datetime
from sqlalchemy import String, DateTime, Integer, Numeric, JSON, ForeignKey
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column
from app.db.session import Base


class Event(Base):
    """Envelope de evento — catálogo v1 (ver Instrumentation & Cost PRD, sección 5)."""
    __tablename__ = "events"

    event_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(100), index=True)  # del catálogo de Instrumentation
    ts: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow, index=True)
    customer_id: Mapped[uuid.UUID | None] = mapped_column(PGUUID(as_uuid=True), nullable=True, index=True)  # anonimizado al borrar cuenta
    session_id: Mapped[str | None] = mapped_column(String(100), nullable=True)
    source: Mapped[str] = mapped_column(String(50))  # app | nombre del servicio
    context: Mapped[dict] = mapped_column(JSON, default=lambda: {})  # {request_id?, episode_id?, block_id?, job_id?, call_id?}
    payload: Mapped[dict] = mapped_column(JSON, default=lambda: {})  # específico del evento, sin texto libre


class AICall(Base):
    """Toda llamada a un modelo pasa por la AI Platform y queda registrada aquí."""
    __tablename__ = "ai_calls"

    call_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    prompt: Mapped[str] = mapped_column(String(200))  # nombre del prompt versionado
    version: Mapped[str] = mapped_column(String(50))
    purpose: Mapped[str] = mapped_column(String(100))  # structure_request, research, answer_from_history, ...
    model: Mapped[str] = mapped_column(String(100))
    provider: Mapped[str] = mapped_column(String(50))
    tokens_in: Mapped[int | None] = mapped_column(Integer, nullable=True)
    tokens_out: Mapped[int | None] = mapped_column(Integer, nullable=True)
    characters: Mapped[int | None] = mapped_column(Integer, nullable=True)  # para llamadas de TTS
    cost: Mapped[float] = mapped_column(Numeric(10, 6), default=0)
    latency_ms: Mapped[int] = mapped_column(Integer)
    context: Mapped[dict] = mapped_column(JSON, default=lambda: {})  # {customer_id, request_id?, episode_id?, job_id?}
    rejected_reason: Mapped[str | None] = mapped_column(String(200), nullable=True)
    creado_en: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow, index=True)
