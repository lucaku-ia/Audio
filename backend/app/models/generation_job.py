"""GenerationJob and InventoryItem — System Contracts v0.1."""
import enum
import uuid
from datetime import datetime, date as date_type
from sqlalchemy import DateTime, Date, JSON, ForeignKey, Enum as SAEnum, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column
from app.db.session import Base
from app.models.episode import EpisodePath


class JobStatus(str, enum.Enum):
    queued = "queued"
    researching = "researching"
    writing = "writing"
    voicing = "voicing"
    ready = "ready"
    late = "late"
    empty = "empty"
    failed = "failed"


class GenerationJob(Base):
    __tablename__ = "generation_jobs"
    # One job per (customer, date, path) — see app.services.episode_generator.run_generation,
    # which checks for an existing row before inserting. On an existing DB (create_all won't
    # add this to a table that already exists) this is also backfilled in app/db/migraciones.py.
    __table_args__ = (
        UniqueConstraint("customer_id", "fecha", "path", name="uq_generation_jobs_customer_fecha_path"),
    )

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), ForeignKey("clientes.id"), index=True)
    fecha: Mapped[date_type] = mapped_column(Date)
    path: Mapped[EpisodePath] = mapped_column(SAEnum(EpisodePath, name="job_path"))
    status: Mapped[JobStatus] = mapped_column(SAEnum(JobStatus, name="job_status"), default=JobStatus.queued)
    eta: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    snapshot: Mapped[dict] = mapped_column(JSON, default=lambda: {})  # active_for_generation result that was used
    stages: Mapped[list] = mapped_column(JSON, default=lambda: [])  # [{name, started, completed, cost, latency}]
    creado_en: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)


class InventoryItem(Base):
    __tablename__ = "inventory_items"

    episode_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), ForeignKey("episodes.id"), primary_key=True)
    tags: Mapped[list] = mapped_column(JSON, default=lambda: [])
    seed_request_text: Mapped[str] = mapped_column(String(1000))
    reason_template: Mapped[str | None] = mapped_column(String(500), nullable=True)
