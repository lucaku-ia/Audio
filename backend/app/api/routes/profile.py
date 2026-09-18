"""
Profile — System Contracts v0.1 + umbrella doc cross-cutting rule
("Language and name | Captured once in Login profile. Inherited by every
epic. Never asked again.").

That's why `language` is not editable through this endpoint: it's copied
from Cliente.idioma the first time the Profile row is created (either at
signup, or here if the row doesn't exist yet). If the customer wants to
change their language, that lives in Cliente/Settings, not here.

`signals` (completion/skip/rating, refinements, adoptions, dismissals) is
derived — never asked and never shown as a label (Request Management PRD
tenet). It's also not editable through this endpoint; the future
Player/Home will write it.
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_cliente
from app.db.session import get_db
from app.models.cliente import Cliente
from app.models.profile import Language, NarrationStyle, Profile
from app.services.events import emitir

router = APIRouter(prefix="/profile", tags=["Profile"])


class ProfileBody(BaseModel):
    voice_id: str | None = None
    narration_style: NarrationStyle = NarrationStyle.news
    delivery_time: str | None = Field(default=None, pattern=r"^\d{2}:\d{2}$")  # "HH:MM"
    delivery_timezone: str = "America/Bogota"
    max_length_minutes: int | None = None  # None = no limit — ceiling, never a target (umbrella §8)


class ProfileOut(BaseModel):
    customer_id: str
    voice_id: str | None
    narration_style: str
    language: str
    delivery_time: str | None
    delivery_timezone: str
    max_length_minutes: int | None
    signals: dict


def _out(perfil: Profile) -> ProfileOut:
    return ProfileOut(
        customer_id=str(perfil.customer_id),
        voice_id=perfil.voice_id,
        narration_style=perfil.narration_style.value,
        language=perfil.language.value,
        delivery_time=perfil.delivery_time.strftime("%H:%M") if perfil.delivery_time else None,
        delivery_timezone=perfil.delivery_timezone,
        max_length_minutes=perfil.max_length_minutes,
        signals=perfil.signals or {},
    )


@router.get("", response_model=ProfileOut)
async def get_profile(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    perfil = await db.get(Profile, cliente.id)
    if not perfil:
        raise HTTPException(404, "Profile not set up yet (Onboarding incomplete)")
    return _out(perfil)


@router.put("", response_model=ProfileOut)
async def update_profile(
    body: ProfileBody,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    from datetime import time as time_type

    hora = None
    if body.delivery_time:
        h, m = body.delivery_time.split(":")
        hora = time_type(int(h), int(m))

    perfil = await db.get(Profile, cliente.id)
    if not perfil:
        perfil = Profile(
            customer_id=cliente.id,
            language=Language(cliente.idioma),  # inherited from Cliente, not from the body — never re-asked
        )
        db.add(perfil)

    perfil.voice_id = body.voice_id
    perfil.narration_style = body.narration_style
    perfil.delivery_time = hora
    perfil.delivery_timezone = body.delivery_timezone
    perfil.max_length_minutes = body.max_length_minutes

    # This is the only Profile write path today (Request Management catalogue's
    # profile_recomputed) — signals-driven recomputation doesn't exist yet since
    # the Player/Home epics that would write `signals` haven't been built.
    await emitir(db, "profile_recomputed", customer_id=cliente.id, source="profile",
                 narration_style=perfil.narration_style.value,
                 has_delivery_time=perfil.delivery_time is not None,
                 has_voice_id=perfil.voice_id is not None)
    await db.commit()
    await db.refresh(perfil)
    return _out(perfil)
