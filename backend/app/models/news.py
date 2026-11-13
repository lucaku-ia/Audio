"""
News feed tables (backlog T-301/T-302/T-303, adapted to this FastAPI stack).

News is TOPIC-keyed, never customer-keyed: one NewsItem is written once per
(topic, day, slot) and shared by every follower, exactly like the findings
cache. What is per customer is only the read state. That separation is what
keeps cost independent of follower count.
"""
import uuid
from datetime import date, datetime, timezone

from sqlalchemy import (
    JSON, Date, DateTime, ForeignKey, Index, Integer, String, Text, UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.session import Base


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class NewsItem(Base):
    __tablename__ = "news_items"
    __table_args__ = (
        Index("ix_news_items_topic_published", "topic_key", "published_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    topic_key: Mapped[str] = mapped_column(String(300))
    category: Mapped[str] = mapped_column(String(40), index=True)  # one of news_pipeline.CATEGORIES
    title: Mapped[str] = mapped_column(String(300))
    summary: Mapped[str] = mapped_column(String(70))  # two-line-friendly, hard cap 70 chars
    short_version: Mapped[str] = mapped_column(Text)
    body: Mapped[str] = mapped_column(Text)
    # [{"name": ..., "url": ...}] — at least one entry, enforced by the pipeline ("no source, no item").
    sources: Mapped[list] = mapped_column(JSON, default=lambda: [])
    image_hint: Mapped[str | None] = mapped_column(String(300), nullable=True)
    published_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, index=True)
    slot: Mapped[str] = mapped_column(String(10))  # "0500" | "1300" | "adhoc"
    # "es" | "en": the language the item is WRITTEN in. Rows that predate this
    # column are English (the pipeline was English-only); the migration adds it with default 'en'.
    language: Mapped[str] = mapped_column(String(5), default="en", server_default="en")
    cluster_id: Mapped[uuid.UUID | None] = mapped_column(PGUUID(as_uuid=True), nullable=True, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)


class NewsReadState(Base):
    __tablename__ = "news_read_states"
    __table_args__ = (
        UniqueConstraint("cliente_id", "news_id", name="uq_news_read_cliente_news"),
    )

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    cliente_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), ForeignKey("clientes.id", ondelete="CASCADE"), index=True)
    news_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), ForeignKey("news_items.id", ondelete="CASCADE"), index=True)
    read_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)


class NewsRun(Base):
    """One row per (topic_key, run_date, slot, language): the idempotency
    record. The unique constraint is what makes "claim the run" race-safe.
    Language is part of the key because the write step runs once per
    language; research is shared and cached, so it is never repeated."""
    __tablename__ = "news_runs"
    __table_args__ = (
        UniqueConstraint("topic_key", "run_date", "slot", "language", name="uq_news_runs_topic_date_slot_lang"),
    )

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    topic_key: Mapped[str] = mapped_column(String(300))
    run_date: Mapped[date] = mapped_column(Date)
    slot: Mapped[str] = mapped_column(String(10))
    language: Mapped[str] = mapped_column(String(5), default="en", server_default="en")
    status: Mapped[str] = mapped_column(String(20), default="running")  # running | done | no_news | failed
    items_count: Mapped[int] = mapped_column(Integer, default=0)
    attempts: Mapped[int] = mapped_column(Integer, default=1)  # claims so far; capped by news_pipeline.MAX_ATTEMPTS
    cost: Mapped[float] = mapped_column(default=0.0)
    error: Mapped[str | None] = mapped_column(String(300), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)
