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
- Banner.blocks: per-block breakdown of the ready episode (id, request_id,
  sequence, start_s/end_s/duration_s, summary, had_more) alongside the
  existing aggregate headline/duration_s/requests_count fields — additive,
  see BlockSummaryOut's docstring. Reuses generation.py's `_block_common_fields`
  helper rather than a second, divergent block serialization.
- POST /home/request-today: thin wrapper around the existing
  POST /requests one-off flow, tagged created_from=home_empty_day.

Deferred, and why (per the PRD's own engineering notes and open questions):
- Suggestions (PRD §4, "up to three suggested requests each with a reason"):
  needs the AI Platform's shared semantic index for ranking candidates
  against interests — doesn't exist (see README's "AI Platform scope" and
  app/services/ai_platform.py, which only has structure_request/
  research_topic/write_block so far). Returns an empty list; no placeholder
  ranking logic was written.
- Shared inventory for empty days (PRD §4, "up to three shared-inventory
  episodes matched to interests"): now built. `shared_inventory`
  returns up to 3 Episodes tagged shared=True whose InventoryItem.tags
  overlap the customer's OnboardingState.selected_interests, most recent
  per matching tag first, each with a `reason` field ("Because you follow
  {tag}") per the PRD's "if we cannot say why, we do not show it" tenet —
  see _derive_shared_inventory below and app/services/episode_generator.py's
  "Built: shared inventory" section for how those Episodes get produced.
  A customer with no selected interests, or none matching any tag a shared
  episode currently exists for, correctly gets an empty list rather than a
  guessed match. Onboarding's own day-zero sample (PRD, separate from Home)
  is a smaller follow-up not wired up yet — see onboarding.py's scope note;
  the query below is exactly what that follow-up would reuse.
- Playback position / "left at m:ss" (PRD §4, Recent): there is no Player
  epic and no playback-position field anywhere in this codebase. Recent's
  `state` therefore only distinguishes a completed episode from a
  synthesized "no news that day" entry — it never claims "listened" or
  "left at m:ss", since there is no data source for either. Revisit once
  the Player PRD lands.
- job.eta (PRD's "Ready at HH:MM" countdown): now set for real by
  episode_generator.run_generation (see that module's _compute_eta) and
  kept current by its check_late_jobs watchdog when a job runs long enough
  to be relabelled `late` — `banner.eta` still just passes through
  whatever is in the column, unchanged here, but that column is no longer
  always null.
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
from app.api.routes.generation import _block_common_fields
from app.api.routes.requests import CrearRequestBody, RequestOut, crear_request
from app.db.session import get_db
from app.models.cliente import Cliente
from app.models.episode import Block, Episode
from app.models.generation_job import GenerationJob, InventoryItem, JobStatus
from app.models.onboarding import OnboardingState
from app.models.request import CreatedFrom, Request, RequestKind, RequestStatus

router = APIRouter(prefix="/home", tags=["Home"])


# ── Schemas ──────────────────────────────────────────────────────────────────

class BlockSummaryOut(BaseModel):
    """Per-block breakdown for the ready episode's banner, additive alongside
    the existing aggregate headline/duration_s/requests_count fields — the
    Home design (per-topic rows, currently-playing highlight) needs the list,
    but nothing about the aggregate fields changes for clients that don't
    read `blocks` yet (see ios/.../Networking/Models/HomeModels.swift, which
    doesn't decode this field today and isn't broken by its addition).

    Built from the same `_block_common_fields` helper generation.py's
    BlockOut uses, minus `script` (Home renders a list row, not a script
    reader — that stays a Player/Generation-only field).

    No "currently playing" field: there is no server-side concept of
    playback position anywhere in this codebase (see this module's own
    docstring, "Playback position" scope note) — which block is currently
    playing is purely client-side Player state, not something to invent a
    column for here.
    """
    id: str
    request_id: str | None  # null = intro/outro block
    sequence: int  # 0-based position in playback order (== this array's own order)
    start_s: int
    end_s: int
    duration_s: int
    summary: str  # Block.summary — the one-line topic/question text for this block
    had_more: bool


class BannerOut(BaseModel):
    state: str  # ready | making | late | empty_day | re_entry
    headline: str | None = None
    requests_count: int | None = None  # ready: number of answered requests (blocks); making/late: requests in progress
    duration_s: int | None = None
    style: str | None = None
    eta: datetime | None = None  # making/late only; see module scope note for how the Generator sets/refreshes it
    blocks: list[BlockSummaryOut] = Field(default_factory=list)  # ready only; see BlockSummaryOut docstring
    # ready only — lets a client tell "the player is playing TODAY'S episode" apart from
    # "the player is playing some other episode" (a past day or a shared sample), and open
    # it directly via GET /generation/episodes/{id}.
    episode_id: str | None = None


class RecentEpisodeOut(BaseModel):
    date: date
    headline: str | None
    duration_s: int | None
    style: str | None
    state: str  # completed | no_news — see module scope note on playback position
    episode_id: str | None = None  # null for a synthesized "no news that day" entry (nothing to play)


class SharedInventoryOut(BaseModel):
    episode_id: str
    headline: str | None
    duration_s: int | None
    style: str | None
    reason: str  # e.g. "Because you follow technology" — see module scope note
    tag: str | None = None  # the interest tag this sample belongs to (e.g. "technology")


class HomeOut(BaseModel):
    banner: BannerOut
    recent: list[RecentEpisodeOut]
    suggestions: list = Field(default_factory=list)  # deferred — see module scope note
    shared_inventory: list[SharedInventoryOut] = Field(default_factory=list)
    # Shared samples for tags the customer does NOT follow yet — "something new to try".
    # Kept separate from shared_inventory so the "if we cannot say why, we do not show it"
    # rule stays intact: shared_inventory's reason is a real match to their interests,
    # this list's reason honestly says it's an exploration ("Explore {tag}"), not a match.
    explore: list[SharedInventoryOut] = Field(default_factory=list)


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
            select(Block).where(Block.episode_id == episode.id).order_by(Block.start_s)
        )
        all_blocks = blocks_result.scalars().all()
        answered_blocks = [b for b in all_blocks if b.request_id is not None]
        return BannerOut(
            state="ready",
            headline=episode.headline,
            requests_count=len(answered_blocks),
            duration_s=episode.duration_s,
            style=episode.style,
            episode_id=str(episode.id),
            blocks=[
                BlockSummaryOut(**_block_common_fields(b), sequence=i)
                for i, b in enumerate(all_blocks)
            ],
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
        RecentEpisodeOut(
            date=e.fecha, headline=e.headline, duration_s=e.duration_s, style=e.style,
            state="completed", episode_id=str(e.id),
        )
        for e in episodes
    ]
    entries += [
        RecentEpisodeOut(date=j.fecha, headline=None, duration_s=None, style=None, state="no_news")
        for j in empty_jobs
        if j.fecha not in dates_with_episodes  # a real episode always wins over a synthesized empty-day entry
    ]

    entries.sort(key=lambda entry: entry.date, reverse=True)
    return entries[:3]


# ── Shared inventory derivation ──────────────────────────────────────────────

async def _derive_shared_inventory(db: AsyncSession, cliente: Cliente) -> list[SharedInventoryOut]:
    """
    Matches the customer's OnboardingState.selected_interests against tags on
    shared Episodes — see app/services/episode_generator.py's "Built: shared
    inventory" section for how those Episodes/InventoryItem rows are produced
    (app.api.routes.internal.generate_shared_inventory). No selected
    interests, or no shared episode currently tagged with any of them, both
    correctly return an empty list rather than a guessed match — this is the
    same "if we cannot say why, we do not show it" rule Home's suggestions
    already follow.

    Filters InventoryItem.tags in Python rather than a JSON-containment SQL
    filter: the shared-inventory table is small (one row per interest tag,
    refreshed at most once a day), so a plain fetch-and-filter is simpler and
    keeps this portable across whatever JSON column type the DB backend uses.
    """
    state = await db.get(OnboardingState, cliente.id)
    interests = state.selected_interests if state else []
    if not interests:
        return []

    latest_by_tag = await _latest_shared_by_tag(db)

    matched: list[SharedInventoryOut] = []
    for tag in interests:
        hit = latest_by_tag.get(tag)
        if not hit:
            continue
        episode, item = hit
        reason = (item.reason_template or "Because you follow {tag}").format(tag=tag)
        matched.append(SharedInventoryOut(
            episode_id=str(episode.id), headline=episode.headline,
            duration_s=episode.duration_s, style=episode.style, reason=reason, tag=tag,
        ))
        if len(matched) >= 3:
            break
    return matched


async def _latest_shared_by_tag(db: AsyncSession) -> dict[str, tuple[Episode, InventoryItem]]:
    rows_result = await db.execute(
        select(Episode, InventoryItem)
        .join(InventoryItem, InventoryItem.episode_id == Episode.id)
        .where(Episode.shared.is_(True))
        .order_by(Episode.fecha.desc(), Episode.published_at.desc())
    )
    latest_by_tag: dict[str, tuple[Episode, InventoryItem]] = {}
    for episode, item in rows_result.all():
        for tag in item.tags:
            latest_by_tag.setdefault(tag, (episode, item))  # rows are already newest-first
    return latest_by_tag


async def _derive_explore(db: AsyncSession, cliente: Cliente) -> list[SharedInventoryOut]:
    """
    Shared samples for tags the customer does NOT follow — Home's "Explore" shelf,
    the "other episodes I might like" the customer asked for. Deliberately a
    separate list from _derive_shared_inventory: that one only ever contains real
    matches to what they said they care about, so its `reason` is a true
    explanation. These are honestly labelled as exploration, never as a match.
    """
    state = await db.get(OnboardingState, cliente.id)
    followed = set(state.selected_interests) if state and state.selected_interests else set()

    explore: list[SharedInventoryOut] = []
    for tag, (episode, _item) in (await _latest_shared_by_tag(db)).items():
        if tag in followed:
            continue
        explore.append(SharedInventoryOut(
            episode_id=str(episode.id), headline=episode.headline,
            duration_s=episode.duration_s, style=episode.style, reason=f"Explore {tag}", tag=tag,
        ))
        if len(explore) >= 6:
            break
    return explore


# ── Endpoints ────────────────────────────────────────────────────────────────

@router.get("", response_model=HomeOut)
async def home(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    banner = await _derive_banner(db, cliente)
    recent = await _derive_recent(db, cliente)
    shared_inventory = await _derive_shared_inventory(db, cliente)
    explore = await _derive_explore(db, cliente)
    return HomeOut(
        banner=banner, recent=recent, suggestions=[], shared_inventory=shared_inventory, explore=explore,
    )


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
