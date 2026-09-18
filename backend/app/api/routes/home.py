"""
Home PRD (Andrés, Draft v1) — one call that returns everything Home needs to
render. Per the PRD's own engineering note ("State is derived server-side and
cached; Home renders, it does not decide"), all banner-state derivation and
recent-episode shaping happens here, not on a client.

Built:
- Banner state machine: ready / making / late / empty_day / re_entry, derived
  from the customer's active Requests and today's GenerationJob (see
  `_derive_banner` for the exact rules and the judgment calls below).
- Recent: last 3 Episodes for this customer (all paths), each with date,
  headline, duration_s, style, and a coarse `state`.
- POST /home/request-today: thin wrapper around the existing
  POST /requests one-off flow, tagged created_from=home_empty_day.

Deferred, and why (per the PRD's own engineering notes and open questions):
- Suggestions (PRD §4, "up to three suggested requests each with a reason"):
  needs the AI Platform's shared semantic index for ranking candidates
  against interests — doesn't exist (see README's "AI Platform scope" and
  app/services/ai_platform.py, which only has structure_request/
  research_and_write_block so far). Returns an empty list; no placeholder
  ranking logic was written.
- Shared inventory for empty days (PRD §4, "up to three shared-inventory
  episodes matched to interests"): needs team-curated seed requests per
  interest cluster, which don't exist — see episode_generator.py's own
  scope note ("Shared inventory... needs team-curated seed requests per
  cluster, which don't exist"). Returns an empty list.
- Playback position / "left at m:ss" (PRD §4, Recent): there is no Player
  epic and no playback-position field anywhere in this codebase. Recent's
  `state` therefore only distinguishes a completed episode from a
  synthesized "no news that day" entry — it never claims "listened" or
  "left at m:ss", since there is no data source for either. Revisit once
  the Player PRD lands.
- job.eta (PRD's "Ready at HH:MM" countdown): GenerationJob.eta exists as a
  column but episode_generator.py never sets it anywhere in the pipeline —
  so it is always null today. That's an existing gap in the Generator, not
  something patched here; `banner.eta` simply passes through whatever is
  in the column (currently always None).
- Subscribing to job-status updates (PRD §5: "subscribe, not poll, for the
  countdown"): out of scope for a synchronous HTTP endpoint; a client
  polls GET /api/home or GET /generation/jobs/{id} for now. A push channel
  (websocket/SSE) is a separate piece of infrastructure, not attempted here.

Judgment calls made (no PRD text settles these — see docstrings below for
detail): no-job-yet-today is treated as `making` with no ETA rather than
`empty_day`, since we cannot yet tell day-zero-before-trigger apart from a
genuinely empty day; `failed` jobs are shown to the customer as `making`
with no ETA rather than exposing "failed" (an internal state) or jumping to
`empty_day` (which would falsely claim there is no news); and Recent does
show synthesized "no news that day" entries for empty-day jobs, per the
PRD's own open question #9 ("Does Recent show the empty-day entries or only
real episodes?") and the "Home is never empty" tenet — this is our choice,
not a settled PRD requirement.
"""
from datetime import date, datetime

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_cliente
from app.api.routes.requests import CrearRequestBody, RequestOut, crear_request
from app.db.session import get_db
from app.models.cliente import Cliente
from app.models.episode import Block, Episode
from app.models.generation_job import GenerationJob, JobStatus
from app.models.request import CreatedFrom, Request, RequestKind, RequestStatus

router = APIRouter(prefix="/home", tags=["Home"])


# ── Schemas ──────────────────────────────────────────────────────────────────

class BannerOut(BaseModel):
    state: str  # ready | making | late | empty_day | re_entry
    headline: str | None = None
    requests_count: int | None = None  # ready: number of answered requests (blocks); making/late: requests in progress
    duration_s: int | None = None
    style: str | None = None
    eta: datetime | None = None  # making/late only; see module scope note — always null until the Generator sets it


class RecentEpisodeOut(BaseModel):
    date: date
    headline: str | None
    duration_s: int | None
    style: str | None
    state: str  # completed | no_news — see module scope note on playback position


class HomeOut(BaseModel):
    banner: BannerOut
    recent: list[RecentEpisodeOut]
    suggestions: list = Field(default_factory=list)  # deferred — see module scope note
    shared_inventory: list = Field(default_factory=list)  # deferred — see module scope note


class RequestTodayBody(BaseModel):
    raw_text: str = Field(min_length=5, max_length=2000)


# ── Banner derivation ────────────────────────────────────────────────────────

async def _derive_banner(db: AsyncSession, cliente: Cliente) -> BannerOut:
    active_count_result = await db.execute(
        select(Request).where(Request.customer_id == cliente.id, Request.status == RequestStatus.active)
    )
    active_requests = active_count_result.scalars().all()
    if not active_requests:
        return BannerOut(state="re_entry")

    today = date.today()
    job_result = await db.execute(
        select(GenerationJob)
        .where(GenerationJob.customer_id == cliente.id, GenerationJob.fecha == today)
        .order_by(GenerationJob.creado_en.desc())
        .limit(1)
    )
    job = job_result.scalar_one_or_none()

    if job is None:
        # Ambiguous per the PRD: could be day-zero, or simply "before today's
        # scheduled trigger has run yet". We can't tell those apart from the
        # data we have (no per-customer "next scheduled run" record exists),
        # so we default to the optimistic, non-alarming state: "making" with
        # no ETA, rather than claiming "no news" for a day that hasn't
        # actually run yet.
        return BannerOut(state="making", requests_count=len(active_requests), eta=None)

    if job.status in (JobStatus.queued, JobStatus.researching, JobStatus.writing, JobStatus.voicing):
        return BannerOut(state="making", requests_count=len(active_requests), eta=job.eta)

    if job.status == JobStatus.late:
        return BannerOut(state="late", requests_count=len(active_requests), eta=job.eta)

    if job.status == JobStatus.empty:
        return BannerOut(state="empty_day")

    if job.status == JobStatus.ready:
        episode_result = await db.execute(
            select(Episode).where(Episode.customer_id == cliente.id, Episode.fecha == today)
            .order_by(Episode.published_at.desc())
            .limit(1)
        )
        episode = episode_result.scalar_one_or_none()
        if episode is None:
            # Shouldn't happen (job says ready but no episode row) — fall back
            # to a non-alarming state rather than erroring the whole banner.
            return BannerOut(state="making", requests_count=len(active_requests), eta=None)

        blocks_result = await db.execute(
            select(Block).where(Block.episode_id == episode.id, Block.request_id.is_not(None))
        )
        answered_blocks = blocks_result.scalars().all()
        return BannerOut(
            state="ready",
            headline=episode.headline,
            requests_count=len(answered_blocks),
            duration_s=episode.duration_s,
            style=episode.style,
        )

    # job.status == JobStatus.failed: an internal failure, not something the
    # customer should see verbatim ("failed" leaks internals and isn't
    # actionable for them). We map it to "making" with no ETA rather than
    # "empty_day", because failed does not mean "we checked and there was no
    # news" — that would be actively misleading. "making" at least leaves
    # room for a retry to succeed without over-promising a time.
    return BannerOut(state="making", requests_count=len(active_requests), eta=None)


# ── Recent derivation ────────────────────────────────────────────────────────

async def _derive_recent(db: AsyncSession, cliente: Cliente) -> list[RecentEpisodeOut]:
    episodes_result = await db.execute(
        select(Episode)
        .where(Episode.customer_id == cliente.id)
        .order_by(Episode.fecha.desc(), Episode.published_at.desc())
        .limit(3)
    )
    episodes = episodes_result.scalars().all()

    empty_jobs_result = await db.execute(
        select(GenerationJob)
        .where(GenerationJob.customer_id == cliente.id, GenerationJob.status == JobStatus.empty)
        .order_by(GenerationJob.fecha.desc())
        .limit(3)
    )
    empty_jobs = empty_jobs_result.scalars().all()

    dates_with_episodes = {e.fecha for e in episodes}
    entries: list[RecentEpisodeOut] = [
        RecentEpisodeOut(date=e.fecha, headline=e.headline, duration_s=e.duration_s, style=e.style, state="completed")
        for e in episodes
    ]
    entries += [
        RecentEpisodeOut(date=j.fecha, headline=None, duration_s=None, style=None, state="no_news")
        for j in empty_jobs
        if j.fecha not in dates_with_episodes  # a real episode always wins over a synthesized empty-day entry
    ]

    entries.sort(key=lambda entry: entry.date, reverse=True)
    return entries[:3]


# ── Endpoints ────────────────────────────────────────────────────────────────

@router.get("", response_model=HomeOut)
async def home(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    banner = await _derive_banner(db, cliente)
    recent = await _derive_recent(db, cliente)
    return HomeOut(banner=banner, recent=recent, suggestions=[], shared_inventory=[])


@router.post("/request-today", response_model=RequestOut, status_code=201)
async def request_today(
    body: RequestTodayBody,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """
    Thin wrapper over POST /requests (Request Management) — same flow, just
    fixing kind=one_off and created_from=home_empty_day so the origin is
    recorded accurately. Kept as its own endpoint (rather than telling the
    client to call POST /requests directly) because the PRD names this as a
    distinct Home action ("Request something for today") and the fixed
    created_from is meaningful provenance data worth not leaving to the
    client to set correctly.
    """
    return await crear_request(
        CrearRequestBody(raw_text=body.raw_text, kind=RequestKind.one_off, created_from=CreatedFrom.home_empty_day),
        cliente,
        db,
    )
