"""Request and RequestVersion — System Contracts v0.1, section 1."""
import enum
import uuid
from datetime import datetime
from sqlalchemy import String, DateTime, Text, JSON, ForeignKey, Enum as SAEnum
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column
from app.db.session import Base


class RequestKind(str, enum.Enum):
    standing = "standing"
    one_off = "one_off"


class RequestStatus(str, enum.Enum):
    active = "active"
    paused = "paused"
    archived = "archived"
    fulfilled = "fulfilled"


class CreatedFrom(str, enum.Enum):
    onboarding = "onboarding"
    interests = "interests"
    suggestion = "suggestion"
    search = "search"
    home_empty_day = "home_empty_day"


class VersionSource(str, enum.Enum):
    create = "create"
    edit = "edit"
    refine_less = "refine_less"
    refine_deeper = "refine_deeper"


class VersionStatus(str, enum.Enum):
    applied = "applied"
    pending = "pending"
    superseded = "superseded"


class Request(Base):
    __tablename__ = "requests"

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), ForeignKey("clientes.id"), index=True)
    kind: Mapped[RequestKind] = mapped_column(SAEnum(RequestKind, name="request_kind"), default=RequestKind.standing)
    raw_text: Mapped[str] = mapped_column(Text)  # sacred — the system never modifies it
    structured: Mapped[dict] = mapped_column(JSON, default=lambda: {})  # {topic, scope, geography, depth}
    cadence: Mapped[str] = mapped_column(String(20), default="daily")
    status: Mapped[RequestStatus] = mapped_column(SAEnum(RequestStatus, name="request_status"), default=RequestStatus.active)
    created_from: Mapped[CreatedFrom] = mapped_column(SAEnum(CreatedFrom, name="request_created_from"))
    current_version_id: Mapped[uuid.UUID | None] = mapped_column(PGUUID(as_uuid=True), ForeignKey("request_versions.id"), nullable=True)
    pending_version_id: Mapped[uuid.UUID | None] = mapped_column(PGUUID(as_uuid=True), ForeignKey("request_versions.id"), nullable=True)
    last_answered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    fulfilled_episode_id: Mapped[uuid.UUID | None] = mapped_column(PGUUID(as_uuid=True), ForeignKey("episodes.id"), nullable=True)
    creado_en: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)


class RequestVersion(Base):
    __tablename__ = "request_versions"

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    request_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), ForeignKey("requests.id"), index=True)
    raw_text: Mapped[str] = mapped_column(Text)
    structured: Mapped[dict] = mapped_column(JSON, default=lambda: {})
    source: Mapped[VersionSource] = mapped_column(SAEnum(VersionSource, name="request_version_source"))
    status: Mapped[VersionStatus] = mapped_column(SAEnum(VersionStatus, name="request_version_status"), default=VersionStatus.pending)
    creado_en: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
    aplicado_en: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
