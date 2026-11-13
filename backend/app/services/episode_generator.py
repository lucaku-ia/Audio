"""
Episode Generator PRD (Juan, Draft v1, proposed by Andrés for review).

Scope note — what's built vs. deferred:

Built: the on-demand path's pipeline — load -> research+write (per active
request, via ai_platform.research_topic) -> write (per listener, via
ai_platform.write_block) -> assemble
-> trim -> headline -> publish. Triggered manually via
POST /api/generation/run (app/api/routes/generation.py).

Built: the scheduled path's trigger — app.services.scheduler runs an
in-process asyncio ticker (started from app.main's lifespan) that calls
run_generation(..., path=EpisodePath.scheduled) once per customer per day,
at T-60 in their own Profile.delivery_timezone. See that module's docstring
for what's simplified (closest-minute granularity, no distributed lock).
This confirms the PRD's premise that the two paths "share the pipeline and
differ only in trigger and latency budget" — no pipeline code below changed
to add it, only the `path`/`fecha` parameters so a caller can say which
path/day it's triggering for.

Built: voicing, via app.services.ai_platform.synthesize (ElevenLabs). Each
block's script is synthesized separately and the resulting mp3s are
concatenated into one episode file, written to disk under
settings.MEDIA_DIR (a Railway persistent volume in production — see
app/core/config.py) and served at /media/{episode_id}.mp3 (see app.main's
StaticFiles mount). Requires ELEVENLABS_API_KEY; if unset,
ai_platform.elevenlabs_configured() is false and the job falls back to the
pre-TTS behavior below (script-only, status stays "voicing") rather than
failing. A TTS call that fails after the key is confirmed present is
likewise non-fatal — the episode still publishes as text-only and a
`generation_tts_failed` stage note records why. Verified working
end-to-end against production.

Built: `job.eta` and the late-job watchdog (closing a gap the scheduler's
own docstring and Home's own scope note both flagged as deferred: "the
scheduler triggers jobs on time but doesn't watch them afterward" — now
that Home exists, there's a surface to report to). `_compute_eta` sets a
real `eta` when every job is created: on-demand gets the PRD's "target 60
minutes" from creation time; scheduled gets the customer's actual
Profile.delivery_time/delivery_timezone as a real timestamp, not a
relative offset — that's the promise actually made to them. `check_late_jobs`
is the watchdog itself: called from app.services.scheduler's existing 60s
tick, it relabels (never cancels — see that function's own docstring for
why) any non-terminal job whose eta plus the PRD's +30 min hard limit has
passed to JobStatus.late, with a fresh `eta` re-estimate, and emits
`job_late`. See _compute_eta and check_late_jobs below for the exact
formulas.

Built: idempotency per (customer, fecha, path) — see run_generation. A
second call for the same customer/day/path returns the existing job as-is
(whatever its status, including "failed") instead of creating a duplicate.
Enforced both in-app (a SELECT before the INSERT) and at the DB level (a
UniqueConstraint on generation_jobs, backfilled onto existing tables in
app/db/migraciones.py). Two concurrent calls for the same (customer, fecha,
path) can both pass the SELECT and race on INSERT; the loser's
IntegrityError is caught and it returns the winner's job instead of a 500 —
see run_generation's docstring for what this does and doesn't guarantee.

Fixed (Defect 2 — an "empty" job used to be exactly as final as "ready" or
"failed", which meant a customer who got a genuinely empty day and then
added a new standing request was stuck seeing that same empty result for
the rest of the day, no matter what they added): a terminal `empty` job for
today can now be retried, up to _MAX_EMPTY_RETRIES_PER_DAY times, but only
when the customer has a standing request created after that job's
creado_en — see _empty_job_can_retry. A retry mutates the same
GenerationJob row in place (customer_id, fecha, path is still unique — a
retry was never going to insert a second row) and bumps its new
`retry_count` column. Every other terminal status is unaffected: `ready`
and `failed` are still returned unchanged on a repeat call, exactly as
before this fix.

Deferred, and why:
- Real per-block timestamp alignment: ElevenLabs' character-level timing
  lives behind a separate `/with-timestamps` endpoint, not used here.
  Block start_s/end_s still come from the word-count estimate
  (_seconds_for_script), which is now measuring against real audio it
  didn't generate — expect some drift, tightest on short blocks.
- Naive mp3 concatenation (raw byte concat, no re-encoding) between
  blocks: works with most players for this MVP but isn't a guaranteed-
  seamless join; revisit with a proper audio mux if gaps/clicks show up.
- Real novelty judgment ("new since we last told this customer," using the
  last 14 days of blocks via the AI Platform's shared semantic index):
  the index doesn't exist yet. research_topic only judges "is
  there anything new today" in isolation, not against history. A request
  can currently get an near-identical block two days running if the topic
  hasn't moved — that's the gap the real index closes.
- Source catalogue (PRD: "config file: source, API, license, language,
  topics. Only licensed or API sources. No scraping."): now built —
  app/models/source_catalogue.py, seeded from
  app/data/source_catalogue_seeds.json, with a GET /internal/source-catalogue
  read endpoint. Research itself still runs through Claude's server-side
  web_search tool, which is API-based and not scraping, so it already
  satisfied the PRD's mechanism-level tenet; what the catalogue adds is a
  license field, best-effort matched by domain onto whatever web_search
  actually returns (app/services/source_catalogue.attach_licenses), stored
  on Block.sources. Read that module's docstring before assuming more:
  this is a provenance/labeling layer applied AFTER the search already
  ran — there is no API-level way to restrict web_search itself to only
  the catalogued domains with this codebase's `anthropic` SDK usage, so a
  block can still cite a source outside the catalogue (license: null in
  that case, never fabricated). Revisit if/when a real allowlist-scoped
  search mechanism becomes available.

Built: shared inventory (PRD: "samples and suggestions generated by the
team for common interest clusters in the pilot, tagged shared = true,
excluded from per-customer cost"; engineering note: "same pipeline with a
synthetic customer per cluster; profile defaults; tagged shared"). No team
was available to curate real seed requests in this session, so
app/data/shared_inventory_seeds.json holds a real, usable placeholder list
(one seed per existing Onboarding interest tag) — its own top-level "_note"
key says plainly that it is not the team-curated content the PRD describes.

Design decision — synthetic customer, not a pipeline refactor: run_generation
takes a real Cliente and produces Requests/Episodes tied to a real
customer_id FK (Request.customer_id, Episode.customer_id are both real FKs
to clientes.id) — refactoring it to accept a bare request string with no
customer row would touch every read path that assumes a Cliente exists
(Profile lookup, active_for_generation, event emission). Simpler and lower-
risk: one persistent system Cliente per interest tag
(`shared-inventory+{tag}@system.lucaku.internal`, see
shared_inventory_email below), each with one standing Request holding that
tag's seed text. `generate_shared_episode` creates that Cliente/Request
on first use (idempotent — reused on every later refresh) and then calls
run_generation exactly as any other caller would, with
path=EpisodePath.shared and shared_tag=<tag>. run_generation itself only
needed two small, additive changes for this: (1) when path is shared, the
resulting Episode is stored with customer_id=None (per Episode's own
column comment, "null = shared inventory") and shared=True, rather than
tied to the synthetic customer; (2) an InventoryItem row is written
alongside it (episode_id, tags=[shared_tag], seed_request_text, and a
reason_template Home fills in as "Because you follow {tag}") — the
existing InventoryItem model (app/models/generation_job.py) already has
exactly these columns, so no new model was added.

System-customer isolation: the email pattern above is the only marker —
no new column was added to Cliente for this (no real customer/admin list
endpoint exists anywhere in this codebase to leak it into; the one place
that does aggregate by customer_id, Instrumentation's /cost-summary, now
explicitly excludes clientes matching this email pattern from its
by_customer breakdown — see app/api/routes/instrumentation.py). GenerationJob
rows for shared runs do keep customer_id set to the synthetic Cliente's id
(needed for the existing per-customer-per-day idempotency check to work
unmodified) — only the published Episode itself is customer_id=None.

Refresh: triggered manually via POST /internal/generate-shared-inventory
(app/api/routes/internal.py), gated the same as every other internal-only
route. No recurring scheduler was built for this — the PRD's own open
question ("how often are shared samples refreshed?") is unresolved, so a
manually-triggered endpoint is the right scope for now, matching this
session's other internal-ops-tool endpoints (prompt registry, Instrumentation
dashboard). Calling it again the same day is a safe no-op per tag, since
run_generation's existing (customer, fecha, path) idempotency applies
unchanged to the synthetic customers.

Not done (a smaller follow-up, not attempted here — see app/api/routes/
onboarding.py and app/models/onboarding.py's own scope notes): wiring a
day-zero shared sample into Onboarding's confirmation step. The underlying
data now exists and is queryable (Episode.shared=True joined to
InventoryItem.tags) exactly the way Home's own shared_inventory field
reads it — a future pass can reuse that same query from
app/api/routes/onboarding.py's confirm()/get_state() without needing any
further Generator or storage work.

Built: pending -> current version promotion. A request can carry a
pending_version_id (set by refine(), landing separately) whose RequestVersion
is meant to take effect "from the next generation," not immediately. This
run is that next generation, so before the research loop reads req.structured
we promote any pending version still in VersionStatus.pending: the current
version is marked superseded, the pending one is marked applied (with
aplicado_en stamped), request.current_version_id/structured move to it, and
pending_version_id is cleared. This runs inside the same try block as the
rest of the job, so a later failure rolls the promotion back with everything
else — a version should only look "applied" if the episode it was applied
for actually got produced. request.raw_text is deliberately left alone by
this promotion — it's sacred; only structured, current_version_id and
pending_version_id are updated here.

Decision (System Contracts gap, not yet resolved elsewhere): editar_request
(PATCH /requests/{id}) does not touch pending_version_id today. If a
customer edits their request while a refine is still pending, the pending
version was structured against raw_text that no longer exists — promoting
it later would silently overwrite the fresh edit with stale content. Fixed
at the source in app/api/routes/requests.py: editar_request now supersedes
any pending version instead of leaving it to be wrongly promoted here.

Built: cost per stage. Each `job.stages` entry (research/assemble/voicing)
and its matching `stage_completed` Event payload now carry a `cost` field —
the sum of real AICall cost incurred during that stage, not the timing-only
entries this used to be. research_topic and write_block each run once per active
request inside the research stage's loop, so research_cost accumulates
across every call in that loop, not just the last one. Threaded up without
touching research_topic's/write_block's/synthesize's public *business*
parameters: ai_platform._log_call now returns the cost of the AICall row it
just wrote, and both direct callers pass it back to their own caller
(BlockResult gained a `cost` field; synthesize now returns `(bytes, cost)`
instead of bare bytes) — deliberately not a time-window `SELECT SUM(cost)
FROM ai_calls WHERE ...` scoped by customer_id/purpose/timestamp, which
would be a lossy heuristic if a customer has two jobs running concurrently
or two stages complete in the same wall-clock second.
"""
import logging
import time
import uuid
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.routes.requests import active_for_generation
from app.core.config import settings
from app.models.cliente import AuthProvider, Cliente
from app.models.episode import Block, Episode, EpisodePath
from app.models.generation_job import GenerationJob, InventoryItem, JobStatus
from app.models.profile import Profile
from app.models.request import CreatedFrom, Request, RequestKind, RequestStatus, RequestVersion, VersionStatus
from app.services import ai_platform, capsules, told_log
from app.services.events import emitir

logger = logging.getLogger(__name__)

_WORDS_PER_MINUTE = 150  # rough narration rate, used only to estimate duration/offsets pre-TTS
_INTRO_OUTRO_SECONDS = 15

# PRD: "Target 60 minutes, hard limit +30" — see _compute_eta and check_late_jobs.
_ON_DEMAND_TARGET_MINUTES = 60
_HARD_LIMIT_SLACK_MINUTES = 30
# Grace window handed out as the "new ETA" the moment a job is marked late — not a PRD
# number (the PRD only specifies the original 60/+30 budget, not what to promise after
# it's blown), just a reasonable, clearly-labelled re-estimate so Home has something
# concrete to show rather than leaving eta null again. See check_late_jobs.
_LATE_GRACE_MINUTES = 15

# Defect 2 fix — cap on how many extra times run_generation will re-research a
# same-day job that already came back terminal `empty`, once the customer has
# added a standing request since. See _empty_job_can_retry and run_generation's
# docstring for the full mechanism; this constant is the "not unbounded" half of
# that fix, and here's the arithmetic behind the number:
#
# Measured cost of one full pipeline pass through research_and_write_block +
# synthesize for a single-request customer is ~$0.43 research + ~$0.15 voicing
# (~$0.58/run; see Instrumentation's per-stage cost tracking on GenerationJob.stages,
# which is exactly what this number comes from). Nothing in this codebase caps a
# customer's overall daily spend yet (the AI Platform PRD's own "budgets/rate
# limits" item is still listed as deferred), so a per-job retry cap is the only
# lever available today to keep "let a genuinely empty day be revisited" from
# turning into "an unbounded cost sink triggered by repeatedly adding/removing
# standing requests." Capping at 2 retries means at most 3 total pipeline passes
# for one (customer, fecha, path) in a day — the original attempt plus 2 — for a
# worst case of roughly 3 x $0.58 ~= $1.74 per customer per day from this path.
# That's a small, explicit, easily-raised number, not a real budget calculation;
# revisit once a real per-customer daily spend tracker exists.
_MAX_EMPTY_RETRIES_PER_DAY = 2

# Shared inventory — see module docstring's "Built: shared inventory" section.
# The domain marks a Cliente row as a synthetic, system-owned account rather
# than a real customer; Instrumentation's /cost-summary filters on it
# explicitly so shared-sample generation cost never gets attributed to a
# real "active customer" in that dashboard.
SHARED_INVENTORY_EMAIL_DOMAIN = "system.lucaku.internal"


def shared_inventory_email(tag: str) -> str:
    return f"shared-inventory+{tag}@{SHARED_INVENTORY_EMAIL_DOMAIN}"


def _seconds_for_script(script: str) -> float:
    word_count = len(script.split())
    return (word_count / _WORDS_PER_MINUTE) * 60


async def _compute_eta(db: AsyncSession, cliente: Cliente, path: EpisodePath, fecha: date, created_at: datetime) -> datetime:
    """
    On-demand: target ~60 minutes from job creation (PRD: "Target 60 minutes,
    hard limit +30" — the +30 itself is applied separately, in
    check_late_jobs, rather than baked into this value, so `eta` always
    reads as "when we're aiming to be done").

    Scheduled: the customer's own configured delivery moment
    (Profile.delivery_time/delivery_timezone), not a relative offset — that
    is the actual promise made to them, distinct from the T-60 trigger
    instant app.services.scheduler computes to *start* the job. Reuses the
    same combine-with-tz pattern as scheduler._due_candidates rather than
    re-deriving it. Falls back to the on-demand formula if the profile,
    delivery_time, or timezone is missing/invalid — better an approximate
    real estimate than a null one.

    Returned as a naive UTC datetime, matching every other timestamp column
    in this codebase (see e.g. GenerationJob.creado_en's datetime.utcnow()
    default) — storing a tz-aware value here would make later comparisons
    against datetime.utcnow() (in check_late_jobs) silently wrong.
    """
    if path != EpisodePath.scheduled:
        return created_at + timedelta(minutes=_ON_DEMAND_TARGET_MINUTES)

    result = await db.execute(select(Profile).where(Profile.customer_id == cliente.id))
    perfil = result.scalar_one_or_none()
    if perfil is None or perfil.delivery_time is None:
        return created_at + timedelta(minutes=_ON_DEMAND_TARGET_MINUTES)

    try:
        tz = ZoneInfo(perfil.delivery_timezone)
    except ZoneInfoNotFoundError:
        return created_at + timedelta(minutes=_ON_DEMAND_TARGET_MINUTES)

    delivery_at_local = datetime.combine(fecha, perfil.delivery_time, tzinfo=tz)
    return delivery_at_local.astimezone(timezone.utc).replace(tzinfo=None)


_NON_TERMINAL_STATUSES = (JobStatus.queued, JobStatus.researching, JobStatus.writing, JobStatus.voicing)


async def check_late_jobs(db: AsyncSession) -> list[GenerationJob]:
    """
    Watchdog: relabels — never cancels — a job whose eta plus the PRD's
    +30 min hard limit has passed while it's still non-terminal. Called
    from app.services.scheduler's existing 60s tick (see that module for
    why: it's the only periodic infrastructure in this single-process app,
    and the same check applies uniformly to both paths since both now set a
    real `eta`).

    run_generation runs synchronously within one request/tick, so a job
    stuck past its budget is never actually "cancelled" here — there is no
    clean way to kill a coroutine already mid-flight, and that's explicitly
    out of scope. This only flips job.status to JobStatus.late and rewrites
    job.eta to a fresh, clearly-labelled re-estimate (now + _LATE_GRACE_MINUTES)
    so Home's "late (with new ETA)" banner state has real data to show — the
    underlying run keeps executing to whatever conclusion it reaches and
    will overwrite status/eta again itself once it finishes (ready/empty/failed).

    A review of this design found a real gap the paragraph above glossed
    over: run_generation's own INTERMEDIATE status writes (researching ->
    writing -> voicing) are plain unconditional UPDATEs from a long-lived
    in-memory job object on a different session — without a guard, one of
    those writes landing after this function marks a job late would
    silently revert it to writing/voicing, putting it back in this
    function's non-terminal scan and risking a repeated late relabel (and
    duplicate job_late events) once its fresh eta also lapses. Fixed via
    run_generation's _advance_status_unless_late helper, which every
    intermediate transition now goes through — only the terminal
    transitions (ready/empty/failed) still win unconditionally, which is
    correct: a run that finishes should always report its real outcome
    regardless of how late it finished.
    """
    now = datetime.utcnow()
    result = await db.execute(
        select(GenerationJob).where(
            GenerationJob.status.in_(_NON_TERMINAL_STATUSES),
            GenerationJob.eta.isnot(None),
        )
    )
    newly_late: list[GenerationJob] = []
    for job in result.scalars().all():
        # asyncpg round-trips a TIMESTAMPTZ column back as timezone-aware (UTC) even
        # though _compute_eta wrote it naive — strip tzinfo so this compares cleanly
        # against the naive datetime.utcnow() this whole codebase otherwise standardizes
        # on (see e.g. GenerationJob.creado_en's default), rather than raising
        # "can't compare offset-naive and offset-aware datetimes".
        job_eta = job.eta.replace(tzinfo=None) if job.eta.tzinfo else job.eta
        deadline = job_eta + timedelta(minutes=_HARD_LIMIT_SLACK_MINUTES)
        if now <= deadline:
            continue
        job.status = JobStatus.late
        job.eta = now + timedelta(minutes=_LATE_GRACE_MINUTES)
        await emitir(db, "job_late", customer_id=job.customer_id, source="episode_generator",
                     job_id=str(job.id), new_eta=job.eta.isoformat())
        newly_late.append(job)
    if newly_late:
        await db.commit()
    return newly_late


async def _advance_status_unless_late(db: AsyncSession, job: GenerationJob, new_status: JobStatus) -> None:
    """
    Sets job.status to new_status UNLESS check_late_jobs has already relabelled this
    row `late` on another session concurrently with this run — otherwise this
    in-memory `job` object's next commit blindly overwrites `late` back to
    `writing`/`voicing` (a plain UPDATE has no idea another process touched the row
    since it was loaded), which put the job back in check_late_jobs' non-terminal
    scan and let it get marked late again once its fresh eta also expired. Use this
    ONLY for intermediate, non-terminal transitions (writing, voicing) — the final
    terminal ones (ready/empty/failed) must still win unconditionally regardless of
    a `late` label, since those represent the run actually finishing.

    One extra fresh-status query per transition (two per run) is a deliberate,
    cheap trade against re-querying job.stages/eta too, which aren't at risk here —
    only .status is written elsewhere.
    """
    current_status = (
        await db.execute(select(GenerationJob.status).where(GenerationJob.id == job.id))
    ).scalar_one()
    if current_status != JobStatus.late:
        job.status = new_status


async def _promote_pending_version(db: AsyncSession, req: Request) -> None:
    """Applies req.pending_version_id, if any, so this generation run researches
    against it rather than against stale current data. See module docstring."""
    if not req.pending_version_id:
        return

    pendiente = await db.get(RequestVersion, req.pending_version_id)
    if not pendiente or pendiente.status != VersionStatus.pending or pendiente.request_id != req.id:
        # Already applied/superseded by something else (e.g. an intervening edit),
        # or (defensively — should never happen) pointing at another request's
        # version, which we refuse to trust rather than overwrite req.structured
        # with the wrong request's data. Either way: nothing to promote, drop
        # the stale pointer.
        req.pending_version_id = None
        return

    if req.current_version_id:
        actual = await db.get(RequestVersion, req.current_version_id)
        if actual and actual.request_id == req.id:
            actual.status = VersionStatus.superseded

    pendiente.status = VersionStatus.applied
    pendiente.aplicado_en = datetime.utcnow()

    req.current_version_id = pendiente.id
    req.structured = pendiente.structured
    req.pending_version_id = None


def _failure_reason(exc: Exception) -> str:
    """What goes into job.stages for a failure. A spend-guard refusal records
    its stable, user-safe code ("budget_exceeded" / "ai_paused") instead of an
    exception string."""
    return exc.code if isinstance(exc, ai_platform.AIBlocked) else str(exc)


def _failure_stage(exc: Exception, **extra) -> dict:
    stage = {"error": _failure_reason(exc), **extra}
    if isinstance(exc, ai_platform.AIBlocked):
        stage["code"] = exc.code
    return stage


_BLOCKED_CODES = ("budget_exceeded", "ai_paused")
# Job-level re-voice rounds (a job that voiced NOTHING and is `failed`).
_MAX_REVOICE_ROUNDS = 3


async def _blocked_job_can_retry(db: AsyncSession, customer_id: uuid.UUID, job: GenerationJob) -> bool:
    """
    A job that failed ONLY because the spend guard refused it (daily budget or
    kill switch) may be re-run in place once the guard would now let it
    through: the switch was flipped back, the limit raised, or (via a new
    customer-local day) the budget window moved. Never while the guard still
    refuses, so repeated polling cannot loop or spend; bounded by the same
    per-day retry cap as empty days.
    """
    if job.status != JobStatus.failed or job.retry_count >= _MAX_EMPTY_RETRIES_PER_DAY:
        return False
    if not any(st.get("code") in _BLOCKED_CODES for st in (job.stages or [])):
        return False
    try:
        await ai_platform.guard_paid_call(db, customer_id, "generation_precheck", emit=False)
    except ai_platform.AIBlocked:
        return False
    return True


async def _empty_job_can_retry(db: AsyncSession, customer_id: uuid.UUID, job: GenerationJob) -> bool:
    """
    Defect 2 fix: a same-day job that ended in terminal `empty` ("no news
    today") must not lock the customer out of ever getting a real episode
    for the rest of that day — not even after they add a new standing
    request that could plausibly have news. Before this, run_generation's
    idempotency check treated `empty` exactly like `ready`/`failed`: any
    later call just returned the same stale job, so a customer who added a
    request minutes after an empty result got that empty result again,
    forever, until the next day's job.

    Allows a bounded re-run only when BOTH hold:
    - The retry cap (_MAX_EMPTY_RETRIES_PER_DAY) hasn't been hit yet — see
      that constant's docstring for the cost math behind the number.
    - The customer has a standing request created after this job's
      `creado_en` — the signal that something actually changed since the
      pipeline last ran and found nothing. Without this check, calling
      run_generation again would just re-spend the research cost to
      rediscover the same empty result for the same requests.

    One_off requests deliberately don't count here: a one_off is answered
    (or not) by the very next run regardless, and never sits around waiting
    like a standing request does — it isn't the "new thing to check" the PRD
    means by an empty day being revisited after the customer adds a request.
    """
    if job.status != JobStatus.empty:
        return False
    if job.retry_count >= _MAX_EMPTY_RETRIES_PER_DAY:
        return False
    result = await db.execute(
        select(Request.id)
        .where(
            Request.customer_id == customer_id,
            Request.kind == RequestKind.standing,
            Request.creado_en > job.creado_en,
        )
        .limit(1)
    )
    return result.scalar_one_or_none() is not None


async def _synthesize_episode(
    db: AsyncSession,
    *,
    cliente: Cliente,
    episode: Episode,
    block_rows: list[Block],
    voice_id: str | None,
) -> float:
    """
    Voice every block, assemble one file, and publish the episode. Returns the
    cost actually spent. Raises on any synthesis failure — the caller decides
    what a failure means.

    Extracted from run_generation so the re-voice path (revoice_job) runs the
    SAME code rather than a second copy that drifts. A second implementation of
    "turn scripts into the published episode" is exactly the kind of duplicate
    that ends up publishing an episode one way and re-publishing it another.

    Cost is accumulated in a loop rather than a comprehension on purpose: if a
    later block raises, whatever was already spent on earlier blocks is real,
    was billed, and has AICall rows — losing it would understate the cost of a
    failed run.
    """
    # Phase 1a (audio capsules): each block is voiced on its own with failure
    # isolation, so this raises ONLY when no capsule at all could be voiced
    # (the job then fails exactly as before, with the stable budget code when
    # the guard refused). Otherwise the concatenated file is built from the
    # voiced capsules and the episode publishes. Word timestamps are
    # capsule-relative (0.0 = first word of that block's own audio).
    cliente_id = cliente.id
    outcome = await capsules.voice_pending(
        db, cliente_id=cliente_id, episode=episode, blocks=block_rows, voice_id=voice_id,
    )
    if not outcome.voiced:
        # A spend-guard refusal wins over provider errors so the job failure
        # carries the stable code (_blocked_job_can_retry keys off it).
        exc = outcome.report_error or RuntimeError("no capsule could be voiced")
        # Carry the partial spend out so the caller can record what the attempt cost.
        exc.voicing_cost = outcome.spent  # type: ignore[attr-defined]
        raise exc
    await capsules.build_concatenated_file(db, episode, block_rows)
    await _mark_answered(db, cliente, [b for b in block_rows if capsules.counts_as_delivered(b)])
    return outcome.spent


async def _mark_answered(db: AsyncSession, cliente: Cliente, blocks: list[Block]) -> None:
    """
    A request counts as answered only once its capsule is DELIVERED (inside the
    episode's concatenated file, or a legacy no-TTS block) — doc 4.1. A failed
    capsule leaves its one_off request active. Runs after the episode is
    published and committed, so it must never fail the job: errors are logged
    and rolled back. Idempotent: a request already answered for this episode
    (e.g. a pre-deploy episode re-voiced post-deploy) is skipped, so
    `request_answered` is never emitted twice.
    """
    blocks = [b for b in blocks if b.request_id and capsules.counts_as_delivered(b)]
    if not blocks:
        return
    try:
        reqs = {r.id: r for r in (await db.execute(
            select(Request).where(Request.id.in_([b.request_id for b in blocks])))).scalars().all()}
        episodes: dict[uuid.UUID, Episode | None] = {}
        for b in blocks:
            req = reqs.get(b.request_id)
            if req is None:
                continue
            if b.episode_id not in episodes:
                episodes[b.episode_id] = await db.get(Episode, b.episode_id)
            ep = episodes[b.episode_id]
            if req.fulfilled_episode_id == b.episode_id:
                continue  # one_off already fulfilled by this episode
            if ep is not None and req.last_answered_at is not None:
                created = ep.creado_en if ep.creado_en.tzinfo else ep.creado_en.replace(tzinfo=timezone.utc)
                answered = req.last_answered_at if req.last_answered_at.tzinfo \
                    else req.last_answered_at.replace(tzinfo=timezone.utc)
                if answered >= created:
                    continue  # already answered at/after this episode was built
            req.last_answered_at = datetime.now(timezone.utc)
            if req.kind.value == "one_off":
                req.status = RequestStatus.fulfilled
                req.fulfilled_episode_id = b.episode_id
            await emitir(db, "request_answered", customer_id=cliente.id, source="episode_generator",
                         request_id=str(req.id), episode_id=str(b.episode_id), had_more=bool(b.had_more))
        await db.commit()
    except Exception:  # noqa: BLE001
        logger.exception("could not mark requests answered; episode stays published")
        await db.rollback()


async def _revoice_late_capsules(db: AsyncSession, cliente: Cliente, job: GenerationJob) -> None:
    """
    Give capsules that failed (or were blocked by the budget) in an episode that
    already published another bounded try. Touches ONLY those blocks: the
    concatenated file, Episode.audio_url and the other blocks' offsets are never
    rewritten. The late capsule is therefore reachable through the playlist
    endpoint only. One try per call, spaced by LATE_REVOICE_BACKOFF_S, capped by
    VOICE_MAX_TOTAL_ATTEMPTS, and refused while the spend guard refuses.
    """
    # OFF by default: no shipped client can play a late capsule, so paying for
    # it would buy audio nobody hears (see settings.CAPSULE_LATE_REVOICE_ENABLED).
    if not settings.CAPSULE_LATE_REVOICE_ENABLED:
        return
    if job.status != JobStatus.ready or not ai_platform.elevenlabs_configured():
        return
    episode = (await db.execute(
        select(Episode).where(
            Episode.customer_id == cliente.id, Episode.fecha == job.fecha, Episode.path == job.path,
            Episode.published_at.is_not(None),
        ).order_by(Episode.creado_en.desc()).limit(1)
    )).scalar_one_or_none()
    if episode is None:
        return
    blocks = list((await db.execute(select(Block).where(Block.episode_id == episode.id))).scalars().all())
    # Tight bound: at most LATE_REVOICE_PER_CALL capsules, one try each, so a
    # POST /run on a ready job never blocks for long.
    due = [b for b in sorted(blocks, key=capsules.sort_key)
           if capsules.late_revoice_due(b, episode)][:capsules.LATE_REVOICE_PER_CALL]
    if not due:
        return
    try:
        await ai_platform.guard_paid_call(db, cliente.id, "generation_precheck", emit=False)
    except ai_platform.AIBlocked:
        return
    perfil = await db.get(Profile, cliente.id)
    outcome = await capsules.voice_pending(
        db, cliente_id=cliente.id, episode=episode, blocks=due,
        voice_id=perfil.voice_id if perfil else None, max_tries=1,
    )
    # A late capsule is NOT marked answered / told: it is outside the file the
    # shipped client plays (capsules.counts_as_delivered is False for it).
    if outcome.spent or outcome.voiced:
        job.stages = [*job.stages, {
            "stage": "capsule_revoice", "cost": outcome.spent, "voiced": len(outcome.voiced),
        }]
        await db.commit()


async def _revoice_failed_job(db: AsyncSession, cliente: Cliente, job: GenerationJob) -> bool:
    """
    Recover a job that died in voicing, WITHOUT paying for research again.

    When synthesis fails, run_generation deliberately keeps the episode and its
    finished block scripts and leaves the episode unpublished (see the voicing
    stage's own comment). That state exists precisely so a failed run can be
    completed later for the price of the audio alone — research and writing are
    the larger share of a run's cost and are already paid for. Until this
    function existed, nothing consumed that, so the saved scripts were just
    rows nobody read.

    Returns True if it re-voiced (successfully or not), False if this job isn't
    a re-voice candidate and the caller should fall through to its normal path.

    Narrow by design. A job qualifies only when ALL of these hold:
      - it is terminal `failed`
      - its last recorded failure was in the VOICING stage, not research or
        writing — a job that failed earlier has no scripts to re-voice, and
        pretending otherwise would publish an empty episode
      - an unpublished episode exists for it with at least one block that has
        a non-empty script
      - TTS is actually configured now

    The most common real cause is a quota the founder has since topped up, or
    a provider 5xx. Both are worth exactly one cheap retry; neither is worth
    re-researching the day from scratch.
    """
    if job.status != JobStatus.failed or not ai_platform.elevenlabs_configured():
        return False
    # Still over budget / switched off: re-voicing would only fail again (and
    # pile up stage entries and retry_count), so leave the job as it is.
    try:
        await ai_platform.guard_paid_call(db, cliente.id, "generation_precheck", emit=False)
    except ai_platform.AIBlocked:
        return False

    voicing_stages = [st for st in (job.stages or []) if st.get("stage") == "voicing" and st.get("error")]
    if not voicing_stages:
        # Failed somewhere else — there are no scripts to re-voice, and
        # treating this as a re-voice candidate would publish an empty episode.
        return False

    episode = (await db.execute(
        select(Episode).where(
            Episode.customer_id == cliente.id,
            Episode.fecha == job.fecha,
            Episode.path == job.path,
            Episode.published_at.is_(None),
        ).order_by(Episode.creado_en.desc()).limit(1)
    )).scalar_one_or_none()
    if episode is None:
        return False

    block_rows = list((await db.execute(
        select(Block).where(Block.episode_id == episode.id).order_by(Block.sequence, Block.start_s)
    )).scalars().all())
    if not block_rows or not any((b.script or "").strip() for b in block_rows):
        return False
    # Bounded: every capsule that still needs audio has used up its lifetime
    # tries (capsules.VOICE_MAX_TOTAL_ATTEMPTS), or the job already had its
    # re-voice rounds. Budget refusals do not consume tries, so the round cap
    # is what bounds those.
    if job.retry_count >= _MAX_REVOICE_ROUNDS or not any(
        b.audio_status != capsules.VOICED and (b.voice_attempts or 0) < capsules.VOICE_MAX_TOTAL_ATTEMPTS
        for b in block_rows
    ):
        return False

    perfil = await db.get(Profile, cliente.id)
    voice_id = perfil.voice_id if perfil else None

    # Atomic claim of the JOB: only one overlapping caller re-voices it.
    claim = await db.execute(
        update(GenerationJob)
        .where(GenerationJob.id == job.id, GenerationJob.status == JobStatus.failed)
        .values(status=JobStatus.voicing, retry_count=GenerationJob.retry_count + 1)
        .execution_options(synchronize_session=False)
    )
    await db.commit()
    await db.refresh(job)
    if claim.rowcount != 1:
        return False  # lost the race: the job is now `voicing`, so callers return it unchanged
    start = time.monotonic()
    await emitir(db, "stage_started", customer_id=cliente.id, source="episode_generator",
                 job_id=str(job.id), stage="revoicing")

    try:
        cost = await _synthesize_episode(
            db, cliente=cliente, episode=episode, block_rows=block_rows, voice_id=voice_id,
        )
        job.status = JobStatus.ready
        job.stages = [*job.stages, {
            "stage": "revoicing", "latency_ms": int((time.monotonic() - start) * 1000), "cost": cost,
        }]
        await emitir(db, "episode_published", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), episode_id=str(episode.id), had_more_any=episode.had_more_any)
    except Exception as exc:
        cost = getattr(exc, "voicing_cost", 0.0)
        job.status = JobStatus.failed  # still terminal — never back to a non-terminal status
        job.stages = [*job.stages, _failure_stage(
            exc, stage="revoicing", cost=cost, latency_ms=int((time.monotonic() - start) * 1000),
        )]
        await emitir(db, "job_failed", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), stage="revoicing", episode_id=str(episode.id))

    await db.commit()
    await db.refresh(job)
    job.started_new_run = True
    return True


async def run_generation(
    db: AsyncSession,
    cliente: Cliente,
    path: EpisodePath = EpisodePath.on_demand,
    fecha: date | None = None,
    shared_tag: str | None = None,
) -> GenerationJob:
    """
    Runs the full pipeline synchronously for one customer and returns the
    GenerationJob row describing the outcome. `path` and `fecha` let a
    caller say which PRD path and which calendar day this run is for — the
    on-demand route (app/api/routes/generation.py) leaves both at their
    defaults (today, on_demand); app.services.scheduler passes
    path=EpisodePath.scheduled and the customer's local delivery date, since
    that can differ from the server's own date near midnight.

    `shared_tag` is only meaningful with path=EpisodePath.shared — see
    generate_shared_episode below, the only caller that sets it. When set,
    the resulting Episode (if any) is published with customer_id=None and
    shared=True instead of tied to `cliente` (per Episode's own "null =
    shared inventory" column comment), and an InventoryItem row tags it for
    Home's interest matching. `cliente` itself is still required and still
    owns the GenerationJob row — see module docstring's "Design decision".

    Idempotent per (customer, fecha, path): "never fill" means a second
    call for the same customer/day/path must not produce a second episode,
    so this returns the existing job unchanged (whatever its status —
    ready, failed, etc.) instead of erroring or re-running the pipeline.
    Enforced here via a SELECT before the INSERT, backed by a DB-level
    UniqueConstraint (see GenerationJob.__table_args__) as the source of
    truth.

    Defect 2 fix — the one exception to "unchanged": a job whose status is
    the terminal `empty` ("no news today") is no longer forever final for
    that day. If the customer has since added a standing request, and this
    (customer, fecha, path) hasn't already been retried past
    _MAX_EMPTY_RETRIES_PER_DAY times, this re-runs the pipeline on the SAME
    row (the unique constraint forbids a second row for this key) instead of
    returning the stale empty result — see _empty_job_can_retry for the
    exact conditions and the retry cap's docstring for the cost reasoning.
    Every other terminal status (ready, failed) is still returned unchanged,
    same as before this fix — only `empty` gets a second chance, since only
    `empty` can be invalidated by "the customer asked for something new."

    The returned GenerationJob also carries a plain (non-persisted) Python
    attribute, `started_new_run: bool`, set before every return in this
    function — True when this call actually kicked off (or re-ran) the
    pipeline, False when it just handed back an existing job unchanged. Only
    a genuinely new HTTP-facing trigger point needs this (see
    app/api/routes/generation.py's JobOut.run_started); scheduler.py and
    generate_shared_episode's own callers don't read it and are unaffected.

    Two concurrent calls for the same (customer, fecha, path) can both pass
    the initial SELECT before either commits and race to INSERT a brand-new
    row; rather than let the loser surface the resulting IntegrityError as a
    500, that insert is wrapped to catch exactly that race and return the
    winner's job instead — still no row lock (e.g. SELECT ... FOR UPDATE),
    so this is a catch-and-recover rather than a true mutex, but it means a
    concurrent on-demand call and scheduler tick for the same customer both
    get a clean job back rather than one of them erroring. The same caveat
    now also applies, undefended, to two concurrent empty-job retries: both
    could pass _empty_job_can_retry and both UPDATE the same row — a lost-
    update race, not a crash, and no worse than the pre-existing "no
    distributed lock" gap this module's other docstrings already flag.

    Also promotes each request's pending RequestVersion (if any) to current
    before reading its structured data for research — see
    _promote_pending_version and the module docstring.
    """
    today = fecha or date.today()

    async def _find_existing() -> GenerationJob | None:
        result = await db.execute(
            select(GenerationJob).where(
                GenerationJob.customer_id == cliente.id,
                GenerationJob.fecha == today,
                GenerationJob.path == path,
            )
        )
        return result.scalar_one_or_none()

    existing_job = await _find_existing()
    if existing_job is not None:
        # A job that died in voicing already has its research and writing paid
        # for. Finish it for the price of the audio instead of sending the
        # customer down the full pipeline again — see _revoice_failed_job.
        if await _revoice_failed_job(db, cliente, existing_job):
            return existing_job
        # A published episode may still hold capsules that failed to voice:
        # one bounded retry of just those (never rewrites the published file).
        await _revoice_late_capsules(db, cliente, existing_job)
        if not (await _blocked_job_can_retry(db, cliente.id, existing_job)
                or await _empty_job_can_retry(db, cliente.id, existing_job)):
            existing_job.started_new_run = False
            return existing_job
        # Re-run in place — see _empty_job_can_retry and this function's own
        # "Defect 2 fix" docstring note for why this mutates the existing row
        # instead of inserting a new one.
        job = existing_job
        job.retry_count += 1
        job.status = JobStatus.researching
        job.stages = []
        job.eta = await _compute_eta(db, cliente, path, today, datetime.utcnow())
        await emitir(db, "job_retried", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), path=job.path.value, retry_count=job.retry_count)
        await db.commit()
        await db.refresh(job)
    else:
        job_created_at = datetime.utcnow()
        eta = await _compute_eta(db, cliente, path, today, job_created_at)
        job = GenerationJob(
            customer_id=cliente.id,
            fecha=today,
            path=path,
            status=JobStatus.researching,
            eta=eta,
            stages=[],
        )
        db.add(job)
        try:
            await db.commit()  # persist the job row on its own before doing any work, so a failure
        except IntegrityError:
            # Lost the race to a concurrent call for the same (customer, fecha, path) —
            # its insert landed first. Recover by returning that row instead of a 500.
            await db.rollback()
            existing_job = await _find_existing()
            if existing_job is not None:
                existing_job.started_new_run = False
                return existing_job
            raise  # constraint violation for a reason other than the expected race
        await db.refresh(job)  # below can mark *this* row failed instead of losing it to rollback
        await emitir(db, "job_created", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), path=job.path.value)
        await db.commit()

    job.started_new_run = True

    try:
        research_start = time.monotonic()
        await emitir(db, "stage_started", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), stage="research")
        snapshot = await active_for_generation(at=None, cliente=cliente, db=db)
        # snapshot's request lists are RequestOut pydantic models — not JSON-serializable
        # as-is for the `snapshot` JSON column, so dump them before storing.
        job.snapshot = {
            **snapshot,
            "standing_requests": [r.model_dump(mode="json") for r in snapshot["standing_requests"]],
            "one_off_requests": [r.model_dump(mode="json") for r in snapshot["one_off_requests"]],
        }

        result = await db.execute(select(Profile).where(Profile.customer_id == cliente.id))
        perfil = result.scalar_one_or_none()
        style = perfil.narration_style.value if perfil else "news"
        language = perfil.language.value if perfil else cliente.idioma
        voice_id = perfil.voice_id if perfil else None
        max_length_minutes = perfil.max_length_minutes if perfil else None

        all_requests = snapshot["standing_requests"] + snapshot["one_off_requests"]
        active_result = await db.execute(
            select(Request).where(Request.customer_id == cliente.id, Request.status == RequestStatus.active)
        )
        req_by_id = {str(r.id): r for r in active_result.scalars().all()}

        # Research: customer-neutral, one pass per topic. Kept separate from
        # writing below so the expensive half is cacheable/shareable per topic
        # while the cheap half stays per-listener — see
        # ai_platform.research_topic's docstring for the full reasoning.
        researched: list[dict] = []
        research_cost = 0.0
        for req_out in all_requests:
            req = req_by_id.get(req_out.id)
            if not req:
                continue
            await _promote_pending_version(db, req)  # "applies from next generation" — this run is that next one
            structured = req.structured or {}
            findings = await ai_platform.research_topic(
                db,
                raw_text=req.raw_text,
                topic=structured.get("topic", req.raw_text[:60]),
                scope=structured.get("scope", ""),
                geography=structured.get("geography"),
                customer_id=cliente.id,
                request_id=req.id,
            )
            researched.append({"request": req, "structured": structured, "findings": findings})
            research_cost += findings.cost

        research_latency_ms = int((time.monotonic() - research_start) * 1000)
        job.stages = [*job.stages, {"stage": "research", "latency_ms": research_latency_ms, "cost": research_cost}]
        await emitir(db, "stage_completed", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), stage="research", latency_ms=research_latency_ms, cost=research_cost)

        await _advance_status_unless_late(db, job, JobStatus.writing)

        # Writing: per-listener, no web access, findings as input. This stage
        # used to be a bare status flip with no work behind it; the split gives
        # it the work the PRD always described.
        writing_start = time.monotonic()
        await emitir(db, "stage_started", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), stage="writing")

        blocks: list[dict] = []
        writing_cost = 0.0
        for item in researched:
            # An empty research day needs no writing call — skip rather than
            # pay a model to tell us it has nothing to say.
            if item["findings"].no_news:
                continue
            req, structured = item["request"], item["structured"]
            # Continuity: what this listener already heard on THIS request.
            # Read before the episode row for today exists, so there is
            # nothing of today's to exclude yet. Only published episodes
            # count — see told_log's module docstring for why that is a
            # correctness property and not a detail.
            previously_told = await told_log.recent_for_request(
                db, customer_id=cliente.id, request_id=req.id,
            )
            block_result = await ai_platform.write_block(
                db,
                findings=item["findings"],
                raw_text=req.raw_text,
                topic=structured.get("topic", req.raw_text[:60]),
                depth=structured.get("depth", "standard"),
                style=style,
                language=language,
                customer_id=cliente.id,
                request_id=req.id,
                previously_told=previously_told,
            )
            blocks.append({"request": req, "result": block_result})
            writing_cost += block_result.cost

        writing_latency_ms = int((time.monotonic() - writing_start) * 1000)
        job.stages = [*job.stages, {"stage": "writing", "latency_ms": writing_latency_ms, "cost": writing_cost}]
        await emitir(db, "stage_completed", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), stage="writing", latency_ms=writing_latency_ms, cost=writing_cost)

        answerable = [b for b in blocks if not b["result"].no_news]

        if not answerable:
            job.status = JobStatus.empty
            await emitir(db, "empty_day", customer_id=cliente.id, source="episode_generator", job_id=str(job.id))
            await db.commit()
            await db.refresh(job)
            return job

        assemble_start = time.monotonic()
        await emitir(db, "stage_started", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), stage="assemble")

        trim_factor = 1.0
        if max_length_minutes is not None:
            total_seconds = sum(_seconds_for_script(b["result"].script) for b in answerable) + _INTRO_OUTRO_SECONDS
            max_seconds = max_length_minutes * 60
            if total_seconds > max_seconds:
                trim_factor = max(0.2, (max_seconds - _INTRO_OUTRO_SECONDS) / (total_seconds - _INTRO_OUTRO_SECONDS))

        is_shared = path == EpisodePath.shared
        episode = Episode(
            customer_id=None if is_shared else cliente.id,  # null = shared inventory (see Episode's own comment)
            shared=is_shared,
            fecha=today,
            path=path,
            language=language,
            style=style,
            voice_id=voice_id,
            audio_url=None,  # set below, only if synthesis actually succeeds
            had_more_any=trim_factor < 1.0,
            # NOT published yet. This used to be datetime.utcnow() here, which
            # marked the episode published before anyone knew whether it had
            # audio — so a TTS failure still produced a "published", silent
            # episode. published_at is now stamped in the voicing stage below,
            # on success or on the explicit no-TTS-configured path, and stays
            # NULL when synthesis fails. Every customer-facing query filters on
            # published_at IS NOT NULL; see this stage's comment for why that
            # filter is required rather than cosmetic.
            published_at=None,
            cost={},
        )
        db.add(episode)
        await db.flush()

        cursor_s = _INTRO_OUTRO_SECONDS // 2
        topics = []
        block_rows: list[Block] = []
        # With TTS on, every block is a capsule awaiting its own audio; with
        # TTS off the status stays NULL (legacy script-only episode).
        capsule_status = capsules.PENDING if ai_platform.elevenlabs_configured() else None
        for seq, b in enumerate(answerable):
            req, result = b["request"], b["result"]
            script = result.script
            had_more = trim_factor < 1.0
            if had_more:
                words = script.split()
                script = " ".join(words[: max(5, int(len(words) * trim_factor))])

            duration = _seconds_for_script(script)
            block = Block(
                id=uuid.uuid4(),
                episode_id=episode.id,
                request_id=req.id,
                request_version_id=req.current_version_id,
                start_s=int(cursor_s),
                end_s=int(cursor_s + duration),
                summary=result.summary,
                script=script,
                sources=result.sources,
                had_more=had_more,
                no_news=False,
                sequence=seq,
                audio_status=capsule_status,
                voice_attempts=0,
            )
            db.add(block)
            block_rows.append(block)
            cursor_s += duration
            topics.append((req.structured or {}).get("topic") or req.raw_text[:30])

        if is_shared and shared_tag:
            # Home reads this back via Episode.shared + InventoryItem.tags — see
            # app/api/routes/home.py's _derive_shared_inventory. seed_request_text
            # is the actual synthetic request's raw_text, not the topic snippet
            # above, so a future ops view can see exactly what was asked for.
            db.add(InventoryItem(
                episode_id=episode.id,
                tags=[shared_tag],
                seed_request_text=answerable[0]["request"].raw_text[:1000],
                reason_template="Because you follow {tag}",
            ))

        episode.duration_s = int(cursor_s + _INTRO_OUTRO_SECONDS // 2)
        episode.headline = "Today: " + ", ".join(topics[:3]) if language != "es" else "Hoy: " + ", ".join(topics[:3])

        # Requests are marked answered AFTER voicing, per delivered capsule —
        # see _mark_answered (doc 4.1: not at assemble, before audio exists).

        assemble_latency_ms = int((time.monotonic() - assemble_start) * 1000)
        # No AICall is made during assembly (pure in-process trimming/DB writes) — cost
        # is 0.0 here, kept explicit rather than omitted so every stage entry has the
        # same shape (GenerationJob.stages' own docstring: "{name, started, completed,
        # cost, latency}") and the funnel's per-stage-type cost aggregation below can
        # sum a `cost` key that's always present.
        job.stages = [*job.stages, {"stage": "assemble", "latency_ms": assemble_latency_ms, "cost": 0.0}]
        await emitir(db, "stage_completed", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), stage="assemble", latency_ms=assemble_latency_ms, cost=0.0)

        voicing_start = time.monotonic()
        await emitir(db, "stage_started", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), stage="voicing")

        # text/sources done; audio pending unless synthesis below succeeds — unless the
        # watchdog already relabelled this job `late` concurrently, see the helper's docstring
        await _advance_status_unless_late(db, job, JobStatus.voicing)
        voicing_skipped = not ai_platform.elevenlabs_configured()
        voicing_cost = 0.0
        voicing_failed = False
        if not voicing_skipped:
            try:
                # A plain list-comprehension over synthesize() would lose whatever cost
                # was already spent on earlier blocks if a later one raises mid-loop —
                # accumulating in a for loop keeps voicing_cost accurate to the calls
                # that actually happened (and got AICall rows written) even on failure.
                voicing_cost = await _synthesize_episode(
                    db, cliente=cliente, episode=episode, block_rows=block_rows, voice_id=voice_id,
                )
                job.status = JobStatus.ready
            except Exception as exc:
                # A TTS failure is a FAILED job, not a published silent episode.
                #
                # This used to swallow the exception with the note "the text
                # episode is still good and published; audio_url just stays null
                # this time." That was wrong in three separate ways, and the
                # three compounded into the founder-visible "no audio at all":
                #
                #   1. `job.status = JobStatus.ready` is set inside the `try`,
                #      after synthesis. Swallowing the error left the status on
                #      `voicing` — a NON-TERMINAL status, forever. Nothing ever
                #      marked the job finished or failed, so no retry, no error
                #      surface, no alert.
                #   2. The episode was published anyway, with audio_url NULL,
                #      and `episode_published` was emitted for it.
                #   3. The clients then misreport it permanently: search.py
                #      computes `state = "ready" if ep.audio_url else "voicing"`,
                #      so a silent episode reads as "still generating" for the
                #      rest of time. The customer sees a spinner that can never
                #      resolve.
                #
                # What we do instead: mark the job failed (terminal, retryable,
                # visible), and leave the episode unpublished so no customer
                # query returns it.
                #
                # We deliberately KEEP the episode and block rows rather than
                # rolling them back. Research and writing are already paid for —
                # by far the larger share of the cost of a run — so discarding
                # the scripts would burn that money and force a full re-research
                # to recover from what is usually a transient voice-provider
                # problem (quota, 5xx, timeout). An unpublished episode with
                # finished scripts is exactly the right state to re-voice from.
                voicing_cost = getattr(exc, "voicing_cost", voicing_cost)
                job.stages = [*job.stages, _failure_stage(exc, stage="voicing", cost=voicing_cost)]
                job.status = JobStatus.failed
                voicing_failed = True

        if voicing_skipped:
            # No TTS configured at all (local dev, tests, a deployment without an
            # ElevenLabs key). This is an explicit, documented mode — see the
            # module docstring's pre-TTS note — not a failure, so it keeps the
            # pre-existing behaviour: publish the script-only episode. Only a
            # real synthesis *error* is treated as a failed job above.
            episode.published_at = datetime.now(timezone.utc)
            await _mark_answered(db, cliente, block_rows)

        voicing_latency_ms = int((time.monotonic() - voicing_start) * 1000)
        job.stages = [*job.stages, {
            "stage": "voicing", "latency_ms": voicing_latency_ms, "skipped": voicing_skipped, "cost": voicing_cost,
            # Additive: per-capsule outcome, e.g. {"voiced": 2, "failed": 1} (absent when TTS is off).
            **({"capsules": {s: _cnt for s in (capsules.VOICED, capsules.FAILED, capsules.BLOCKED, capsules.PENDING)
                             if (_cnt := sum(1 for b in block_rows if b.audio_status == s))}}
               if not voicing_skipped else {}),
        }]
        await emitir(db, "stage_completed", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), stage="voicing", latency_ms=voicing_latency_ms,
                     skipped=voicing_skipped, cost=voicing_cost)

        if voicing_failed:
            # Nothing was published, so don't claim it was. Emitting
            # `episode_published` here was what made the funnel and the
            # dashboards count silent episodes as successful deliveries, which
            # is why "no audio at all" never showed up as a metric.
            await emitir(db, "job_failed", customer_id=cliente.id, source="episode_generator",
                         job_id=str(job.id), stage="voicing", episode_id=str(episode.id))
        else:
            await emitir(db, "episode_published", customer_id=cliente.id, source="episode_generator",
                         job_id=str(job.id), episode_id=str(episode.id), had_more_any=episode.had_more_any)
        await db.commit()
        await db.refresh(job)
        return job

    except Exception as exc:
        await db.rollback()  # discard any partial episode/block writes — never publish partial results
        job.status = JobStatus.failed
        job.stages = [_failure_stage(exc)]
        await db.commit()
        await db.refresh(job)
        if isinstance(exc, ai_platform.BudgetExceededError):
            # The guard's own event was just rolled back with the rest of the
            # transaction; record the refusal once, here, where it persists.
            await ai_platform.emit_budget_exceeded(
                db, scope=exc.scope, spent=exc.spent, limit=exc.limit,
                customer_id=job.customer_id, purpose=exc.purpose)
        # No free-text error content in the Event payload (PII tenet) — the exception
        # message stays only in job.stages, which is internal-only, not the catalogue.
        # customer_id comes from job (just refreshed), not the `cliente` argument —
        # rollback() expires every object tied to this session, and `cliente` wasn't
        # reloaded, so reading cliente.id here would trigger a lazy load outside the
        # async greenlet context and crash with MissingGreenlet.
        await emitir(db, "job_failed", customer_id=job.customer_id, source="episode_generator", job_id=str(job.id))
        await db.commit()
        return job


# ── Shared inventory ─────────────────────────────────────────────────────────
# See module docstring's "Built: shared inventory" section for the design.

async def _get_or_create_shared_customer(db: AsyncSession, tag: str) -> Cliente:
    """One persistent system Cliente per interest tag, created on first use and
    reused on every later refresh. Never logs in (no hashed_password) and is
    excluded from real customer-facing lists by construction — nothing lists
    Cliente rows generically anywhere in this codebase — and from cost-per-
    customer views by its email pattern (see instrumentation.py)."""
    result = await db.execute(select(Cliente).where(Cliente.email == shared_inventory_email(tag)))
    cliente = result.scalar_one_or_none()
    if cliente is not None:
        return cliente

    cliente = Cliente(
        email=shared_inventory_email(tag),
        auth_provider=AuthProvider.email,
        hashed_password=None,
        nombre=f"Shared inventory — {tag}",
        idioma="es",
        onboarding_complete=True,
    )
    db.add(cliente)
    await db.flush()
    return cliente


async def _get_or_create_shared_request(db: AsyncSession, cliente: Cliente, seed_request_text: str) -> Request:
    """Standing (not one_off) so run_generation never marks it fulfilled/inactive —
    each day's refresh needs to find the same active request again, per the module
    docstring's idempotency note. Text is refreshed in place if the seed file
    changed, so editing shared_inventory_seeds.json and re-running the trigger
    picks up the new wording without leaving a stale duplicate request behind."""
    result = await db.execute(
        select(Request).where(Request.customer_id == cliente.id, Request.status == RequestStatus.active)
    )
    existing = result.scalar_one_or_none()
    if existing is not None:
        if existing.raw_text != seed_request_text:
            existing.raw_text = seed_request_text
        return existing

    req = Request(
        customer_id=cliente.id,
        kind=RequestKind.standing,
        raw_text=seed_request_text,
        structured={},
        created_from=CreatedFrom.suggestion,
        status=RequestStatus.active,
    )
    db.add(req)
    await db.flush()
    return req


async def generate_shared_episode(
    db: AsyncSession,
    tag: str,
    seed_request_text: str,
    fecha: date | None = None,
) -> GenerationJob:
    """
    Runs the shared pipeline for one interest tag: gets or creates that tag's
    synthetic Cliente/Request, then calls run_generation exactly as any other
    caller would, with path=EpisodePath.shared. Called once per tag in
    app/data/shared_inventory_seeds.json by POST /internal/generate-shared-
    inventory (app/api/routes/internal.py) — see that endpoint for the loop.

    Idempotent per (tag, day) via run_generation's existing (customer, fecha,
    path) uniqueness — calling this twice for the same tag on the same day
    returns the first call's job unchanged rather than generating twice.
    """
    cliente = await _get_or_create_shared_customer(db, tag)
    await _get_or_create_shared_request(db, cliente, seed_request_text)
    await db.commit()
    return await run_generation(db, cliente, path=EpisodePath.shared, fecha=fecha, shared_tag=tag)
