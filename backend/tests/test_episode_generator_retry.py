"""
Real-DB tests for the Defect 2 fix: a same-day GenerationJob that ended in
terminal `empty` must not lock the customer out of ever getting a real
episode for the rest of that day once they add a new standing request — but
only up to a documented, cost-justified cap
(episode_generator._MAX_EMPTY_RETRIES_PER_DAY). See
app/services/episode_generator.py's run_generation/_empty_job_can_retry
docstrings for the mechanism.

No ANTHROPIC_API_KEY is available in this worktree, so
app.services.ai_platform.research_and_write_block (the only real AI call in
this path) is monkeypatched everywhere below — never mocked at the HTTP/SDK
level, just swapped for a fake coroutine that returns a scripted
ai_platform.BlockResult. ElevenLabs voicing needs no mocking: it's already
skipped since ELEVENLABS_API_KEY isn't set (see episode_generator.py's own
"Built: voicing" scope note).

Run with (from backend/):
TEST_DATABASE_URL=postgresql+asyncpg://lucaku:lucaku@localhost:5432/lucaku_audio_test pytest tests/test_episode_generator_retry.py
"""
import uuid
from datetime import time as dt_time

import pytest
from sqlalchemy import select

from app.api.routes.generation import run as run_endpoint
from app.models.cliente import AuthProvider, Cliente
from app.models.generation_job import GenerationJob, JobStatus
from app.models.profile import Profile
from app.models.request import CreatedFrom, Request, RequestKind, RequestStatus
from app.services import ai_platform
from app.services.episode_generator import _MAX_EMPTY_RETRIES_PER_DAY, run_generation


async def _make_customer_with_standing_request(db) -> Cliente:
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


async def _add_standing_request(db, cliente: Cliente, text: str) -> Request:
    req = Request(customer_id=cliente.id, kind=RequestKind.standing, raw_text=text,
                  structured={}, status=RequestStatus.active, created_from=CreatedFrom.interests)
    db.add(req)
    await db.commit()
    await db.refresh(req)
    return req


def _empty_result() -> ai_platform.BlockResult:
    return ai_platform.BlockResult(summary="", script="", sources=[], no_news=True, cost=0.43)


def _news_result() -> ai_platform.BlockResult:
    return ai_platform.BlockResult(
        summary="Something happened", script="Here is today's real news. " * 10, sources=[], no_news=False, cost=0.43,
    )


@pytest.mark.asyncio
async def test_empty_job_locked_out_before_the_fix_scenario(full_db_session, monkeypatch):
    """Reproduces the exact bug report: an empty job, then a new standing
    request, then a re-run — before the fix this returned the same stale
    empty job forever; after the fix it re-researches and can come back
    `ready` once there's something new to say."""
    async def fake_empty(*a, **kw):
        return _empty_result()

    monkeypatch.setattr(ai_platform, "research_and_write_block", fake_empty)
    cliente = await _make_customer_with_standing_request(full_db_session)

    job1 = await run_generation(full_db_session, cliente)
    assert job1.status == JobStatus.empty
    assert job1.started_new_run is True
    assert job1.retry_count == 0

    # Immediately calling again with NO new standing request must still be
    # the pre-existing "never fill" idempotency behavior: same job, unchanged.
    job2 = await run_generation(full_db_session, cliente)
    assert job2.id == job1.id
    assert job2.status == JobStatus.empty
    assert job2.started_new_run is False
    assert job2.retry_count == 0

    # Now the customer adds a new standing request — the fix's trigger condition.
    await _add_standing_request(full_db_session, cliente, "Also tell me about interest rates")

    async def fake_news(*a, **kw):
        return _news_result()

    monkeypatch.setattr(ai_platform, "research_and_write_block", fake_news)

    job3 = await run_generation(full_db_session, cliente)
    assert job3.id == job1.id  # same row — (customer, fecha, path) is still unique
    assert job3.status == JobStatus.voicing  # ElevenLabs unconfigured in this worktree — see module docstring
    assert job3.started_new_run is True
    assert job3.retry_count == 1

    # Only one GenerationJob row ever existed for this customer/day/path.
    all_jobs = (await full_db_session.execute(
        select(GenerationJob).where(GenerationJob.customer_id == cliente.id)
    )).scalars().all()
    assert len(all_jobs) == 1


@pytest.mark.asyncio
async def test_ready_job_is_never_retried_even_with_a_new_standing_request(full_db_session, monkeypatch):
    """Narrow fix, per the task: only `empty` gets a second chance. A `ready`
    job must stay exactly as final as it always was — new requests just wait
    for the next day's/on_demand's own fresh job."""
    async def fake_news(*a, **kw):
        return _news_result()

    monkeypatch.setattr(ai_platform, "research_and_write_block", fake_news)
    cliente = await _make_customer_with_standing_request(full_db_session)

    job1 = await run_generation(full_db_session, cliente)
    assert job1.status == JobStatus.voicing  # ElevenLabs unconfigured in this worktree — see module docstring

    await _add_standing_request(full_db_session, cliente, "One more topic")

    job2 = await run_generation(full_db_session, cliente)
    assert job2.id == job1.id
    assert job2.started_new_run is False
    assert job2.retry_count == 0


@pytest.mark.asyncio
async def test_empty_retry_cap_is_enforced(full_db_session, monkeypatch):
    """Cost-cap regression test: even with a fresh qualifying standing
    request added before every attempt, no more than
    _MAX_EMPTY_RETRIES_PER_DAY re-runs happen — the customer cannot turn an
    empty day into unbounded research spend."""
    async def fake_empty(*a, **kw):
        return _empty_result()

    monkeypatch.setattr(ai_platform, "research_and_write_block", fake_empty)
    cliente = await _make_customer_with_standing_request(full_db_session)

    job = await run_generation(full_db_session, cliente)
    assert job.status == JobStatus.empty
    assert job.retry_count == 0

    # Keep adding new standing requests and re-running — every result stays
    # empty, so retry_count should climb by exactly 1 per call, up to the cap.
    for expected_retry_count in range(1, _MAX_EMPTY_RETRIES_PER_DAY + 1):
        await _add_standing_request(full_db_session, cliente, f"Topic #{expected_retry_count}")
        job = await run_generation(full_db_session, cliente)
        assert job.started_new_run is True
        assert job.retry_count == expected_retry_count

    # One more new request past the cap: run_generation must now refuse to
    # retry again, no matter how "new" the request is.
    await _add_standing_request(full_db_session, cliente, "One topic too many")
    job_after_cap = await run_generation(full_db_session, cliente)
    assert job_after_cap.started_new_run is False
    assert job_after_cap.retry_count == _MAX_EMPTY_RETRIES_PER_DAY  # unchanged

    all_jobs = (await full_db_session.execute(
        select(GenerationJob).where(GenerationJob.customer_id == cliente.id)
    )).scalars().all()
    assert len(all_jobs) == 1  # still exactly one row — capped retries mutate it, never insert a second


@pytest.mark.asyncio
async def test_run_endpoint_exposes_run_started_distinction(full_db_session, monkeypatch):
    """Response-shape half of Defect 2: POST /generation/run's JobOut must
    let the client tell 'returned existing job unchanged' apart from
    'started a new run' — see app/api/routes/generation.py's JobOut.run_started."""
    async def fake_news(*a, **kw):
        return _news_result()

    monkeypatch.setattr(ai_platform, "research_and_write_block", fake_news)
    cliente = await _make_customer_with_standing_request(full_db_session)

    first = await run_endpoint(cliente, full_db_session)
    assert first.run_started is True
    assert first.status == "voicing"  # ElevenLabs unconfigured in this worktree — see module docstring

    second = await run_endpoint(cliente, full_db_session)
    assert second.run_started is False
    assert second.id == first.id


@pytest.mark.asyncio
async def test_get_job_endpoint_leaves_run_started_null(full_db_session, monkeypatch):
    """GET /generation/jobs/{id} never triggered anything, so it shouldn't
    guess at run_started — it should stay null, not default to False (which
    would misleadingly look like a real answer)."""
    from app.api.routes.generation import get_job

    async def fake_news(*a, **kw):
        return _news_result()

    monkeypatch.setattr(ai_platform, "research_and_write_block", fake_news)
    cliente = await _make_customer_with_standing_request(full_db_session)
    job = await run_generation(full_db_session, cliente)

    fetched = await get_job(job.id, cliente, full_db_session)
    assert fetched.run_started is None
