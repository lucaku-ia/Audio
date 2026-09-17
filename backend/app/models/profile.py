"""Profile — System Contracts v0.1. Derived, never asked and never shown as a label."""
import enum
import uuid
from datetime import datetime, time
from sqlalchemy import String, DateTime, Time, Integer, JSON, ForeignKey, Enum as SAEnum
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column
from app.db.session import Base


class NarrationStyle(str, enum.Enum):
    news = "news"
    story = "story"
    casual = "casual"


class Language(str, enum.Enum):
    es = "es"
    en = "en"


class Profile(Base):
    __tablename__ = "profiles"

    customer_id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), ForeignKey("clientes.id"), primary_key=True)
    voice_id: Mapped[str | None] = mapped_column(String(100), nullable=True)
    narration_style: Mapped[NarrationStyle] = mapped_column(SAEnum(NarrationStyle, name="narration_style"), default=NarrationStyle.news)
    language: Mapped[Language] = mapped_column(SAEnum(Language, name="profile_language"), default=Language.es)
    delivery_time: Mapped[time | None] = mapped_column(Time, nullable=True)  # local time; tz goes in delivery_timezone
    delivery_timezone: Mapped[str] = mapped_column(String(50), default="America/Bogota")
    max_length_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)  # null = no limit, a ceiling not a target
    signals: Mapped[dict] = mapped_column(JSON, default=lambda: {})  # completion/skip/rating, refinements, adoptions, dismissals
    computado_en: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
