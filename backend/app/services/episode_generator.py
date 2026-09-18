"""
Episode Generator PRD (Juan, Draft v1, proposed by Andrés for review).

Scope note — what's built vs. deferred:

Built: the on-demand path's pipeline — load -> research+write (per active
request, via app.services.ai_platform.research_and_write_block) -> assemble
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
(whatever its status, including "empty" or "failed") instead of creating a
duplicate. Enforced both in-app (a SELECT before the INSERT) and at the DB
level (a UniqueConstraint on generation_jobs, backfilled onto existing
tables in app/db/migraciones.py). Two concurrent calls for the same
(customer, fecha, path) can both pass the SELECT and race on INSERT; the
loser's IntegrityError is caught and it returns the winner's job instead of
a 500 — see run_generation's docstring for what this does and doesn't
guarantee.

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
  the index doesn't exist yet. research_and_write_block only judges "is
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
entries this used to be. research_and_write_block runs once per active
request inside the research stage's loop, so research_cost accumulates
across every call in that loop, not just the last one. Threaded up without
touching research_and_write_block's/synthesize's public *business*
parameters: ai_platform._log_call now returns the cost of the AICall row it
just wrote, and both direct callers pass it back to their own caller
(BlockResult gained a `cost` field; synthesize now returns `(bytes, cost)`
instead of bare bytes) — deliberately not a time-window `SELECT SUM(cost)
FROM ai_calls WHERE ...` scoped by customer_id/purpose/timestamp, which
would be a lossy heuristic if a customer has two jobs running concurrently
or two stages complete in the same wall-clock second.
"""
import time
import uuid
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.routes.requests import active_for_generation
from app.core.config import settings
from app.models.cliente import AuthProvider, Cliente
from app.models.episode import Block, Episode, EpisodePath
from app.models.generation_job import GenerationJob, InventoryItem, JobStatus
from app.models.profile import Profile
from app.models.request import CreatedFrom, Request, RequestKind, RequestStatus, RequestVersion, VersionStatus
from app.services import ai_platform
from app.services.events import emitir

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
    ready, empty, failed, etc.) instead of erroring or re-running the
    pipeline. Enforced here via a SELECT before the INSERT, backed by a
    DB-level UniqueConstraint (see GenerationJob.__table_args__) as the
    source of truth.

    Two concurrent calls for the same (customer, fecha, path) can both pass
    the SELECT before either commits and race to INSERT; rather than let
    the loser surface the resulting IntegrityError as a 500, the insert
    below is wrapped to catch exactly that race and return the winner's job
    instead — still no row lock (e.g. SELECT ... FOR UPDATE), so this is a
    catch-and-recover rather than a true mutex, but it means a concurrent
    on-demand call and scheduler tick for the same customer both get a
    clean job back rather than one of them erroring.

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
        return existing_job

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
            return existing_job
        raise  # constraint violation for a reason other than the expected race
    await db.refresh(job)  # below can mark *this* row failed instead of losing it to rollback
    await emitir(db, "job_created", customer_id=cliente.id, source="episode_generator",
                 job_id=str(job.id), path=job.path.value)
    await db.commit()

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

        blocks: list[dict] = []
        research_cost = 0.0
        for req_out in all_requests:
            req = req_by_id.get(req_out.id)
            if not req:
                continue
            await _promote_pending_version(db, req)  # "applies from next generation" — this run is that next one
            structured = req.structured or {}
            block_result = await ai_platform.research_and_write_block(
                db,
                raw_text=req.raw_text,
                topic=structured.get("topic", req.raw_text[:60]),
                scope=structured.get("scope", ""),
                geography=structured.get("geography"),
                depth=structured.get("depth", "standard"),
                style=style,
                language=language,
                customer_id=cliente.id,
                request_id=req.id,
            )
            blocks.append({"request": req, "result": block_result})
            research_cost += block_result.cost

        research_latency_ms = int((time.monotonic() - research_start) * 1000)
        job.stages = [*job.stages, {"stage": "research", "latency_ms": research_latency_ms, "cost": research_cost}]
        await emitir(db, "stage_completed", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), stage="research", latency_ms=research_latency_ms, cost=research_cost)

        await _advance_status_unless_late(db, job, JobStatus.writing)
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
            audio_url=None,  # TTS not wired yet — see module docstring
            had_more_any=trim_factor < 1.0,
            published_at=datetime.utcnow(),
            cost={},
        )
        db.add(episode)
        await db.flush()

        cursor_s = _INTRO_OUTRO_SECONDS // 2
        topics = []
        block_rows: list[Block] = []
        for b in answerable:
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

        for req in [b["request"] for b in answerable]:
            req.last_answered_at = datetime.utcnow()
            if req.kind.value == "one_off":
                req.status = RequestStatus.fulfilled
                req.fulfilled_episode_id = episode.id
            # The real on-demand path marks requests answered here directly rather than
            # through POST /requests/mark_answered (that endpoint is still the contract
            # path for when a caller other than this pipeline needs it) — so this is the
            # only place that can emit request_answered for what actually happens today.
            await emitir(db, "request_answered", customer_id=cliente.id, source="episode_generator",
                         request_id=str(req.id), episode_id=str(episode.id), had_more=trim_factor < 1.0)

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
        if not voicing_skipped:
            try:
                # A plain list-comprehension over synthesize() would lose whatever cost
                # was already spent on earlier blocks if a later one raises mid-loop —
                # accumulating in a for loop keeps voicing_cost accurate to the calls
                # that actually happened (and got AICall rows written) even on failure.
                audio_parts: list[bytes] = []
                for block in block_rows:
                    audio_bytes_part, call_cost, word_timestamps = await ai_platform.synthesize(
                        db, block.script, voice_id, customer_id=cliente.id,
                        request_id=block.request_id, episode_id=episode.id,
                    )
                    audio_parts.append(audio_bytes_part)
                    voicing_cost += call_cost
                    # Timestamps are relative to this block's OWN synthesized audio
                    # (0.0 = the first word of block.script), not to the assembled
                    # episode timeline — the Player must add block.start_s itself
                    # when mapping episode playhead position -> word to highlight,
                    # the same way it already uses block.start_s/end_s today.
                    block.word_timestamps = word_timestamps
                audio_bytes = b"".join(audio_parts)
                settings.MEDIA_DIR.mkdir(parents=True, exist_ok=True)
                (settings.MEDIA_DIR / f"{episode.id}.mp3").write_bytes(audio_bytes)
                episode.audio_url = f"{settings.PUBLIC_BASE_URL}/media/{episode.id}.mp3"
                job.status = JobStatus.ready
            except Exception as exc:
                # Don't fail the whole job over a TTS problem — the text episode is
                # still good and published; audio_url just stays null this time.
                job.stages = [*job.stages, {"stage": "voicing", "error": str(exc), "cost": voicing_cost}]

        voicing_latency_ms = int((time.monotonic() - voicing_start) * 1000)
        job.stages = [*job.stages, {
            "stage": "voicing", "latency_ms": voicing_latency_ms, "skipped": voicing_skipped, "cost": voicing_cost,
        }]
        await emitir(db, "stage_completed", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), stage="voicing", latency_ms=voicing_latency_ms,
                     skipped=voicing_skipped, cost=voicing_cost)

        await emitir(db, "episode_published", customer_id=cliente.id, source="episode_generator",
                     job_id=str(job.id), episode_id=str(episode.id), had_more_any=episode.had_more_any)
        await db.commit()
        await db.refresh(job)
        return job

    except Exception as exc:
        await db.rollback()  # discard any partial episode/block writes — never publish partial results
        job.status = JobStatus.failed
        job.stages = [{"error": str(exc)}]
        await db.commit()
        await db.refresh(job)
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
