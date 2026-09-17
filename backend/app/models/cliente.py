"""
Cliente — account object per Lucaku_Login_PRD (Juan, Draft v2).

Not part of System Contracts v0.1 (which assumes customer_id already exists),
but the Login PRD does define its shape: mandatory login (guest mode was
rejected), 3 methods (Google / Apple / email+password), post-login routing
via onboarding_complete (false -> Onboarding, true -> Home, never a feed).

Language is captured here once and inherited by Profile — never asked
again (umbrella doc cross-cutting rule).
"""
import enum
import uuid
from datetime import datetime
from sqlalchemy import String, DateTime, Boolean, Integer, Enum as SAEnum
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column
from app.db.session import Base


class AuthProvider(str, enum.Enum):
    google = "google"
    apple = "apple"
    email = "email"


class Cliente(Base):
    __tablename__ = "clientes"

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)  # Apple: private relay email
    auth_provider: Mapped[AuthProvider] = mapped_column(SAEnum(AuthProvider, name="auth_provider"))
    provider_sub: Mapped[str | None] = mapped_column(String(255), nullable=True)  # Google/Apple sub; null for email
    hashed_password: Mapped[str | None] = mapped_column(String(255), nullable=True)  # bcrypt/argon2; email method only
    nombre: Mapped[str] = mapped_column(String(255))
    idioma: Mapped[str] = mapped_column(String(5), default="es")  # captured here, inherited by Profile — never re-asked
    onboarding_complete: Mapped[bool] = mapped_column(Boolean, default=False)  # routing: false->Onboarding, true->Home

    # Attempt throttle — Login PRD §5: "5 consecutive failed attempts trigger a 60s lockout"
    intentos_fallidos: Mapped[int] = mapped_column(Integer, default=0)
    bloqueado_hasta: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # Incremented on logout — any JWT issued before that instantly becomes invalid
    token_version: Mapped[int] = mapped_column(Integer, default=0)

    creado_en: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
