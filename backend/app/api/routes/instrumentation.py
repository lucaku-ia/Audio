"""
Instrumentation & Cost PRD (Andrés, Draft v1) — the internal, founder/ops-only
dashboard: "the pilot's most important deliverable."

Security posture (read before deploying this): there is no admin/founder role
built anywhere in this codebase yet — Cliente is the only account type, and
every other route gates on `get_current_cliente` (a customer's own JWT).
These routes expose cross-customer cost and business data, so they must
never be reachable with a customer token. Rather than either (a) silently
reusing customer auth (wrong — any signed-up customer could read everyone
else's costs) or (b) shipping with no gate at all, this uses the same "read
a secret from the environment, fail closed if it's missing" shape already
used for ANTHROPIC_API_KEY/ELEVENLABS_API_KEY (see
app/services/ai_platform.py's `elevenlabs_configured()`): a shared-secret
header, `X-Internal-Dashboard-Key`, checked against `Settings.
INTERNAL_DASHBOARD_KEY` by `require_internal_dashboard_key`
(app/api/deps.py). If that setting is unset, every route here 503s instead
of opening up. This is a stopgap, not real internal auth — there's no per-
founder identity, no audit log, no rotation story. Replace with a proper
staff-auth mechanism before more than a couple of trusted people need this.

What's built vs. deferred, against the PRD's dashboard requirements:

- Cost per active customer / cost per episode by component (research /
  writing / TTS / other) -> `/cost-summary`. Fully buildable today:
  `AICall` already logs `purpose`, `cost`, and `context` (which carries
  `customer_id`) for every real model call (Anthropic + ElevenLabs), per
  app/models/instrumentation.py and app/services/ai_platform.py.
- Completeness ("event catalog received") -> `/event-counts`. Simplified
  per the PRD's own escape hatch ("simplify to just reporting counts per
  event name/day ... if a strict expected-vs-received check is
  overengineering for what exists today"): there is no declared catalog of
  *expected* event names/volumes anywhere in the codebase to compare
  against, only the events actually emitted (`grep -rn "emitir(" app/`
  shows: account_created, login_failure, login_success, logout, empty_day,
  episode_published). So this reports raw counts per name per day, not a
  received/expected ratio.
- First-episode on-time rate / generation timeliness -> `/generation-funnel`.
  `GenerationJob` (app/models/generation_job.py) has `creado_en` but no
  `completed_at`/`finished_at` column, so a created-to-ready *latency* is
  not measurable — this endpoint reports the status distribution and the
  creation-time range per status only. Do not fabricate a completion
  timestamp to fake a latency number; add the column (and a
  COLUMNAS_ESPERADAS entry) when the Generator actually needs one.
- Onboarding funnel (steps entered vs completed) -> `/onboarding-funnel`.
  Buildable from `OnboardingState.step` and `.completed_at`
  (app/models/onboarding.py) — one row per customer, so this is a
  straightforward "customers currently at each step" + "completed vs not"
  count, not a full step-transition funnel (no per-step timestamps exist).

Explicitly out of scope / skipped, and why:

- Refinement rate: the PRD gates this on a `refine()` endpoint from a
  parallel workstream. `app/api/routes/requests.py`'s own module docstring
  lists `refine()` and `adopt()` as not implemented ("depend on Player and
  Home, which don't exist yet") and no `/refine` route exists anywhere in
  `app/api/routes/`. Skipped entirely, per the PRD's own instruction to
  skip it if this endpoint hasn't landed.
- Completion by style/voice/length, and listening/block-level attribution:
  both need a Player (playback events, listening seconds) that does not
  exist in this codebase (README's module table lists Player as "Not
  started"). No stub/fake data is provided for either.

Every query here is read-only aggregation — no route in this file writes
anything.
"""
import uuid
from datetime import date, datetime, timedelta

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_internal_dashboard_key
from app.db.session import get_db
from app.models.generation_job import GenerationJob, JobStatus
from app.models.instrumentation import AICall, Event
from app.models.onboarding import OnboardingState, OnboardingStep

router = APIRouter(
    prefix="/internal/instrumentation",
    tags=["Instrumentation (internal)"],
    dependencies=[Depends(require_internal_dashboard_key)],
)


# ── cost-summary ──────────────────────────────────────────────────────────

class CostByPurpose(BaseModel):
    purpose: str
    call_count: int
    total_cost: float


class CostByCustomer(BaseModel):
    customer_id: str | None
    call_count: int
    total_cost: float


class CostByDay(BaseModel):
    day: date
    call_count: int
    total_cost: float


class CostSummaryOut(BaseModel):
    since: date
    total_cost: float
    total_calls: int
    by_purpose: list[CostByPurpose]
    by_customer: list[CostByCustomer]
    by_day: list[CostByDay]


@router.get("/cost-summary", response_model=CostSummaryOut)
async def cost_summary(
    days: int = Query(default=30, ge=1, le=365, description="How many trailing days to include"),
    top_customers: int = Query(default=20, ge=1, le=200, description="Max customers in by_customer"),
    db: AsyncSession = Depends(get_db),
):
    """
    Cost per active customer and cost per component (`purpose`), from
    AICall — the PRD's #1 dashboard requirement. `purpose` values today are
    whatever ai_platform.py actually logs: structure_request,
    research_and_write_block, synthesize (see that module's `_log_call`
    call sites) — no fixed enum exists on the model, so this reports
    whatever purposes are present in the data rather than a hardcoded list.
    """
    since_dt = datetime.utcnow() - timedelta(days=days)
    since_date = since_dt.date()

    total_row = (
        await db.execute(
            select(func.coalesce(func.sum(AICall.cost), 0), func.count(AICall.call_id))
            .where(AICall.creado_en >= since_dt)
        )
    ).one()
    total_cost, total_calls = total_row

    by_purpose_rows = (
        await db.execute(
            select(AICall.purpose, func.count(AICall.call_id), func.coalesce(func.sum(AICall.cost), 0))
            .where(AICall.creado_en >= since_dt)
            .group_by(AICall.purpose)
            .order_by(func.sum(AICall.cost).desc())
        )
    ).all()

    customer_id_expr = AICall.context["customer_id"].as_string()
    by_customer_rows = (
        await db.execute(
            select(customer_id_expr, func.count(AICall.call_id), func.coalesce(func.sum(AICall.cost), 0))
            .where(AICall.creado_en >= since_dt)
            .group_by(customer_id_expr)
            .order_by(func.sum(AICall.cost).desc())
            .limit(top_customers)
        )
    ).all()

    day_expr = func.date(AICall.creado_en)
    by_day_rows = (
        await db.execute(
            select(day_expr, func.count(AICall.call_id), func.coalesce(func.sum(AICall.cost), 0))
            .where(AICall.creado_en >= since_dt)
            .group_by(day_expr)
            .order_by(day_expr)
        )
    ).all()

    return CostSummaryOut(
        since=since_date,
        total_cost=float(total_cost),
        total_calls=total_calls,
        by_purpose=[
            CostByPurpose(purpose=purpose, call_count=count, total_cost=float(cost))
            for purpose, count, cost in by_purpose_rows
        ],
        by_customer=[
            CostByCustomer(customer_id=customer_id, call_count=count, total_cost=float(cost))
            for customer_id, count, cost in by_customer_rows
        ],
        by_day=[
            CostByDay(day=day, call_count=count, total_cost=float(cost))
            for day, count, cost in by_day_rows
        ],
    )


# ── event-counts ──────────────────────────────────────────────────────────

class EventCount(BaseModel):
    name: str
    day: date
    count: int


class EventCountsOut(BaseModel):
    start_date: date
    end_date: date
    counts: list[EventCount]


@router.get("/event-counts", response_model=EventCountsOut)
async def event_counts(
    start_date: date | None = Query(default=None, description="Defaults to 7 days before end_date"),
    end_date: date | None = Query(default=None, description="Defaults to today (UTC)"),
    db: AsyncSession = Depends(get_db),
):
    """
    Raw counts per event name per day — the simplified "completeness" view.
    Not an expected-vs-received check: there is no declared catalog of
    expected event volumes in this codebase to compare against, only the
    events `app/services/events.emitir()` is actually called with today.
    """
    resolved_end = end_date or datetime.utcnow().date()
    resolved_start = start_date or (resolved_end - timedelta(days=7))

    day_expr = func.date(Event.ts)
    rows = (
        await db.execute(
            select(Event.name, day_expr, func.count(Event.event_id))
            .where(func.date(Event.ts) >= resolved_start, func.date(Event.ts) <= resolved_end)
            .group_by(Event.name, day_expr)
            .order_by(day_expr, Event.name)
        )
    ).all()

    return EventCountsOut(
        start_date=resolved_start,
        end_date=resolved_end,
        counts=[EventCount(name=name, day=day, count=count) for name, day, count in rows],
    )


# ── generation-funnel ─────────────────────────────────────────────────────

class GenerationStatusCount(BaseModel):
    status: str
    count: int
    earliest_creado_en: datetime | None
    latest_creado_en: datetime | None


class GenerationFunnelOut(BaseModel):
    since: date
    total_jobs: int
    by_status: list[GenerationStatusCount]
    latency_note: str


@router.get("/generation-funnel", response_model=GenerationFunnelOut)
async def generation_funnel(
    days: int = Query(default=30, ge=1, le=365),
    db: AsyncSession = Depends(get_db),
):
    """
    Status distribution from GenerationJob. True creation-to-ready latency
    (the PRD's "first-episode on-time rate") is NOT computed here:
    GenerationJob has no completed_at/finished_at column (only `creado_en`),
    so there is nothing to subtract from. This reports the creation-time
    range per status instead of a fabricated latency figure — add a real
    completion timestamp (and a COLUMNAS_ESPERADAS migration entry) before
    this metric can be built.
    """
    since_dt = datetime.utcnow() - timedelta(days=days)

    total = (
        await db.execute(
            select(func.count(GenerationJob.id)).where(GenerationJob.creado_en >= since_dt)
        )
    ).scalar_one()

    rows = (
        await db.execute(
            select(
                GenerationJob.status,
                func.count(GenerationJob.id),
                func.min(GenerationJob.creado_en),
                func.max(GenerationJob.creado_en),
            )
            .where(GenerationJob.creado_en >= since_dt)
            .group_by(GenerationJob.status)
            .order_by(func.count(GenerationJob.id).desc())
        )
    ).all()

    return GenerationFunnelOut(
        since=since_dt.date(),
        total_jobs=total,
        by_status=[
            GenerationStatusCount(
                status=status.value if isinstance(status, JobStatus) else status,
                count=count, earliest_creado_en=earliest, latest_creado_en=latest,
            )
            for status, count, earliest, latest in rows
        ],
        latency_note=(
            "GenerationJob has no completed_at/finished_at column, so "
            "creation-to-ready latency cannot be computed — only status "
            "counts and creation-time ranges are reported."
        ),
    )


# ── onboarding-funnel ─────────────────────────────────────────────────────

class OnboardingStepCount(BaseModel):
    step: str
    count: int


class OnboardingFunnelOut(BaseModel):
    total_customers_started: int
    completed: int
    not_completed: int
    by_step: list[OnboardingStepCount]


@router.get("/onboarding-funnel", response_model=OnboardingFunnelOut)
async def onboarding_funnel(db: AsyncSession = Depends(get_db)):
    """
    One row per customer in OnboardingState — `step` is the customer's
    current step (not a per-step event log, so this is a snapshot of where
    everyone who has started onboarding currently sits, not a
    step-by-step drop-off funnel with timestamps; OnboardingState carries
    no per-step timestamps beyond `creado_en`/`completed_at`).
    """
    total = (await db.execute(select(func.count(OnboardingState.customer_id)))).scalar_one()
    completed = (
        await db.execute(
            select(func.count(OnboardingState.customer_id)).where(OnboardingState.completed_at.is_not(None))
        )
    ).scalar_one()

    step_rows = (
        await db.execute(
            select(OnboardingState.step, func.count(OnboardingState.customer_id))
            .group_by(OnboardingState.step)
            .order_by(func.count(OnboardingState.customer_id).desc())
        )
    ).all()

    return OnboardingFunnelOut(
        total_customers_started=total,
        completed=completed,
        not_completed=total - completed,
        by_step=[
            OnboardingStepCount(step=step.value if isinstance(step, OnboardingStep) else step, count=count)
            for step, count in step_rows
        ],
    )
