"""Episode and Block — System Contracts v0.1."""
import enum
import uuid
from datetime import datetime, date as date_type
from sqlalchemy import String, DateTime, Date, Integer, Boolean, Text, JSON, ForeignKey, Enum as SAEnum
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column
from app.db.session import Base


class EpisodePath(str, enum.Enum):
    scheduled = "scheduled"
    on_demand = "on_demand"
    shared = "shared"


class Episode(Base):
    __tablename__ = "episodes"

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID | None] = mapped_column(PGUUID(as_uuid=True), ForeignKey("clientes.id"), nullable=True, index=True)  # null = shared inventory
    shared: Mapped[bool] = mapped_column(Boolean, default=False)
    fecha: Mapped[date_type] = mapped_column(Date)
    path: Mapped[EpisodePath] = mapped_column(SAEnum(EpisodePath, name="episode_path"))
    headline: Mapped[str | None] = mapped_column(String(500), nullable=True)
    language: Mapped[str | None] = mapped_column(String(10), nullable=True)
    style: Mapped[str | None] = mapped_column(String(50), nullable=True)
    voice_id: Mapped[str | None] = mapped_column(String(100), nullable=True)
    duration_s: Mapped[int | None] = mapped_column(Integer, nullable=True)
    audio_url: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    had_more_any: Mapped[bool] = mapped_column(Boolean, default=False)
    published_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    cost: Mapped[dict] = mapped_column(JSON, default=lambda: {})  # {research, writing, tts, other} — Instrumentation snapshot
    creado_en: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)


class Block(Base):
    __tablename__ = "blocks"

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    episode_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), ForeignKey("episodes.id"), index=True)
    request_id: Mapped[uuid.UUID | None] = mapped_column(PGUUID(as_uuid=True), ForeignKey("requests.id"), nullable=True)  # null = intro/outro
    request_version_id: Mapped[uuid.UUID | None] = mapped_column(PGUUID(as_uuid=True), ForeignKey("request_versions.id"), nullable=True)
    start_s: Mapped[int] = mapped_column(Integer)
    end_s: Mapped[int] = mapped_column(Integer)
    summary: Mapped[str] = mapped_column(Text)  # one line, indexed
    script: Mapped[str] = mapped_column(Text)  # stored, not fully indexed
    sources: Mapped[list] = mapped_column(JSON, default=lambda: [])  # [{url, title, publisher, license, retrieved_at}]
    had_more: Mapped[bool] = mapped_column(Boolean, default=False)
    no_news: Mapped[bool] = mapped_column(Boolean, default=False)
    # Word-level timing for karaoke-style transcript highlighting (Player PRD).
    # Populated from ElevenLabs' character-level alignment (the `/with-timestamps`
    # variant of the TTS endpoint — see app/services/ai_platform.synthesize),
    # collapsed from characters to words here since the Player highlights whole
    # words, not individual characters. Shape: a list of
    # {"word": str, "start_s": float, "end_s": float}, in script order. Null
    # (not []) when this block's audio wasn't synthesized with timestamps (e.g.
    # ELEVENLABS_API_KEY unset, or synthesized before this field existed) — the
    # iOS client's own proportional-highlight fallback should key off null vs.
    # populated, not off an empty list, since a no_news/empty-script block would
    # legitimately have an empty list otherwise.
    word_timestamps: Mapped[list | None] = mapped_column(JSON, nullable=True, default=None)
