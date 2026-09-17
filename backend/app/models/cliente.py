"""
Cliente — objeto de cuenta según Lucaku_Login_PRD (Juan, Draft v2).

No está en System Contracts v0.1 (que asume que customer_id ya existe),
pero el Login PRD sí define su forma: login obligatorio (se descartó modo
invitado), 3 métodos (Google / Apple / email+password), ruteo post-login
por onboarding_complete (false → Onboarding, true → Home, nunca a un feed).

El idioma se captura aquí una sola vez y lo hereda Profile — nunca se
vuelve a preguntar (regla transversal del documento paraguas).
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
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)  # Apple: email de relay privado
    auth_provider: Mapped[AuthProvider] = mapped_column(SAEnum(AuthProvider, name="auth_provider"))
    provider_sub: Mapped[str | None] = mapped_column(String(255), nullable=True)  # sub de Google/Apple; null si es email
    hashed_password: Mapped[str | None] = mapped_column(String(255), nullable=True)  # bcrypt/argon2; solo metodo email
    nombre: Mapped[str] = mapped_column(String(255))
    idioma: Mapped[str] = mapped_column(String(5), default="es")  # capturado aqui, heredado por Profile — nunca se repregunta
    onboarding_complete: Mapped[bool] = mapped_column(Boolean, default=False)  # ruteo: false→Onboarding, true→Home

    # Throttle de intentos — Login PRD §5: "5 intentos fallidos consecutivos disparan 60s de bloqueo"
    intentos_fallidos: Mapped[int] = mapped_column(Integer, default=0)
    bloqueado_hasta: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # Se incrementa en logout — cualquier JWT emitido antes queda invalido de inmediato
    token_version: Mapped[int] = mapped_column(Integer, default=0)

    creado_en: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
