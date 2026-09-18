"""
Request Management PRD (Andrés, Draft v1) — CRUD + versioning.

structure_request and validate_request now go through the AI Platform
(app/services/ai_platform.py) — a single call returns both the structured
object {topic, scope, geography, depth} and a safety verdict, filling in
what used to be a length-only placeholder heuristic.

Still deliberately missing:
- refine() and adopt(): depend on Player and Home, which don't exist yet.

raw_text is sacred — the system never overwrites it; every edit creates a
new RequestVersion and the previous one is marked superseded
(System Contracts §3).
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
from app.services import ai_platform
from app.services.events import emitir

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
    """Cheap pre-filter before spending a model call — the real safety/structuring
    gate is app.services.ai_platform.structure_request."""
    if len(raw_text.strip()) < 5:
        raise HTTPException(400, "This request is too short to research anything from.")


def _structured_dict(result: ai_platform.StructuredRequest) -> dict:
    return {"topic": result.topic, "scope": result.scope, "geography": result.geography, "depth": result.depth}


async def _structure_or_reject(
    db: AsyncSession, raw_text: str, customer_id: uuid.UUID, request_id: uuid.UUID | None
) -> dict:
    result = await ai_platform.structure_request(db, raw_text, customer_id, request_id)
    if result.rejected:
        await db.commit()  # persist the AICall log even though the request is rejected — PRD: every call is logged
        raise HTTPException(400, result.rejected_reason or "This request can't be researched as written.")
    return _structured_dict(result)


async def _obtener_request_del_cliente(db: AsyncSession, request_id: uuid.UUID, cliente: Cliente) -> Request:
    result = await db.execute(
        select(Request).where(Request.id == request_id, Request.customer_id == cliente.id)
    )
    req = result.scalar_one_or_none()
    if not req:
        raise HTTPException(404, "Request not found")
    return req


# ── Endpoints ────────────────────────────────────────────────────────────────

@router.post("", response_model=RequestOut, status_code=201)
async def crear_request(
    body: CrearRequestBody,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    _validar_raw_text(body.raw_text)
    structured = await _structure_or_reject(db, body.raw_text, cliente.id, None)

    req = Request(
        customer_id=cliente.id,
        kind=body.kind,
        raw_text=body.raw_text,
        structured=structured,
        status=RequestStatus.active,
        created_from=body.created_from,
    )
    db.add(req)
    await db.flush()

    version = RequestVersion(
        request_id=req.id,
        raw_text=body.raw_text,
        structured=structured,
        source=VersionSource.create,
        status=VersionStatus.applied,
        aplicado_en=datetime.utcnow(),
    )
    db.add(version)
    await db.flush()

    req.current_version_id = version.id
    await emitir(db, "request_created", customer_id=cliente.id, source="requests",
                 request_id=str(req.id), kind=req.kind.value, created_from=req.created_from.value)
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
    Snapshot the Episode Generator needs at T-60 (System Contracts §2).
    Consumed internally today only for testing — the Generator doesn't exist yet.
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
    """Direct edit — applies immediately (unlike refine(), which applies on the next generation)."""
    _validar_raw_text(body.raw_text)
    req = await _obtener_request_del_cliente(db, request_id, cliente)
    structured = await _structure_or_reject(db, body.raw_text, cliente.id, req.id)

    if req.current_version_id:
        anterior = await db.get(RequestVersion, req.current_version_id)
        if anterior:
            anterior.status = VersionStatus.superseded

    nueva_version = RequestVersion(
        request_id=req.id,
        raw_text=body.raw_text,
        structured=structured,
        source=VersionSource.edit,
        status=VersionStatus.applied,
        aplicado_en=datetime.utcnow(),
    )
    db.add(nueva_version)
    await db.flush()

    req.raw_text = body.raw_text
    req.structured = structured
    req.current_version_id = nueva_version.id
    await emitir(db, "request_edited", customer_id=cliente.id, source="requests", request_id=str(req.id))
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
    await emitir(db, "request_paused", customer_id=cliente.id, source="requests", request_id=str(req.id))
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
    await emitir(db, "request_resumed", customer_id=cliente.id, source="requests", request_id=str(req.id))
    await db.commit()
    await db.refresh(req)
    return _request_out(req)


@router.patch("/{request_id}/archive", response_model=RequestOut)
async def archivar_request(
    request_id: uuid.UUID,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """Reversible — confirming before archiving is the client's (UI's) responsibility."""
    req = await _obtener_request_del_cliente(db, request_id, cliente)
    req.status = RequestStatus.archived
    await emitir(db, "request_archived", customer_id=cliente.id, source="requests", request_id=str(req.id))
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
    """Called by the Episode Generator after publishing — doesn't exist yet, but the
    operation is already ready per the contract (System Contracts §2)."""
    ahora = datetime.utcnow()
    actualizados = []
    for rid in body.request_ids:
        req = await _obtener_request_del_cliente(db, rid, cliente)
        req.last_answered_at = ahora
        if req.kind == RequestKind.one_off:
            req.status = RequestStatus.fulfilled
            req.fulfilled_episode_id = body.episode_id
        # request_answered, not episode_published, is the per-request signal here —
        # one episode can answer several requests, and this is the only place that
        # knows which ones and whether each got trimmed (had_more).
        await emitir(db, "request_answered", customer_id=cliente.id, source="requests",
                     request_id=str(req.id), episode_id=str(body.episode_id),
                     had_more=body.had_more.get(str(rid), False))
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
