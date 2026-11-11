"""
Real-DB tests for the voicing-failure fix.

Before this fix, a TTS error was swallowed with the note "the text episode is
still good and published; audio_url just stays null this time." Three things
went wrong at once, and together they are the founder-reported "no audio at
all, critical as hell":

  1. `job.status = JobStatus.ready` is set INSIDE the try, after synthesis, so
     swallowing the error left the job on `voicing` — non-terminal, forever.
  2. The episode was published anyway with `audio_url` NULL, and
     `episode_published` was emitted for it.
  3. search.py computes `state = "ready" if ep.audio_url else "voicing"`, so a
     silent episode reads as "still generating" permanently.

These tests pin the new contract: a synthesis error is a FAILED job, the
episode stays unpublished, no `episode_published` event is emitted, and the
already-paid-for scripts are kept so the run can be re-voiced without
re-researching.

ElevenLabs is unconfigured in this worktree, so `elevenlabs_configured` is
monkeypatched True to reach the synthesis path at all, and `synthesize` is
swapped for a coroutine that raises — never mocked at the HTTP level.
Anthropic is unavailable too, so the research/write pipeline is faked through
tests.fakes.patch_ai_pipeline, exactly as the other suites do.

Run with (from backend/):
TEST_DATABASE_URL=postgresql+asyncpg://lucaku:lucaku@localhost:5432/lucaku_audio_test pytest tests/test_voicing_failure.py
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


async def _make_customer(db) -> Cliente:
    cliente = Cliente(email=f"{uuid.uuid4()}@example.com", auth_provider=AuthProvider.email,
                      hashed_password=None, nombre="Test Customer", idioma="es")
    db.add(cliente)
    await db.flush()
    db.add(Profile(customer_id=cliente.id, delivery_time=dt_time(7, 0), delivery_timezone="America/Bogota"))
    db.add(Request(customer_id=cliente.id, kind=RequestKind.standing, raw_text="Daily markets summary",
                   structured={}, status=RequestStatus.active, created_from=CreatedFrom.onboarding))
    await db.commit()
    await db.refresh(cliente)
    return cliente


def _arrange_tts(monkeypatch, *, raises: bool):
    patch_ai_pipeline(monkeypatch)
    monkeypatch.setattr(ai_platform, "elevenlabs_configured", lambda: True)

    if raises:
        async def boom(*a, **kw):
            # The real shape of the production failure: ElevenLabs returning
            # quota_exceeded once the plan's credits are spent.
            raise RuntimeError("quota_exceeded: 291 credits remaining, 782 required")
        monkeypatch.setattr(ai_platform, "synthesize", boom)
    else:
        async def ok(*a, **kw):
            return b"\x00\x01audio", 0.15, []
        monkeypatch.setattr(ai_platform, "synthesize", ok)


@pytest.mark.asyncio
async def test_a_tts_failure_marks_the_job_failed_not_stuck_on_voicing(full_db_session, monkeypatch):
    """Defect 1. The job must reach a TERMINAL status. `voicing` is not one:
    it leaves the customer on a spinner nothing can ever resolve."""
    _arrange_tts(monkeypatch, raises=True)
    cliente = await _make_customer(full_db_session)

    job = await run_generation(full_db_session, cliente)

    assert job.status == JobStatus.failed, (
        f"a TTS failure left the job on {job.status!r} — before the fix this was "
        "JobStatus.voicing, forever"
    )
    voicing_stages = [s for s in job.stages if s.get("stage") == "voicing"]
    assert any("quota_exceeded" in str(s.get("error", "")) for s in voicing_stages), \
        "the provider's own error must survive into job.stages for diagnosis"


@pytest.mark.asyncio
async def test_a_silent_episode_is_never_published(full_db_session, monkeypatch):
    """Defect 2. The episode row may exist, but it must not be published —
    published_at stays NULL so no customer-facing query can return it."""
    _arrange_tts(monkeypatch, raises=True)
    cliente = await _make_customer(full_db_session)

    await run_generation(full_db_session, cliente)

    episode = (await full_db_session.execute(
        select(Episode).where(Episode.customer_id == cliente.id)
    )).scalar_one()
    assert episode.audio_url is None
    assert episode.published_at is None, "a silent episode was published"


@pytest.mark.asyncio
async def test_the_scripts_are_kept_so_the_run_can_be_re_voiced(full_db_session, monkeypatch):
    """Research and writing are the expensive half and are already paid for.
    Rolling the episode back on a transient voice-provider error would burn
    that money and force a full re-research to recover."""
    _arrange_tts(monkeypatch, raises=True)
    cliente = await _make_customer(full_db_session)

    await run_generation(full_db_session, cliente)

    episode = (await full_db_session.execute(
        select(Episode).where(Episode.customer_id == cliente.id)
    )).scalar_one()
    blocks = (await full_db_session.execute(
        select(Block).where(Block.episode_id == episode.id)
    )).scalars().all()
    assert blocks, "the paid-for blocks were discarded on a TTS failure"
    assert all(b.script for b in blocks), "blocks survived but their scripts are empty"


@pytest.mark.asyncio
async def test_no_episode_published_event_on_a_failed_voicing(full_db_session, monkeypatch):
    """Defect 3's upstream cause. Emitting `episode_published` for a silent
    episode is what let the funnel count it as a successful delivery, which is
    why 'no audio at all' never surfaced as a metric."""
    _arrange_tts(monkeypatch, raises=True)
    cliente = await _make_customer(full_db_session)

    await run_generation(full_db_session, cliente)

    names = [e.name for e in (await full_db_session.execute(
        select(Event).where(Event.customer_id == cliente.id)
    )).scalars().all()]
    assert "episode_published" not in names, "a failed voicing still reported a published episode"
    assert "job_failed" in names, "a failed voicing emitted no failure event at all"


@pytest.mark.asyncio
async def test_a_successful_voicing_still_publishes(full_db_session, monkeypatch):
    """The guard rail: none of the above may break the happy path."""
    _arrange_tts(monkeypatch, raises=False)
    cliente = await _make_customer(full_db_session)

    job = await run_generation(full_db_session, cliente)

    assert job.status == JobStatus.ready
    episode = (await full_db_session.execute(
        select(Episode).where(Episode.customer_id == cliente.id)
    )).scalar_one()
    assert episode.audio_url is not None
    assert episode.published_at is not None

    names = [e.name for e in (await full_db_session.execute(
        select(Event).where(Event.customer_id == cliente.id)
    )).scalars().all()]
    assert "episode_published" in names
