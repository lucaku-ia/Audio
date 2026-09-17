"""
Request Management PRD (Andrés, Draft v1) — CRUD + versionado.

Lo que falta a propósito porque depende de la AI Platform (todavía no existe):

- structure_request: `structured` queda siempre {} por ahora. Cuando exista la
  AI Platform, se llena en create/edit.
- validate_request: solo hay un heurístico mínimo (longitud). El PRD pide
  rechazar solicitudes no investigables, maliciosas o sobre personas privadas
  — eso necesita el modelo de IA.
- refine() y adopt(): dependen de Player y Home, que tampoco existen. No están
  implementados todavía.

raw_text es sagrado — nunca se sobrescribe, cada cambio crea una RequestVersion
nueva y la anterior queda marcada superseded (System Contracts §3).
"""
import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_cliente
from app.db.session import get_db
from app.models.cliente import Cliente
from app.models.profile import Profile
from app.models.request import (
    CreatedFrom, Request, RequestKind, RequestStatus, RequestVersion,
    VersionSource, VersionStatus,
)

router = APIRouter(prefix="/requests", tags=["Request Management"])


# ── Schemas ──────────────────────────────────────────────────────────────────

class CrearRequestBody(BaseModel):
    raw_text: str = Field(min_length=5, max_length=2000)
    kind: RequestKind = RequestKind.standing
    created_from: CreatedFrom = CreatedFrom.interests


class EditarRequestBody(BaseModel):
    raw_text: str = Field(min_length=5, max_length=2000)


class VersionOut(BaseModel):
    id: str
    raw_text: str
    source: str
    status: str
    creado_en: datetime
    aplicado_en: datetime | None


class RequestOut(BaseModel):
    id: str
    kind: str
    raw_text: str
    status: str
    created_from: str
    last_answered_at: datetime | None
    fulfilled_episode_id: str | None
    creado_en: datetime


class RequestDetailOut(RequestOut):
    versions: list[VersionOut]


def _validar_raw_text(raw_text: str):
    """Heuristico minimo — el PRD pide rechazar en la puerta via AI Platform.validate_request,
    que todavia no existe. Placeholder deliberado, no la validacion real."""
    if len(raw_text.strip()) < 5:
        raise HTTPException(400, "La solicitud es demasiado corta para investigar algo con ella.")


async def _obtener_request_del_cliente(db: AsyncSession, request_id: uuid.UUID, cliente: Cliente) -> Request:
    result = await db.execute(
        select(Request).where(Request.id == request_id, Request.customer_id == cliente.id)
    )
    req = result.scalar_one_or_none()
    if not req:
        raise HTTPException(404, "Solicitud no encontrada")
    return req


# ── Endpoints ────────────────────────────────────────────────────────────────

@router.post("", response_model=RequestOut, status_code=201)
async def crear_request(
    body: CrearRequestBody,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    _validar_raw_text(body.raw_text)

    req = Request(
        customer_id=cliente.id,
        kind=body.kind,
        raw_text=body.raw_text,
        structured={},  # pendiente de AI Platform.structure_request
        status=RequestStatus.active,
        created_from=body.created_from,
    )
    db.add(req)
    await db.flush()

    version = RequestVersion(
        request_id=req.id,
        raw_text=body.raw_text,
        structured={},
        source=VersionSource.create,
        status=VersionStatus.applied,
        aplicado_en=datetime.utcnow(),
    )
    db.add(version)
    await db.flush()

    req.current_version_id = version.id
    await db.commit()
    await db.refresh(req)
    return _request_out(req)


@router.get("", response_model=list[RequestOut])
async def listar_requests(
    status_filtro: RequestStatus | None = Query(default=None, alias="status"),
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    stmt = select(Request).where(Request.customer_id == cliente.id)
    if status_filtro:
        stmt = stmt.where(Request.status == status_filtro)
    stmt = stmt.order_by(Request.creado_en.desc())
    result = await db.execute(stmt)
    return [_request_out(r) for r in result.scalars().all()]


@router.get("/active_count")
async def contar_activas(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(func.count(Request.id)).where(
            Request.customer_id == cliente.id, Request.status == RequestStatus.active
        )
    )
    return {"active_count": result.scalar() or 0}


@router.get("/active_for_generation")
async def active_for_generation(
    at: datetime | None = Query(default=None),
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """
    Snapshot que el Episode Generator necesita en T-60 (System Contracts §2).
    Consumido internamente hoy solo por pruebas — el Generator todavia no existe.
    """
    result = await db.execute(
        select(Request).where(Request.customer_id == cliente.id, Request.status == RequestStatus.active)
    )
    activas = result.scalars().all()

    standing = [r for r in activas if r.kind == RequestKind.standing]
    one_offs = [r for r in activas if r.kind == RequestKind.one_off]
    pendientes = [r for r in activas if r.pending_version_id is not None]

    perfil_result = await db.execute(select(Profile).where(Profile.customer_id == cliente.id))
    perfil = perfil_result.scalar_one_or_none()

    return {
        "customer_id": str(cliente.id),
        "at": (at or datetime.utcnow()).isoformat(),
        "standing_requests": [_request_out(r) for r in standing],
        "one_off_requests": [_request_out(r) for r in one_offs],
        "pending_versions_to_apply": [str(r.id) for r in pendientes],
        "profile": {
            "voice_id": perfil.voice_id,
            "narration_style": perfil.narration_style.value,
            "language": perfil.language.value,
            "max_length_minutes": perfil.max_length_minutes,
        } if perfil else None,
    }


@router.get("/{request_id}", response_model=RequestDetailOut)
async def detalle_request(
    request_id: uuid.UUID,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    req = await _obtener_request_del_cliente(db, request_id, cliente)
    versiones = await db.execute(
        select(RequestVersion).where(RequestVersion.request_id == req.id).order_by(RequestVersion.creado_en)
    )
    out = _request_out(req).model_dump()
    out["versions"] = [
        VersionOut(
            id=str(v.id), raw_text=v.raw_text, source=v.source.value,
            status=v.status.value, creado_en=v.creado_en, aplicado_en=v.aplicado_en,
        )
        for v in versiones.scalars().all()
    ]
    return RequestDetailOut(**out)


@router.patch("/{request_id}", response_model=RequestOut)
async def editar_request(
    request_id: uuid.UUID,
    body: EditarRequestBody,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """Edicion directa — aplica de inmediato (a diferencia de refine(), que aplica en la proxima generacion)."""
    _validar_raw_text(body.raw_text)
    req = await _obtener_request_del_cliente(db, request_id, cliente)

    if req.current_version_id:
        anterior = await db.get(RequestVersion, req.current_version_id)
        if anterior:
            anterior.status = VersionStatus.superseded

    nueva_version = RequestVersion(
        request_id=req.id,
        raw_text=body.raw_text,
        structured={},
        source=VersionSource.edit,
        status=VersionStatus.applied,
        aplicado_en=datetime.utcnow(),
    )
    db.add(nueva_version)
    await db.flush()

    req.raw_text = body.raw_text
    req.current_version_id = nueva_version.id
    await db.commit()
    await db.refresh(req)
    return _request_out(req)


@router.patch("/{request_id}/pause", response_model=RequestOut)
async def pausar_request(
    request_id: uuid.UUID,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    req = await _obtener_request_del_cliente(db, request_id, cliente)
    req.status = RequestStatus.paused
    await db.commit()
    await db.refresh(req)
    return _request_out(req)


@router.patch("/{request_id}/resume", response_model=RequestOut)
async def reanudar_request(
    request_id: uuid.UUID,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    req = await _obtener_request_del_cliente(db, request_id, cliente)
    req.status = RequestStatus.active
    await db.commit()
    await db.refresh(req)
    return _request_out(req)


@router.patch("/{request_id}/archive", response_model=RequestOut)
async def archivar_request(
    request_id: uuid.UUID,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """Reversible — la confirmacion antes de archivar es responsabilidad del cliente (UI)."""
    req = await _obtener_request_del_cliente(db, request_id, cliente)
    req.status = RequestStatus.archived
    await db.commit()
    await db.refresh(req)
    return _request_out(req)


class MarkAnsweredBody(BaseModel):
    request_ids: list[uuid.UUID]
    episode_id: uuid.UUID
    had_more: dict[str, bool] = {}  # request_id (str) -> had_more


@router.post("/mark_answered")
async def mark_answered(
    body: MarkAnsweredBody,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """Lo llama el Episode Generator tras publicar — todavia no existe, pero la operacion
    ya esta lista segun el contrato (System Contracts §2)."""
    ahora = datetime.utcnow()
    actualizados = []
    for rid in body.request_ids:
        req = await _obtener_request_del_cliente(db, rid, cliente)
        req.last_answered_at = ahora
        if req.kind == RequestKind.one_off:
            req.status = RequestStatus.fulfilled
            req.fulfilled_episode_id = body.episode_id
        actualizados.append(str(req.id))
    await db.commit()
    return {"actualizados": actualizados}


def _request_out(req: Request) -> RequestOut:
    return RequestOut(
        id=str(req.id),
        kind=req.kind.value,
        raw_text=req.raw_text,
        status=req.status.value,
        created_from=req.created_from.value,
        last_answered_at=req.last_answered_at,
        fulfilled_episode_id=str(req.fulfilled_episode_id) if req.fulfilled_episode_id else None,
        creado_en=req.creado_en,
    )
