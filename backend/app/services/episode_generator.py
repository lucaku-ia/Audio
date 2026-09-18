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
for what's simplified (closest-minute granularity, no distributed lock) and
deferred (the PRD's "+30 min hard limit, stated plainly if missed"). This
confirms the PRD's premise that the two paths "share the pipeline and
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
- Shared inventory (day-zero/empty-day samples for common interest
  clusters): needs team-curated seed requests per cluster, which don't
  exist. Every job here is per-customer, tagged shared=False.
- Source catalogue (PRD: "config file: source, API, license, language,
  topics. Only licensed or API sources. No scraping."): substituted with
  Claude's server-side web_search tool for this MVP, which is API-based
  and not scraping, but isn't the curated/licensed catalogue the PRD
  describes. Revisit when the AI Platform builds real source management.

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
"""
import uuid
from datetime import date, datetime

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.routes.requests import active_for_generation
from app.core.config import settings
from app.models.cliente import Cliente
from app.models.episode import Block, Episode, EpisodePath
from app.models.generation_job import GenerationJob, JobStatus
from app.models.profile import Profile
from app.models.request import Request, RequestStatus, RequestVersion, VersionStatus
from app.services import ai_platform
from app.services.events import emitir

_WORDS_PER_MINUTE = 150  # rough narration rate, used only to estimate duration/offsets pre-TTS
_INTRO_OUTRO_SECONDS = 15


def _seconds_for_script(script: str) -> float:
    word_count = len(script.split())
    return (word_count / _WORDS_PER_MINUTE) * 60


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
) -> GenerationJob:
    """
    Runs the full pipeline synchronously for one customer and returns the
    GenerationJob row describing the outcome. `path` and `fecha` let a
    caller say which PRD path and which calendar day this run is for — the
    on-demand route (app/api/routes/generation.py) leaves both at their
    defaults (today, on_demand); app.services.scheduler passes
    path=EpisodePath.scheduled and the customer's local delivery date, since
    that can differ from the server's own date near midnight.

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

    job = GenerationJob(
        customer_id=cliente.id,
        fecha=today,
        path=path,
        status=JobStatus.researching,
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

    try:
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

        job.status = JobStatus.writing
        answerable = [b for b in blocks if not b["result"].no_news]

        if not answerable:
            job.status = JobStatus.empty
            await emitir(db, "empty_day", customer_id=cliente.id, source="episode_generator")
            await db.commit()
            await db.refresh(job)
            return job

        trim_factor = 1.0
        if max_length_minutes is not None:
            total_seconds = sum(_seconds_for_script(b["result"].script) for b in answerable) + _INTRO_OUTRO_SECONDS
            max_seconds = max_length_minutes * 60
            if total_seconds > max_seconds:
                trim_factor = max(0.2, (max_seconds - _INTRO_OUTRO_SECONDS) / (total_seconds - _INTRO_OUTRO_SECONDS))

        episode = Episode(
            customer_id=cliente.id,
            shared=False,
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

        episode.duration_s = int(cursor_s + _INTRO_OUTRO_SECONDS // 2)
        episode.headline = "Today: " + ", ".join(topics[:3]) if language != "es" else "Hoy: " + ", ".join(topics[:3])

        for req in [b["request"] for b in answerable]:
            req.last_answered_at = datetime.utcnow()
            if req.kind.value == "one_off":
                req.status = RequestStatus.fulfilled
                req.fulfilled_episode_id = episode.id

        job.status = JobStatus.voicing  # text/sources done; audio pending unless synthesis below succeeds
        if ai_platform.elevenlabs_configured():
            try:
                audio_bytes = b"".join([
                    await ai_platform.synthesize(
                        db, block.script, voice_id, customer_id=cliente.id,
                        request_id=block.request_id, episode_id=episode.id,
                    )
                    for block in block_rows
                ])
                settings.MEDIA_DIR.mkdir(parents=True, exist_ok=True)
                (settings.MEDIA_DIR / f"{episode.id}.mp3").write_bytes(audio_bytes)
                episode.audio_url = f"{settings.PUBLIC_BASE_URL}/media/{episode.id}.mp3"
                job.status = JobStatus.ready
            except Exception as exc:
                # Don't fail the whole job over a TTS problem — the text episode is
                # still good and published; audio_url just stays null this time.
                job.stages = [{"stage": "voicing", "error": str(exc)}]

        await emitir(db, "episode_published", customer_id=cliente.id, source="episode_generator",
                     episode_id=str(episode.id), had_more_any=episode.had_more_any)
        await db.commit()
        await db.refresh(job)
        return job

    except Exception as exc:
        await db.rollback()  # discard any partial episode/block writes — never publish partial results
        job.status = JobStatus.failed
        job.stages = [{"error": str(exc)}]
        await db.commit()
        await db.refresh(job)
        return job
