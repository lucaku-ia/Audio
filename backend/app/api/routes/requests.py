"""
Request Management PRD (Andrés, Draft v1) — CRUD + versioning.

structure_request and validate_request now go through the AI Platform
(app/services/ai_platform.py) — a single call returns both the structured
object {topic, scope, geography, depth} and a safety verdict, filling in
what used to be a length-only placeholder heuristic.

refine() and adopt() are now built (Player and Home engineering-notes level
only — neither app screen exists, both endpoints are curled manually):

- refine(): POST /requests/{id}/refine. Stores a *pending* RequestVersion
  (source=refine_less|refine_deeper) via a new ai_platform.refine_request
  call — never applied immediately, per the Player PRD's "Applied from
  tomorrow." copy. Scope gap: nothing yet promotes pending_version_id to
  current_version_id at the next generation — app/services/episode_generator.py's
  run_generation() doesn't read or apply it (see that function; only
  active_for_generation() surfaces pending_versions_to_apply, unconsumed).
  Wiring that promotion is a Generator-side change, deliberately left out
  here since it touches episode_generator.py's snapshot/versioning logic,
  not Request Management's.
- adopt(): NOT a new endpoint. Home's own contract ("adopt suggestion ->
  Request Management create (created_from = suggestion)") already maps
  onto the existing POST /requests with created_from="suggestion" — that
  enum value already existed. Home's suggestion *generation* (the AI
  Platform semantic index) doesn't exist yet, so there is no suggestion id
  to accept or suppress; building suppression-list plumbing now would be
  bookkeeping for objects nothing produces. See crear_request() below —
  it already accepts created_from=suggestion with zero changes.

Player rating (thumbs up/down at episode end, System Contracts: profile
signal) is built as POST /episodes/{episode_id}/rating, in this file's
second router (episodes_router) since it doesn't belong under /requests
but there's no episodes.py yet. Per the Player PRD's own §9 open question
("thumbs or 1-5? per episode or per block?"), this implements the
requirements table's simpler, explicitly-named case: thumbs up/down, per
episode — per-block/1-5-scale is deferred, unresolved by the PRD itself.

raw_text is sacred — the system never overwrites it; every edit (and every
refine()) creates a new RequestVersion and the previous one is marked
superseded (System Contracts §3). refine() never touches raw_text at all —
see ai_platform.refine_request's docstring for why.
"""
import uuid
from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_cliente
from app.db.session import get_db
from app.models.cliente import Cliente
from app.models.episode import Block, Episode
from app.models.profile import Profile
from app.models.request import (
    CreatedFrom, Request, RequestKind, RequestStatus, RequestVersion,
    VersionSource, VersionStatus,
)
from app.services import ai_platform
from app.services.events import emitir

router = APIRouter(prefix="/requests", tags=["Request Management"])
episodes_router = APIRouter(prefix="/episodes", tags=["Player"])


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
    # {topic, scope, geography, depth} from ai_platform.structure_request — exposed so a
    # client can show/categorize a request by its topic without re-deriving it (see the
    # free-text-interests feature: "Arsenal FC" structures to topic≈"Arsenal FC", and the
    # client shows that topic as the category rather than forcing a fixed catalogue id).
    structured: dict


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
    kind_filtro: RequestKind | None = Query(default=None, alias="kind"),
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    stmt = select(Request).where(Request.customer_id == cliente.id)
    if status_filtro:
        stmt = stmt.where(Request.status == status_filtro)
    if kind_filtro:
        stmt = stmt.where(Request.kind == kind_filtro)
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

    if req.pending_version_id:
        # A pending refine was structured against the raw_text this edit just replaced —
        # promoting it later would silently undo the customer's fresh edit.
        pendiente = await db.get(RequestVersion, req.pending_version_id)
        if pendiente and pendiente.status == VersionStatus.pending:
            pendiente.status = VersionStatus.superseded
        req.pending_version_id = None

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


class RefineRequestBody(BaseModel):
    intent: Literal["less", "deeper"]
    block_id: uuid.UUID
    episode_id: uuid.UUID


class RefineResponse(BaseModel):
    pending_version_id: str
    message: str = "Applied from tomorrow."


@router.post("/{request_id}/refine", response_model=RefineResponse)
async def refinar_request(
    request_id: uuid.UUID,
    body: RefineRequestBody,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """
    Player PRD §5: "tapping 'less of this'/'go deeper' under the current
    block sends the intent and block to Request Management; a confirmation
    reads 'Applied from tomorrow.'" The player only sends intent + context
    (block_id, episode_id) — this looks up everything else itself.

    Stores a pending version rather than applying immediately; see this
    module's top-of-file scope note for the gap in promoting it to
    current_version_id at the next generation.
    """
    req = await _obtener_request_del_cliente(db, request_id, cliente)

    block_result = await db.execute(
        select(Block).where(
            Block.id == body.block_id,
            Block.episode_id == body.episode_id,
            Block.request_id == req.id,
        )
    )
    block = block_result.scalar_one_or_none()
    if not block:
        raise HTTPException(404, "Block not found for this request/episode")

    refined = await ai_platform.refine_request(
        db, req.raw_text, req.structured, body.intent, block.summary, block.script,
        cliente.id, req.id,
    )
    structured = {"topic": refined.topic, "scope": refined.scope, "geography": refined.geography, "depth": refined.depth}

    if req.pending_version_id:
        anterior_pendiente = await db.get(RequestVersion, req.pending_version_id)
        if anterior_pendiente and anterior_pendiente.status == VersionStatus.pending:
            anterior_pendiente.status = VersionStatus.superseded

    source = VersionSource.refine_less if body.intent == "less" else VersionSource.refine_deeper
    nueva_version = RequestVersion(
        request_id=req.id,
        raw_text=req.raw_text,  # raw_text is sacred — refine() never rewrites it, only `structured`
        structured=structured,
        source=source,
        status=VersionStatus.pending,
    )
    db.add(nueva_version)
    await db.flush()

    req.pending_version_id = nueva_version.id
    await db.commit()
    return RefineResponse(pending_version_id=str(nueva_version.id))


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


class RateEpisodeBody(BaseModel):
    rating: Literal["up", "down"]


@episodes_router.post("/{episode_id}/rating")
async def calificar_episodio(
    episode_id: uuid.UUID,
    body: RateEpisodeBody,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """
    Player PRD requirements table: "thumbs up/down at episode end or from
    the full player menu. Stored per episode and sent to Request Management
    as a profile signal." Per-block/1-5-scale was the PRD's own open
    question (§9) and is deferred, not decided by this endpoint.

    Lives here (not under /requests) because it's an episode-level action,
    but in this file since there's no episodes.py yet and the payload is a
    Profile signal, which is this module's territory.
    """
    episode_result = await db.execute(
        select(Episode).where(Episode.id == episode_id, Episode.customer_id == cliente.id)
    )
    episode = episode_result.scalar_one_or_none()
    if not episode:
        raise HTTPException(404, "Episode not found")

    perfil_result = await db.execute(select(Profile).where(Profile.customer_id == cliente.id))
    perfil = perfil_result.scalar_one_or_none()
    if not perfil:
        perfil = Profile(customer_id=cliente.id)
        db.add(perfil)
        await db.flush()

    signals = dict(perfil.signals or {})
    ratings = dict(signals.get("ratings", {}))
    ratings[str(episode_id)] = {"rating": body.rating, "rated_at": datetime.utcnow().isoformat()}
    signals["ratings"] = ratings
    perfil.signals = signals  # reassign the whole dict — JSON columns don't track in-place mutation

    await db.commit()
    return {"episode_id": str(episode_id), "rating": body.rating}


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
        structured=req.structured or {},
    )
