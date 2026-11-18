"""
Discovery audio (capsules design rev 3, section 8.2): a news item voiced on tap,
once per (news item, voice), and served to everyone.

`news_item_audio` is SHARED and holds no customer data (the voiced text is the
stored NewsItem). `discovery_voicing_log` is the committed spend ledger and the
per-user rate-limit counter: one row per voicing attempt, with the triggering
customer id (and nothing else personal). Account deletion anonymises it
(customer_id -> NULL, cost kept so the daily ceiling stays honest); export lists
the customer's own rows.
"""
import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, DateTime, Float, ForeignKey, Index, Integer, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.session import Base


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class NewsItemAudio(Base):
    __tablename__ = "news_item_audio"
    __table_args__ = (UniqueConstraint("news_item_id", "voice_key", name="uq_news_item_audio_item_voice"),)

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    news_item_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), ForeignKey("news_items.id", ondelete="CASCADE"), index=True)
    voice_key: Mapped[str] = mapped_column(String(60))
    language: Mapped[str] = mapped_column(String(5))
    audio_url: Mapped[str | None] = mapped_column(String(1000), nullable=True)  # random uuid file name
    duration_s: Mapped[int | None] = mapped_column(Integer, nullable=True)
    word_timestamps: Mapped[list | None] = mapped_column(JSON, nullable=True)
    chars: Mapped[int | None] = mapped_column(Integer, nullable=True)
    status: Mapped[str] = mapped_column(String(20), default="pending")  # pending | voicing | voiced | failed
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    voicing_started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)  # lease
    cost: Mapped[float] = mapped_column(Float, default=0.0)  # lifetime provider cost of this row
    error: Mapped[str | None] = mapped_column(String(200), nullable=True)  # last failure / block code (no user data)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)


class DiscoveryVoicingLog(Base):
    __tablename__ = "discovery_voicing_log"
    __table_args__ = (Index("ix_discovery_log_customer_created", "customer_id", "created_at"),)

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID | None] = mapped_column(PGUUID(as_uuid=True), nullable=True)  # no FK: anonymised on account deletion
    news_item_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True))
    voice_key: Mapped[str] = mapped_column(String(60))
    cost: Mapped[float] = mapped_column(Float, default=0.0)  # committed spend of this attempt (actual, or an estimate when billed but failed)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, index=True)
