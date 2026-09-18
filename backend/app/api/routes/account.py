"""
Account & data — Notifications & Settings PRD (Andrés, Draft v1), "Account &
data" requirement: "email, connected method, export (JSON of requests and
episodes list), delete account with confirmation, cascading deletion."

Built here:
- GET /api/account/export — a JSON export of the calling customer's Requests
  (with their RequestVersion history) and Episodes (with their Blocks), per
  the PRD's own wording of what the export contains.
- DELETE /api/account — deletes the Cliente row and cascades the deletion
  through every child table per the PRD's engineering note ("Account
  deletion: async cascade — requests, versions, episodes, downloads, index
  entries, events anonymized").

Deletion approach: none of the existing foreign keys in app/models/*.py
declare `ondelete="CASCADE"` (checked: Profile, OnboardingState, Request,
RequestVersion, Episode, Block, GenerationJob all use a plain
`ForeignKey(...)` with no ondelete clause), so a raw `DELETE FROM clientes`
would hit `ForeignKeyViolation`s rather than cascading. Changing that means
either an `ALTER TABLE ... DROP/ADD CONSTRAINT` migration (touching
app/db/migraciones.py, which per the README has already caused two
production crashes when done carelessly) or explicit, ordered, in-endpoint
deletes. Given that history, this endpoint does the deletes explicitly, in
dependency order, inside one transaction, rather than touching any FK
definition or migration file. This is intentionally the more conservative
choice for a first cut; an FK-level migration can follow later once this
path is proven.

Deletion order (children before parents, breaking cross-references first):
1. Null out Request.current_version_id / pending_version_id / fulfilled_episode_id
   for the customer's own requests — these are the only remaining references
   into request_versions/episodes once request rows are otherwise ready to go,
   and must be cleared before those tables' rows are deleted.
2. Delete Block rows referencing the customer's episodes or requests.
3. Delete InventoryItem rows referencing the customer's episodes (defensive —
   in practice a customer's own episodes are not shared/day-zero inventory,
   but the FK exists so it's handled).
4. Delete RequestVersion rows for the customer's requests.
5. Delete Request rows for the customer.
6. Delete Episode rows for the customer (shared episodes, customer_id NULL,
   are never touched).
7. Delete GenerationJob rows for the customer.
8. Delete OnboardingState row (if any).
9. Delete Profile row (if any).
10. Anonymize Event rows: set customer_id to NULL rather than deleting them
    (PRD + System Contracts: "Events anonymized"; Event.customer_id already
    has no foreign key and is documented in the model as "anonymized on
    account deletion").
11. Anonymize AICall rows: the PRD's "events anonymized" line only names
    Events, but AICall.context carries the same identifying customer_id
    (as a string, inside a plain JSON column — not JSONB, no FK, no index)
    and Colombia's Ley 1581 (cited elsewhere in this PRD) doesn't
    distinguish by table name. Scrubbed via a `context::jsonb ||
    jsonb_build_object('customer_id', null))::json` update matched on
    `context->>'customer_id'` — verified against a real local Postgres
    that this correctly nulls the field while leaving request_id/
    episode_id/job_id and the cost/token data intact (the PRD only asks
    to anonymize identity, not to lose the cost attribution this table
    exists for).
12. Delete the Cliente row itself.

Confirmation email ("Confirmation email" in the PRD's engineering notes) is
skipped: it needs an email-sending provider/credential that isn't configured
anywhere in this repo (no SMTP/SES/Postmark settings exist). The deletion
and cascade themselves are fully built; only the email notice is deferred.

"Delete account with confirmation" — the actual confirmation UX (a modal,
re-typing a password, etc.) is a client-side concern; this is a
backend-only repo with no UI yet (see README). The endpoint itself performs
the deletion unconditionally once called, same as every other mutating
endpoint in this codebase (e.g. DELETE-equivalents like `archive_request`
rely on the client to confirm before calling).
"""
import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy import delete, or_, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_cliente
from app.db.session import get_db
from app.models.cliente import Cliente
from app.models.episode import Block, Episode
from app.models.generation_job import GenerationJob, InventoryItem, JobStatus
from app.models.instrumentation import AICall, Event
from app.models.onboarding import OnboardingState
from app.models.profile import Profile
from app.models.request import Request, RequestVersion
from app.services.events import emitir

router = APIRouter(prefix="/account", tags=["Account & Data"])


# ── Export ───────────────────────────────────────────────────────────────────

class VersionExport(BaseModel):
    id: str
    raw_text: str
    structured: dict
    source: str
    status: str
    creado_en: datetime
    aplicado_en: datetime | None


class RequestExport(BaseModel):
    id: str
    kind: str
    raw_text: str
    structured: dict
    status: str
    created_from: str
    last_answered_at: datetime | None
    creado_en: datetime
    versions: list[VersionExport]


class BlockExport(BaseModel):
    id: str
    request_id: str | None
    start_s: int
    end_s: int
    summary: str
    script: str
    sources: list
    had_more: bool
    no_news: bool


class EpisodeExport(BaseModel):
    id: str
    fecha: str
    path: str
    headline: str | None
    language: str | None
    style: str | None
    duration_s: int | None
    audio_url: str | None
    published_at: datetime | None
    creado_en: datetime
    blocks: list[BlockExport]


class AccountExportOut(BaseModel):
    customer_id: str
    email: str
    exported_at: datetime
    requests: list[RequestExport]
    episodes: list[EpisodeExport]


@router.get("/export", response_model=AccountExportOut)
async def export_account_data(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    req_result = await db.execute(
        select(Request).where(Request.customer_id == cliente.id).order_by(Request.creado_en)
    )
    requests_ = req_result.scalars().all()

    requests_export: list[RequestExport] = []
    for req in requests_:
        ver_result = await db.execute(
            select(RequestVersion).where(RequestVersion.request_id == req.id).order_by(RequestVersion.creado_en)
        )
        versions = [
            VersionExport(
                id=str(v.id), raw_text=v.raw_text, structured=v.structured,
                source=v.source.value, status=v.status.value,
                creado_en=v.creado_en, aplicado_en=v.aplicado_en,
            )
            for v in ver_result.scalars().all()
        ]
        requests_export.append(RequestExport(
            id=str(req.id), kind=req.kind.value, raw_text=req.raw_text, structured=req.structured,
            status=req.status.value, created_from=req.created_from.value,
            last_answered_at=req.last_answered_at, creado_en=req.creado_en, versions=versions,
        ))

    ep_result = await db.execute(
        select(Episode).where(Episode.customer_id == cliente.id).order_by(Episode.creado_en)
    )
    episodes = ep_result.scalars().all()

    episodes_export: list[EpisodeExport] = []
    for ep in episodes:
        block_result = await db.execute(
            select(Block).where(Block.episode_id == ep.id).order_by(Block.start_s)
        )
        blocks = [
            BlockExport(
                id=str(b.id), request_id=str(b.request_id) if b.request_id else None,
                start_s=b.start_s, end_s=b.end_s, summary=b.summary, script=b.script,
                sources=b.sources, had_more=b.had_more, no_news=b.no_news,
            )
            for b in block_result.scalars().all()
        ]
        episodes_export.append(EpisodeExport(
            id=str(ep.id), fecha=ep.fecha.isoformat(), path=ep.path.value, headline=ep.headline,
            language=ep.language, style=ep.style, duration_s=ep.duration_s, audio_url=ep.audio_url,
            published_at=ep.published_at, creado_en=ep.creado_en, blocks=blocks,
        ))

    return AccountExportOut(
        customer_id=str(cliente.id),
        email=cliente.email,
        exported_at=datetime.utcnow(),
        requests=requests_export,
        episodes=episodes_export,
    )


# ── Deletion ─────────────────────────────────────────────────────────────────

@router.delete("", status_code=200)
async def delete_account(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    customer_id: uuid.UUID = cliente.id

    # A review of this cascade found a real (if narrow) race: run_generation()
    # commits a GenerationJob up front, then later inserts Blocks with a live FK
    # to requests.id — if a deletion's DELETE FROM requests lands in between,
    # that insert hits a ForeignKeyViolation instead of a clean outcome on
    # either side. Full row-locking (SELECT ... FOR UPDATE) would close this
    # completely, but a simple in-flight check is enough for a single-instance
    # pilot deployment: refuse deletion while a job for this customer is still
    # actively running, rather than let the two operations interleave.
    in_flight_result = await db.execute(
        select(GenerationJob.id).where(
            GenerationJob.customer_id == customer_id,
            GenerationJob.status.in_([JobStatus.queued, JobStatus.researching, JobStatus.writing, JobStatus.voicing]),
        )
    )
    if in_flight_result.first() is not None:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            "An episode is currently being generated for this account. Try deleting again in a moment.",
        )

    req_ids_result = await db.execute(select(Request.id).where(Request.customer_id == customer_id))
    request_ids = [r for (r,) in req_ids_result.all()]

    ep_ids_result = await db.execute(select(Episode.id).where(Episode.customer_id == customer_id))
    episode_ids = [e for (e,) in ep_ids_result.all()]

    # 1. Break Request -> RequestVersion / Episode references before those rows go.
    if request_ids:
        await db.execute(
            update(Request)
            .where(Request.id.in_(request_ids))
            .values(current_version_id=None, pending_version_id=None, fulfilled_episode_id=None)
        )

    # 2. Blocks referencing this customer's episodes or requests.
    if episode_ids or request_ids:
        conditions = []
        if episode_ids:
            conditions.append(Block.episode_id.in_(episode_ids))
        if request_ids:
            conditions.append(Block.request_id.in_(request_ids))
        await db.execute(delete(Block).where(or_(*conditions)))

    # 3. InventoryItem rows pointing at this customer's episodes (defensive).
    if episode_ids:
        await db.execute(delete(InventoryItem).where(InventoryItem.episode_id.in_(episode_ids)))

    # 4. RequestVersion rows for this customer's requests.
    if request_ids:
        await db.execute(delete(RequestVersion).where(RequestVersion.request_id.in_(request_ids)))

    # 5. Request rows.
    await db.execute(delete(Request).where(Request.customer_id == customer_id))

    # 6. Episode rows (shared/inventory episodes, customer_id NULL, are untouched).
    await db.execute(delete(Episode).where(Episode.customer_id == customer_id))

    # 7. GenerationJob rows.
    await db.execute(delete(GenerationJob).where(GenerationJob.customer_id == customer_id))

    # 8. OnboardingState row, if any.
    await db.execute(delete(OnboardingState).where(OnboardingState.customer_id == customer_id))

    # 9. Profile row, if any.
    await db.execute(delete(Profile).where(Profile.customer_id == customer_id))

    # 10. Anonymize Events instead of deleting them.
    await db.execute(update(Event).where(Event.customer_id == customer_id).values(customer_id=None))

    # 11. Anonymize AICall.context's customer_id — same identity, different
    # table, plain JSON (not JSONB) so this goes through a jsonb cast rather
    # than jsonb_set/the `||` operator working directly on the column.
    await db.execute(
        update(AICall)
        .where(AICall.context["customer_id"].as_string() == str(customer_id))
        .values(context=text(
            "(context::jsonb || jsonb_build_object('customer_id', null))::json"
        ))
    )

    # Emitted with customer_id=None on purpose — by the time this commits the
    # customer row is gone, and the event log for a deleted account is anonymous
    # by design (see the anonymization step above).
    await emitir(db, "account_deleted", customer_id=None, source="account")

    # 12. The Cliente row itself.
    await db.execute(delete(Cliente).where(Cliente.id == customer_id))

    await db.commit()
    return {"deleted": True}
