"""
Recovering a job that died in voicing, without paying for research twice.

When synthesis fails, run_generation keeps the episode and its finished block
scripts and leaves the episode unpublished. That state exists so the run can
be completed later for the price of the audio alone — research and writing
are the larger share of a run's cost and are already spent. These tests cover
the path that finally consumes it.

Most of them are about when re-voicing must REFUSE. Re-voicing a job that
failed before any script existed would publish an empty episode, which is a
worse outcome than the failure it was trying to recover from.

Run with (from backend/):
TEST_DATABASE_URL=postgresql+asyncpg://localhost:5432/lucaku_audio_test pytest tests/test_revoice.py
"""
import uuid
from datetime import time as dt_time

import pytest
from sqlalchemy import select

from app.models.cliente import AuthProvider, Cliente
from app.models.episode import Block, Episode
from app.models.generation_job import JobStatus
from app.models.instrumentation import Event
from app.models.profile import Profile
from app.models.request import CreatedFrom, Request, RequestKind, RequestStatus
from app.services import ai_platform
from app.services.episode_generator import run_generation
from tests.fakes import patch_ai_pipeline


async def _customer(db) -> Cliente:
    cliente = Cliente(email=f"{uuid.uuid4()}@example.com", auth_provider=AuthProvider.email,
                      hashed_password=None, nombre="Test", idioma="es")
    db.add(cliente)
    await db.flush()
    db.add(Profile(customer_id=cliente.id, delivery_time=dt_time(7, 0), delivery_timezone="America/Bogota"))
    db.add(Request(customer_id=cliente.id, kind=RequestKind.standing, raw_text="Daily markets summary",
                   structured={}, status=RequestStatus.active, created_from=CreatedFrom.onboarding))
    await db.commit()
    await db.refresh(cliente)
    return cliente


def _tts(monkeypatch, *, works: bool, calls: list | None = None):
    monkeypatch.setattr(ai_platform, "elevenlabs_configured", lambda: True)

    async def _synth(*a, **kw):
        if calls is not None:
            calls.append(1)
        if not works:
            raise RuntimeError("quota_exceeded: 291 credits remaining, 782 required")
        return b"\x00audio", 0.15, []

    monkeypatch.setattr(ai_platform, "synthesize", _synth)


async def _run_and_fail_voicing(db, monkeypatch) -> tuple[Cliente, object]:
    patch_ai_pipeline(monkeypatch)
    _tts(monkeypatch, works=False)
    cliente = await _customer(db)
    job = await run_generation(db, cliente)
    assert job.status == JobStatus.failed
    return cliente, job


@pytest.mark.asyncio
async def test_a_job_that_died_voicing_is_recovered_without_re_researching(full_db_session, monkeypatch):
    cliente, job = await _run_and_fail_voicing(full_db_session, monkeypatch)

    # The founder tops up the plan. TTS works now; research must NOT run again.
    research_calls: list = []

    async def _forbidden_research(*a, **kw):
        research_calls.append(1)
        raise AssertionError("re-voicing must not re-research a paid-for episode")

    monkeypatch.setattr(ai_platform, "research_topic", _forbidden_research)
    _tts(monkeypatch, works=True)

    recovered = await run_generation(full_db_session, cliente)

    assert research_calls == []
    assert recovered.id == job.id
    assert recovered.status == JobStatus.ready

    episode = (await full_db_session.execute(
        select(Episode).where(Episode.customer_id == cliente.id)
    )).scalar_one()
    assert episode.audio_url is not None
    assert episode.published_at is not None, "a recovered episode must actually be published"


@pytest.mark.asyncio
async def test_a_still_broken_provider_leaves_the_job_terminal(full_db_session, monkeypatch):
    """A failed re-voice must stay `failed`. Dropping back to a non-terminal
    status would recreate the original 'stuck on voicing forever' bug."""
    cliente, job = await _run_and_fail_voicing(full_db_session, monkeypatch)
    _tts(monkeypatch, works=False)

    again = await run_generation(full_db_session, cliente)

    assert again.status == JobStatus.failed
    episode = (await full_db_session.execute(
        select(Episode).where(Episode.customer_id == cliente.id)
    )).scalar_one()
    assert episode.published_at is None, "a still-silent episode was published"


@pytest.mark.asyncio
async def test_it_publishes_exactly_once(full_db_session, monkeypatch):
    """episode_published must fire on the successful recovery and not again
    on a later call — the funnel counts deliveries off this event."""
    cliente, _ = await _run_and_fail_voicing(full_db_session, monkeypatch)
    _tts(monkeypatch, works=True)

    await run_generation(full_db_session, cliente)
    await run_generation(full_db_session, cliente)  # already ready — must be a no-op

    published = [e for e in (await full_db_session.execute(
        select(Event).where(Event.customer_id == cliente.id)
    )).scalars().all() if e.name == "episode_published"]
    assert len(published) == 1, f"episode_published fired {len(published)} times"


@pytest.mark.asyncio
async def test_a_ready_job_is_never_re_voiced(full_db_session, monkeypatch):
    """Re-voicing a finished episode would re-bill the audio — the most
    expensive half — for no benefit."""
    patch_ai_pipeline(monkeypatch)
    calls: list = []
    _tts(monkeypatch, works=True, calls=calls)
    cliente = await _customer(full_db_session)

    first = await run_generation(full_db_session, cliente)
    assert first.status == JobStatus.ready
    spent = len(calls)

    await run_generation(full_db_session, cliente)
    assert len(calls) == spent, "a ready job was voiced again"


@pytest.mark.asyncio
async def test_a_job_that_failed_before_writing_is_not_re_voiced(full_db_session, monkeypatch):
    """The important refusal. A job that died in research has no scripts;
    re-voicing it would publish an empty episode — worse than the failure it
    is trying to recover from."""
    patch_ai_pipeline(monkeypatch)
    cliente = await _customer(full_db_session)
    job = await run_generation(full_db_session, cliente)

    # Force the shape of a job that failed before any script existed.
    job.status = JobStatus.failed
    job.stages = [{"stage": "research", "error": "upstream exploded"}]
    await full_db_session.commit()

    _tts(monkeypatch, works=True, calls=(calls := []))
    await run_generation(full_db_session, cliente)

    assert calls == [], "a job with no scripts was sent to the voice provider"


@pytest.mark.asyncio
async def test_no_recovery_while_tts_is_still_unconfigured(full_db_session, monkeypatch):
    """Without a key there is nothing to retry with; the job stays failed and
    nothing pretends otherwise."""
    cliente, job = await _run_and_fail_voicing(full_db_session, monkeypatch)
    monkeypatch.setattr(ai_platform, "elevenlabs_configured", lambda: False)

    again = await run_generation(full_db_session, cliente)
    assert again.status == JobStatus.failed
