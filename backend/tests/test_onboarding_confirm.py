"""
Real-DB tests for the Defect 1 fix (first-run blocking bug): POST
/api/onboarding/confirm's on_demand branch must return immediately with the
ETA message, not hold the HTTP connection open for the whole research ->
write -> voice pipeline. See app/api/routes/onboarding.py's confirm() and
_trigger_first_episode_in_background docstrings for the fix itself.

Route handlers are called directly (same pattern as
app/api/routes/requests.py's own internal use of active_for_generation) — no
FastAPI TestClient/HTTP layer needed since these are plain async functions
once their Depends() defaults are supplied explicitly.

The only AI call this suite touches is app.services.ai_platform's Anthropic-
backed research_and_write_block — no ANTHROPIC_API_KEY is available in this
worktree, so it's monkeypatched to a fake coroutine everywhere the pipeline
would otherwise run (see conftest.py's full_db_session for why real commits
mean the plain db_session fixture doesn't fit these tests). ElevenLabs voicing
never needs mocking: ai_platform.elevenlabs_configured() is already false
with no ELEVENLABS_API_KEY set, so run_generation takes its documented
"skip voicing, publish text-only" path on its own.

Run with (from backend/):
TEST_DATABASE_URL=postgresql+asyncpg://lucaku:lucaku@localhost:5432/lucaku_audio_test pytest tests/test_onboarding_confirm.py
"""
import asyncio
import time
import uuid
from datetime import datetime, time as dt_time, timedelta

import pytest
from sqlalchemy import select
from zoneinfo import ZoneInfo

from app.api.routes import onboarding
from app.models.cliente import AuthProvider, Cliente
from app.models.episode import EpisodePath
from app.models.generation_job import GenerationJob
from app.models.profile import Profile
from app.models.request import CreatedFrom, Request, RequestKind, RequestStatus
from app.services import ai_platform

_TZ = "America/Bogota"


async def _make_customer(db, *, delivery_in_minutes: int) -> Cliente:
    """A customer past the onboarding gate confirm() checks: >=1 active
    standing request and a delivery_time set delivery_in_minutes from now in
    _TZ (rounded to the minute, matching confirm()'s own now_local.replace
    truncation)."""
    cliente = Cliente(email=f"{uuid.uuid4()}@example.com", auth_provider=AuthProvider.email,
                       hashed_password=None, nombre="Test Customer", idioma="es")
    db.add(cliente)
    await db.flush()

    now_local = datetime.now(ZoneInfo(_TZ))
    target = (now_local + timedelta(minutes=delivery_in_minutes)).replace(second=0, microsecond=0)
    db.add(Profile(customer_id=cliente.id, delivery_time=dt_time(target.hour, target.minute), delivery_timezone=_TZ))
    db.add(Request(customer_id=cliente.id, kind=RequestKind.standing, raw_text="Daily tech news",
                    structured={}, status=RequestStatus.active, created_from=CreatedFrom.onboarding))
    await db.commit()
    await db.refresh(cliente)
    return cliente


def _spy_create_task(monkeypatch, created: list):
    """Wraps asyncio.create_task as used inside onboarding.py so a test can
    later `await asyncio.gather(*created)` to let the background generation
    actually finish, instead of relying on asyncio.all_tasks() picking up
    unrelated pytest-asyncio housekeeping tasks."""
    real_create_task = asyncio.create_task

    def _spy(coro):
        task = real_create_task(coro)
        created.append(task)
        return task

    monkeypatch.setattr(onboarding.asyncio, "create_task", _spy)


async def _fake_slow_empty_research(*args, **kwargs) -> ai_platform.BlockResult:
    """Stands in for the real Anthropic-backed call (no ANTHROPIC_API_KEY in
    this worktree). Sleeps long enough that a test can prove confirm()
    returned well before this coroutine finished — the exact bug being
    fixed was confirm() awaiting a chain that bottoms out here."""
    await asyncio.sleep(0.35)
    return ai_platform.BlockResult(summary="", script="", sources=[], no_news=True, cost=0.43)


@pytest.mark.asyncio
async def test_confirm_on_demand_returns_before_pipeline_finishes(full_db_session, monkeypatch):
    """The core Defect 1 regression test: with delivery < 60 minutes away
    (the on_demand path), confirm() must return in well under the time the
    (mocked, artificially slowed) pipeline takes — proving the HTTP response
    isn't waiting on research_and_write_block at all."""
    monkeypatch.setattr(ai_platform, "research_and_write_block", _fake_slow_empty_research)
    created_tasks: list = []
    _spy_create_task(monkeypatch, created_tasks)

    cliente = await _make_customer(full_db_session, delivery_in_minutes=30)  # < 60 -> on_demand

    start = time.monotonic()
    result = await onboarding.confirm(cliente, full_db_session)
    elapsed = time.monotonic() - start

    assert result.path == "on_demand"
    assert "about an hour from now" in result.message
    # The mocked pipeline call alone sleeps 0.35s; confirm() returning in a
    # small fraction of that proves it never awaited the background task.
    assert elapsed < 0.1, f"confirm() took {elapsed:.3f}s — looks like it's blocking on generation again"

    # Let the background generation actually finish before checking the DB,
    # so this test also proves the background trigger really did fire.
    await asyncio.gather(*created_tasks)

    jobs = (await full_db_session.execute(
        select(GenerationJob).where(GenerationJob.customer_id == cliente.id, GenerationJob.path == EpisodePath.on_demand)
    )).scalars().all()
    assert len(jobs) == 1
    assert jobs[0].status.value == "empty"  # the fake research returned no_news=True


@pytest.mark.asyncio
async def test_confirm_scheduled_path_triggers_no_background_generation(full_db_session, monkeypatch):
    """>=60 minutes out takes the 'scheduled' branch — app.services.scheduler's
    own ticker creates that GenerationJob later, at T-60, so confirm() must
    not also kick off a background run itself (that would race the ticker
    and/or double up on the (customer, fecha, path) idempotency key)."""
    called = False

    async def _fail_if_called(*a, **kw):
        nonlocal called
        called = True
        raise AssertionError("research_and_write_block should not run from the scheduled path")

    monkeypatch.setattr(ai_platform, "research_and_write_block", _fail_if_called)
    created_tasks: list = []
    _spy_create_task(monkeypatch, created_tasks)

    cliente = await _make_customer(full_db_session, delivery_in_minutes=120)  # >= 60 -> scheduled

    result = await onboarding.confirm(cliente, full_db_session)
    assert result.path == "scheduled"
    assert created_tasks == []  # nothing was ever scheduled in the background

    # give any stray task a chance to run before asserting nothing happened
    await asyncio.sleep(0)
    assert called is False

    jobs = (await full_db_session.execute(
        select(GenerationJob).where(GenerationJob.customer_id == cliente.id)
    )).scalars().all()
    assert jobs == []


@pytest.mark.asyncio
async def test_confirm_called_twice_still_produces_one_job(full_db_session, monkeypatch):
    """Idempotency guarantee from the PR description must survive the fix: a
    double-tap (or a retried client request) on confirm() must not produce a
    second GenerationJob — run_generation's own (customer, fecha, path)
    uniqueness is what the second background trigger falls back on."""
    monkeypatch.setattr(ai_platform, "research_and_write_block", _fake_slow_empty_research)
    created_tasks: list = []
    _spy_create_task(monkeypatch, created_tasks)

    cliente = await _make_customer(full_db_session, delivery_in_minutes=30)

    await onboarding.confirm(cliente, full_db_session)
    await onboarding.confirm(cliente, full_db_session)
    await asyncio.gather(*created_tasks)

    jobs = (await full_db_session.execute(
        select(GenerationJob).where(GenerationJob.customer_id == cliente.id)
    )).scalars().all()
    assert len(jobs) == 1


@pytest.mark.asyncio
async def test_confirm_response_body_shape_unchanged_by_the_fix(full_db_session, monkeypatch):
    """Guards the "keep the response body identical" requirement: message,
    path and first_episode_eta must still be exactly what the pre-fix
    endpoint computed — only day_zero_sample (Defect 3, additive) and the
    background side effect are new."""
    monkeypatch.setattr(ai_platform, "research_and_write_block", _fake_slow_empty_research)
    created_tasks: list = []
    _spy_create_task(monkeypatch, created_tasks)

    cliente = await _make_customer(full_db_session, delivery_in_minutes=30)
    result = await onboarding.confirm(cliente, full_db_session)

    assert result.message.startswith("Your first episode will be ready by ")
    assert "From tomorrow, every day at " in result.message
    assert result.path == "on_demand"
    assert isinstance(result.first_episode_eta, datetime)
    assert result.day_zero_sample is None  # no shared inventory exists in a fresh DB — see Defect 3 tests

    await asyncio.gather(*created_tasks)
