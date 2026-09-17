"""
Placeholder mínimo de cuenta de cliente.

El objeto real de cuenta/login vive en el Login PRD, que todavía no existe
en la carpeta de Drive (referenciado por Notifications+Settings y Onboarding
pero no escrito). Este modelo solo existe para que customer_id tenga una
tabla real a la que apuntar — reemplazar/fusionar cuando aparezca ese PRD.
"""
import uuid
from datetime import datetime
from sqlalchemy import String, DateTime
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column
from app.db.session import Base


class Cliente(Base):
    __tablename__ = "clientes"

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    hashed_password: Mapped[str] = mapped_column(String(255))
    creado_en: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
