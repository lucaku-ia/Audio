"""Emisor mínimo del catálogo de Instrumentation (ver Instrumentation & Cost PRD §5)."""
import uuid
from sqlalchemy.ext.asyncio import AsyncSession
from app.models.instrumentation import Event


async def emitir(db: AsyncSession, name: str, customer_id: uuid.UUID | None = None, **payload):
    db.add(Event(name=name, customer_id=customer_id, source="login", payload=payload))
