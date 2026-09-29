"""
Onboarding PRD (Andrés, Draft v4).

Scope note: everything that needs the AI Platform (structure_request,
preview_answer, per-request LLM structuring) is out of scope here — that
epic doesn't exist yet. See app/models/onboarding.py for the full
breakdown of what's deferred and why.

What this module does cover, all buildable today:
- Resumable server-side progress (OnboardingState.step), per PRD §5.
- The interest picker and curated seed-list suggestions (PRD explicitly
  allows a static config for this, not AI, during the pilot).
- Wiring the existing Request Management and Profile endpoints as the
  actual read/write path for requests, delivery time, voice and style —
  Onboarding does not redefine those objects, per PRD §5 ("owned jointly
  with Request Management... Onboarding writes it, never defines it alone").
- The T-60 first-episode scheduling message (PRD §5), computed from
  Profile.delivery_time. The Episode Generator now exists (see
  app/services/episode_generator.py), so confirm()'s on_demand branch (T
  less than 60 minutes away) also kicks off that first GenerationJob —
  see confirm()'s own docstring for why that's fired as an unawaited
  background task rather than inline. The scheduled branch (T >= 60
  minutes away) still creates no job here: app.services.scheduler's own
  ticker creates it at T-60, exactly as it does for every other day.
- A day-zero shared-inventory sample (GET /state and POST /confirm's
  `day_zero_sample`), per the PRD's "the first session has to end with
  audio playing, even if that audio is not yet fully theirs" — reuses
  Home's own _derive_shared_inventory query (app/api/routes/home.py)
  rather than a second, divergent matching implementation. Returns null
  until at least one shared-inventory Episode exists for one of the
  customer's selected interests — see _day_zero_sample's docstring for
  what that does and doesn't guarantee.
- Notification consent, tour completion, and the final onboarding_complete
  flag that Login already routes on.
"""
import asyncio
import json
import logging
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_cliente
from app.api.routes.home import SharedInventoryOut, _derive_shared_inventory
from app.db.session import AsyncSessionLocal, get_db
from app.models.cliente import Cliente
from app.models.episode import EpisodePath
from app.models.onboarding import OnboardingState, OnboardingStep
from app.models.profile import Profile
from app.models.request import Request, RequestStatus
from app.services.episode_generator import run_generation
from app.services.events import emitir

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/onboarding", tags=["Onboarding"])

_SEEDS_PATH = Path(__file__).resolve().parents[2] / "data" / "onboarding_seeds.json"
_SEEDS = json.loads(_SEEDS_PATH.read_text(encoding="utf-8"))
_SEEDS_BY_ID = {i["id"]: i for i in _SEEDS["interests"]}


# ── Schemas ──────────────────────────────────────────────────────────────────

class StateOut(BaseModel):
    step: str
    selected_interests: list[str]
    active_request_count: int
    notifications_enabled: bool | None
    tour_completed: bool
    consent_accepted: bool
    onboarding_complete: bool
    # Defect 3 fix — day-zero content, per the PRD's "the first session has to
    # end with audio playing, even if that audio is not yet fully theirs."
    # Null whenever there's nothing honest to show yet: no interests picked,
    # or (today, in practice, for every customer — see PR notes) no
    # shared-inventory Episode has ever been generated for any of them. See
    # _day_zero_sample's docstring for exactly what this can and can't do.
    day_zero_sample: SharedInventoryOut | None = None


class InterestOption(BaseModel):
    id: str
    label: str


class InterestsBody(BaseModel):
    interests: list[str] = Field(min_length=1)


class SetStepBody(BaseModel):
    step: OnboardingStep


class NotificationsBody(BaseModel):
    enabled: bool


class ConfirmationOut(BaseModel):
    message: str
    path: str  # "scheduled" | "on_demand"
    first_episode_eta: datetime
    # Defect 3 fix — see StateOut.day_zero_sample's docstring; same field,
    # same helper, reused here so the confirmation screen (the actual "first
    # session" moment the PRD's "has to end with audio playing" tenet is
    # about) can offer something to play immediately, not just a promise of
    # an episode up to an hour away.
    day_zero_sample: SharedInventoryOut | None = None


async def _day_zero_sample(db: AsyncSession, cliente: Cliente) -> SharedInventoryOut | None:
    """
    Defect 3 fix. The PRD is explicit: "The first session has to end with
    audio playing, even if that audio is not yet fully theirs." The
    mechanism for that already exists — Home's own shared-inventory matching
    (app/api/routes/home.py's _derive_shared_inventory: Episode.shared=True
    joined to InventoryItem.tags, matched against
    OnboardingState.selected_interests) — but nothing in Onboarding ever
    called it, exactly as both that module's own scope note and
    episode_generator.py's "Not done" section flagged: "a future pass can
    reuse that same query from app/api/routes/onboarding.py's
    confirm()/get_state() without needing any further Generator or storage
    work." This is that pass — reusing _derive_shared_inventory verbatim
    (same "if we cannot say why, we do not show it" matching, same
    SharedInventoryOut shape) rather than a second, divergent
    implementation, and taking its first (most-recently-published) match as
    the one sample to hand back here, since the PRD asks for one thing to
    play, not a shelf of options like Home's own screen.

    Root-cause check done for this fix (see PR description for the full
    verification): on a fresh database, `episodes` has zero rows with
    shared=True until POST /internal/generate-shared-inventory is run at
    least once (see app/services/episode_generator.py's "Built: shared
    inventory" section) — nothing queries or creates that content on its
    own. This function can only ever return non-null once that operational
    step has actually happened for at least one of the customer's selected
    interests; until then, null here is the honest answer, not a bug in this
    query. Wiring that trigger up on a schedule, or as part of a real
    content pipeline, is out of scope for this fix.
    """
    result = await _derive_shared_inventory(db, cliente)
    return result[0] if result else None


async def _trigger_first_episode_in_background(customer_id: uuid.UUID) -> None:
    """
    Defect fix (first-run blocking bug): runs the on-demand first-episode
    pipeline without the confirm() request waiting on it. Mirrors
    app.services.scheduler._tick's own pattern for calling run_generation
    outside of a request/response cycle — a FRESH AsyncSessionLocal(), never
    the request-scoped `db` confirm() used (that session closes the moment
    confirm()'s response is sent, well before this coroutine would finish),
    and its own try/except so a bad customer row or a transient pipeline
    failure can't crash an unattended background task (there's no HTTP
    request left on the other end to receive an error or retry).

    Not awaited by confirm() on purpose — see that function's docstring for
    why awaiting this here was the actual bug (a blank-spinner multi-minute
    hang) it fixes.
    """
    async with AsyncSessionLocal() as session:
        try:
            cliente = await session.get(Cliente, customer_id)
            if cliente is None:
                return
            await run_generation(session, cliente, path=EpisodePath.on_demand)
        except Exception:
            logger.exception(
                "onboarding: background first-episode generation failed for customer %s", customer_id
            )


async def _get_or_create_state(db: AsyncSession, cliente: Cliente) -> OnboardingState:
    state = await db.get(OnboardingState, cliente.id)
    if not state:
        state = OnboardingState(customer_id=cliente.id)
        db.add(state)
        await db.flush()
    return state


async def _transition_step(db: AsyncSession, cliente: Cliente, state: OnboardingState, new_step: OnboardingStep):
    """The state machine's one write path for `step` — every caller that moves it
    goes through here so onboarding_step_completed/entered (PRD §5) can't drift
    out of sync with the actual transitions."""
    old_step = state.step
    if old_step == new_step:
        return
    await emitir(db, "onboarding_step_completed", customer_id=cliente.id, source="onboarding", step=old_step.value)
    state.step = new_step
    await emitir(db, "onboarding_step_entered", customer_id=cliente.id, source="onboarding", step=new_step.value)


def _label(interest: dict, idioma: str) -> str:
    return interest["label_en"] if idioma == "en" else interest["label_es"]


def _seeds(interest: dict, idioma: str) -> list[str]:
    return interest["seeds_en"] if idioma == "en" else interest["seeds_es"]


# ── Endpoints ────────────────────────────────────────────────────────────────

@router.get("/interest_options", response_model=list[InterestOption])
async def interest_options(cliente: Cliente = Depends(get_current_cliente)):
    return [InterestOption(id=i["id"], label=_label(i, cliente.idioma)) for i in _SEEDS["interests"]]


@router.get("/state", response_model=StateOut)
async def get_state(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    state = await _get_or_create_state(db, cliente)
    await db.commit()

    count_result = await db.execute(
        select(func.count(Request.id)).where(Request.customer_id == cliente.id, Request.status == RequestStatus.active)
    )

    return StateOut(
        step=state.step.value,
        selected_interests=state.selected_interests or [],
        active_request_count=count_result.scalar() or 0,
        notifications_enabled=state.notifications_enabled,
        tour_completed=state.tour_completed,
        consent_accepted=state.consent_accepted_at is not None,
        onboarding_complete=cliente.onboarding_complete,
        day_zero_sample=await _day_zero_sample(db, cliente),
    )


@router.post("/consent")
async def accept_consent(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """Ley 1581 de 2012 (Colombia) — PRD §6: consent language must appear before the
    first request is saved. Recorded here; not yet enforced as a gate on request
    creation since there's no UI driving that sequencing yet."""
    state = await _get_or_create_state(db, cliente)
    if not state.consent_accepted_at:
        state.consent_accepted_at = datetime.utcnow()
    await db.commit()
    return {"consent_accepted": True}


@router.patch("/interests", response_model=StateOut)
async def set_interests(
    body: InterestsBody,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    unknown = [i for i in body.interests if i not in _SEEDS_BY_ID]
    if unknown:
        raise HTTPException(400, f"Unknown interest id(s): {', '.join(unknown)}")

    state = await _get_or_create_state(db, cliente)
    state.selected_interests = body.interests
    if state.step == OnboardingStep.interests:
        await _transition_step(db, cliente, state, OnboardingStep.requests)
    await db.commit()
    return await get_state(cliente, db)


@router.get("/suggestions")
async def suggestions(
    interest: str,
    cliente: Cliente = Depends(get_current_cliente),
):
    """
    'Suggest for me' — PRD §5: for the pilot, drawn from a curated seed list
    per interest (config, not AI). No preview_answer one-liner yet since
    that needs the AI Platform; the suggestion is the raw_text itself,
    ready to approve as-is or edit before saving via POST /requests.
    """
    interest_cfg = _SEEDS_BY_ID.get(interest)
    if not interest_cfg:
        raise HTTPException(404, "Unknown interest")
    return {"interest": interest, "suggestions": _seeds(interest_cfg, cliente.idioma)}


@router.patch("/step", response_model=StateOut)
async def set_step(
    body: SetStepBody,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """Manual step transitions — used for the skip paths (voice, notifications,
    additional requests are all skippable per PRD tenet 3)."""
    state = await _get_or_create_state(db, cliente)
    await _transition_step(db, cliente, state, body.step)
    await db.commit()
    return await get_state(cliente, db)


@router.post("/confirm", response_model=ConfirmationOut)
async def confirm(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """
    First-episode scheduling rule — PRD §5. Let T be the chosen delivery time
    today and `now` the confirmation moment:
    - If T - now >= 60 min: scheduled normally, delivers today at T. No job
      is created here — app.services.scheduler's own ticker creates the
      GenerationJob itself at T-60, same as it does for every other customer
      (see that module), so nothing extra to trigger from this endpoint.
    - Otherwise: an on-demand job starts now with a 60-minute target; the
      next episode is scheduled for T tomorrow.

    Defect fix (first-run blocking bug): the on-demand branch below used to
    be the deferred half of this endpoint (see module docstring's original
    scope note — "does not create a GenerationJob, since the Episode
    Generator doesn't exist yet"). It exists now, and the naive way to wire
    it up — `await run_generation(...)` right here — would hold this HTTP
    connection open for the whole research -> write -> voice pipeline
    (multiple sequential model calls, 2+ minutes), leaving the iOS app on a
    blank spinner well past the ETA this response is about to promise. The
    response below already commits to an ETA, not a finished episode, so
    nothing about this endpoint should block on the pipeline finishing —
    _trigger_first_episode_in_background is fired via asyncio.create_task
    (never awaited here), following the same
    fresh-session-outside-the-request pattern app.services.scheduler._tick
    already uses to call run_generation. Idempotency is unaffected: a repeat
    call to confirm() (or scheduler double-fire) just re-finds today's
    (customer, fecha, on_demand) job via run_generation's own uniqueness
    check instead of starting a second one — see that function's docstring.
    """
    count_result = await db.execute(
        select(func.count(Request.id)).where(Request.customer_id == cliente.id, Request.status == RequestStatus.active)
    )
    if (count_result.scalar() or 0) < 1:
        raise HTTPException(400, "At least one standing request is required before confirming (PRD tenet: the one non-skippable step).")

    perfil = await db.get(Profile, cliente.id)
    if not perfil or not perfil.delivery_time:
        raise HTTPException(400, "Set a delivery time first (PUT /profile) before confirming.")

    tz = ZoneInfo(perfil.delivery_timezone)
    now_local = datetime.now(tz)
    t_today = now_local.replace(
        hour=perfil.delivery_time.hour, minute=perfil.delivery_time.minute, second=0, microsecond=0
    )

    minutes_until = (t_today - now_local).total_seconds() / 60

    state = await _get_or_create_state(db, cliente)
    await _transition_step(db, cliente, state, OnboardingStep.confirm)

    if minutes_until >= 60:
        path = "scheduled"
        message = f"Your first episode arrives today at {t_today.strftime('%H:%M')}, and every day after that."
        eta = t_today
    else:
        path = "on_demand"
        eta = now_local + timedelta(minutes=60)
        message = f"Your first episode will be ready by {eta.strftime('%H:%M')} (about an hour from now). From tomorrow, every day at {t_today.strftime('%H:%M')}."

    await db.commit()

    if path == "on_demand":
        asyncio.create_task(_trigger_first_episode_in_background(cliente.id))

    return ConfirmationOut(
        message=message, path=path, first_episode_eta=eta,
        day_zero_sample=await _day_zero_sample(db, cliente),
    )


@router.patch("/notifications", response_model=StateOut)
async def set_notifications(
    body: NotificationsBody,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """Declining never blocks progress and is never re-prompted during onboarding (PRD)."""
    state = await _get_or_create_state(db, cliente)
    state.notifications_enabled = body.enabled
    await _transition_step(db, cliente, state, OnboardingStep.tour)
    await db.commit()
    return await get_state(cliente, db)


@router.post("/complete", response_model=StateOut)
async def complete_onboarding(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    count_result = await db.execute(
        select(func.count(Request.id)).where(Request.customer_id == cliente.id, Request.status == RequestStatus.active)
    )
    if (count_result.scalar() or 0) < 1:
        raise HTTPException(400, "At least one standing request is required to complete onboarding.")

    state = await _get_or_create_state(db, cliente)
    # NOTE: tour_completed is set unconditionally here, whether the customer actually
    # watched the tour or would have skipped it — there's no client endpoint that
    # distinguishes the two (see module docstring / README audit note). Emitting the
    # catalogue's tour_completed/tour_skipped from here would misrepresent what
    # happened, so those stay un-emittable until a real tour UI exists.
    state.tour_completed = True
    await _transition_step(db, cliente, state, OnboardingStep.done)
    state.completed_at = datetime.utcnow()
    cliente.onboarding_complete = True
    await db.commit()
    return await get_state(cliente, db)
