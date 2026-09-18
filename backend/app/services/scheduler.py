"""
Scheduler — in-process trigger for the Episode Generator PRD's scheduled
path ("Per-customer cron in their tz at T-60"), added as pure additive
infrastructure. Per the PRD, "They share the pipeline and differ only in
trigger and latency budget" — nothing in episode_generator.py's pipeline
changed to add this, only the `path`/`fecha` parameters on run_generation
so a caller can say which path/day it's triggering for.

Built: an asyncio background task, started from app.main's lifespan, that
wakes up once a minute, finds every onboarded customer with at least one
active Request whose Profile.delivery_time is currently ~60 minutes away
in their own Profile.delivery_timezone, and — if they don't already have a
scheduled GenerationJob for that delivery day — calls
episode_generator.run_generation(..., path=EpisodePath.scheduled) for them.

Why asyncio instead of APScheduler: this only needs "wake up once a minute
and run an async DB query," which a bare `while True: ... ; await
asyncio.sleep(60)` does without a new dependency, a job store, or a second
way of scheduling things to reason about. APScheduler's per-job cron
scheduling would be a better fit if the trigger check itself were
expensive or needed persistence across restarts (it doesn't — this
recomputes from Profile/Request state every tick), so it isn't worth
the added dependency for a single-instance deployment.

Deliberately simplified:
- Closest-minute granularity, not precise-to-the-second. The tick interval
  is 60s and a customer fires when "now" (in their own tz) floors to the
  same minute as their T-60 instant; a slow tick (the previous tick still
  running, a GC pause) can push an actual trigger a few seconds either
  side of the target minute. Fine given the PRD's own +30 min slack; not
  fine if this ever needs second-level precision.
- No distributed lock. This assumes it is the only process ticking, which
  is true today (single Railway replica). If this service is ever scaled
  to 2+ replicas, every replica would tick independently and try to
  trigger the same customers at the same minute — the
  (customer_id, fecha, path=scheduled) GenerationJob uniqueness check
  below reduces this to a race rather than a guarantee (whichever replica
  commits its job row first wins; a second replica reading before that
  commit lands would still double-fire). Add a real lock (e.g. Postgres
  `pg_try_advisory_lock`) or move to a real job queue before scaling
  replicas.
- Per-customer errors (a bad timezone string, a DB hiccup, the pipeline
  itself raising) are caught and logged inside the tick per customer; they
  never stop the ticker or block the other customers due in that same
  tick.

Built: the late-job watchdog. Every tick, after triggering this minute's
due customers, also calls episode_generator.check_late_jobs(db) — it scans
every non-terminal GenerationJob (any path, any customer) whose eta plus
the PRD's +30 min hard limit has passed and relabels it JobStatus.late
(see that function's docstring for exactly what "relabel" means and why
this never tries to cancel the in-flight run). Reusing this tick rather
than adding a second ticker: the check applies uniformly to both paths
now that both set a real `eta` (see episode_generator._compute_eta), it's
a cheap query, and there's no new process/dependency to add — the same
tradeoffs (closest-minute granularity, no distributed lock) already
documented above for triggering apply here too, and are fine given the
PRD's own 30 min slack.

Deferred:
- Explicit reschedule-on-delivery_time-change (PRD: "delivery_time changes
  reschedule via Notifications + Settings"): not needed as a separate step
  here, because this ticker reads Profile.delivery_time fresh every
  minute instead of pre-computing a schedule — an edited delivery_time
  takes effect on the very next tick automatically. Surfacing that change
  to the customer via Notifications/Settings is still deferred (neither
  module exists).
- On-demand jobs getting "higher queue priority" (PRD): doesn't apply yet
  since there is no queue — on-demand and scheduled runs both execute
  inline, sequentially, in this one process.
"""
import asyncio
import logging
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from sqlalchemy import select

from app.db.session import AsyncSessionLocal
from app.models.cliente import Cliente
from app.models.episode import EpisodePath
from app.models.generation_job import GenerationJob
from app.models.profile import Profile
from app.models.request import Request, RequestStatus
from app.services.episode_generator import check_late_jobs, run_generation

logger = logging.getLogger(__name__)

_TICK_SECONDS = 60
_LEAD_MINUTES = 60


def _floor_to_minute(dt: datetime) -> datetime:
    return dt.replace(second=0, microsecond=0)


async def _due_candidates(db) -> list[tuple[Cliente, date]]:
    """
    Onboarded customers with >=1 active Request whose T-60 instant, in
    their own delivery_timezone, falls in the current minute. Each result
    pairs the customer with the delivery date (their own local date) the
    triggered episode is for — which is *not* always "today" server-side:
    a delivery_time before 01:00 local fires its T-60 trigger the previous
    local evening, so the delivery date is one day ahead of the trigger's
    own local date.
    """
    has_active_request = (
        select(Request.id)
        .where(Request.customer_id == Cliente.id, Request.status == RequestStatus.active)
        .exists()
    )
    stmt = (
        select(Cliente, Profile)
        .join(Profile, Profile.customer_id == Cliente.id)
        .where(
            Cliente.onboarding_complete.is_(True),
            Profile.delivery_time.isnot(None),
            has_active_request,
        )
    )
    result = await db.execute(stmt)

    due: list[tuple[Cliente, date]] = []
    for cliente, perfil in result.all():
        try:
            tz = ZoneInfo(perfil.delivery_timezone)
        except ZoneInfoNotFoundError:
            logger.error("scheduler: unknown delivery_timezone %r for customer %s", perfil.delivery_timezone, cliente.id)
            continue

        now_local = _floor_to_minute(datetime.now(tz))
        # Delivery is always "today" or "tomorrow" relative to now's local date —
        # never further out, since the trigger is at most _LEAD_MINUTES before it.
        for delivery_date in (now_local.date(), now_local.date() + timedelta(days=1)):
            trigger_at = datetime.combine(delivery_date, perfil.delivery_time, tzinfo=tz) - timedelta(minutes=_LEAD_MINUTES)
            if _floor_to_minute(trigger_at) == now_local:
                due.append((cliente, delivery_date))
                break
    return due


async def _already_has_scheduled_job(db, customer_id, delivery_date: date) -> bool:
    result = await db.execute(
        select(GenerationJob.id).where(
            GenerationJob.customer_id == customer_id,
            GenerationJob.fecha == delivery_date,
            GenerationJob.path == EpisodePath.scheduled,
        )
    )
    return result.scalar_one_or_none() is not None


async def _tick() -> None:
    async with AsyncSessionLocal() as db:
        for cliente, delivery_date in await _due_candidates(db):
            try:
                if await _already_has_scheduled_job(db, cliente.id, delivery_date):
                    continue
                await run_generation(db, cliente, path=EpisodePath.scheduled, fecha=delivery_date)
            except Exception:
                # One customer's bad data or a transient failure shouldn't stop the
                # rest of this tick, or the next one, from running. Roll back first —
                # an error from the pre-checks above (outside run_generation's own
                # try/except) can leave this shared session's transaction aborted,
                # which would otherwise fail every subsequent customer in this tick too.
                await db.rollback()
                logger.exception("scheduler: failed to trigger scheduled generation for customer %s", cliente.id)

        try:
            await check_late_jobs(db)
        except Exception:
            # Same isolation principle as the per-customer loop above: a problem in the
            # watchdog scan (e.g. a transient DB error) shouldn't stop this tick's
            # triggering from having happened, or block the next tick from running.
            await db.rollback()
            logger.exception("scheduler: check_late_jobs failed")


async def _run_forever() -> None:
    while True:
        try:
            await _tick()
        except Exception:
            logger.exception("scheduler: tick failed")
        await asyncio.sleep(_TICK_SECONDS)


class Scheduler:
    """Owns the background task's lifecycle so app.main's lifespan can start
    it on startup and cancel it cleanly on shutdown."""

    def __init__(self) -> None:
        self._task: asyncio.Task | None = None

    def start(self) -> None:
        if self._task is not None:
            return
        self._task = asyncio.create_task(_run_forever())

    async def stop(self) -> None:
        if self._task is None:
            return
        self._task.cancel()
        try:
            await self._task
        except asyncio.CancelledError:
            pass
        self._task = None


scheduler = Scheduler()
