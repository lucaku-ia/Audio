"""
Profile — System Contracts v0.1 + regla transversal del documento paraguas
("Language and name | Captured once in Login profile. Inherited by every
epic. Never asked again.").

Por eso `language` no es un campo editable en este endpoint: se copia de
Cliente.idioma la primera vez que se crea el Profile (en el signup del cliente,
o aquí mismo si todavía no existe fila). Si el cliente quiere cambiar su
idioma, ese cambio vive en Cliente/Settings, no aquí.

`signals` (completion/skip/rating/refinements/adoptions/dismissals) es
derivado — nunca se pregunta y nunca se muestra como etiqueta (Request
Management PRD, tenet). Por eso tampoco es editable desde este endpoint;
lo va a escribir el Player/Home cuando existan.
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_cliente
from app.db.session import get_db
from app.models.cliente import Cliente
from app.models.profile import Language, NarrationStyle, Profile

router = APIRouter(prefix="/profile", tags=["Profile"])


class ProfileBody(BaseModel):
    voice_id: str | None = None
    narration_style: NarrationStyle = NarrationStyle.news
    delivery_time: str | None = Field(default=None, pattern=r"^\d{2}:\d{2}$")  # "HH:MM"
    delivery_timezone: str = "America/Bogota"
    max_length_minutes: int | None = None  # None = sin límite — techo, nunca meta (umbrella §8)


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
async def obtener_perfil(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    perfil = await db.get(Profile, cliente.id)
    if not perfil:
        raise HTTPException(404, "Todavía no se ha configurado el perfil (Onboarding sin completar)")
    return _out(perfil)


@router.put("", response_model=ProfileOut)
async def actualizar_perfil(
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
            language=Language(cliente.idioma),  # heredado de Cliente, no del body — nunca se repregunta
        )
        db.add(perfil)

    perfil.voice_id = body.voice_id
    perfil.narration_style = body.narration_style
    perfil.delivery_time = hora
    perfil.delivery_timezone = body.delivery_timezone
    perfil.max_length_minutes = body.max_length_minutes

    await db.commit()
    await db.refresh(perfil)
    return _out(perfil)
