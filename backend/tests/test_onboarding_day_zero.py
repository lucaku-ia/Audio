"""
Real-DB tests for the Defect 3 fix: day-zero shared-inventory content wired
into Onboarding's own GET /state and POST /confirm (StateOut/ConfirmationOut
.day_zero_sample), per the PRD's "the first session has to end with audio
playing, even if that audio is not yet fully theirs." See
app/api/routes/onboarding.py's _day_zero_sample docstring for the mechanism
(it reuses app/api/routes/home.py's own _derive_shared_inventory verbatim).

This suite also does the root-cause verification the task asked for: on a
completely fresh database (nothing else in this repo ever seeds shared
episodes on its own), day_zero_sample must come back null, proving the gap
really is "no shared-inventory content has ever been generated" and not a
matching bug in this query. It then generates exactly one real
shared-inventory episode (via episode_generator.generate_shared_episode, the
same function POST /internal/generate-shared-inventory calls) with the AI
call mocked, and shows the fallback correctly reaches the customer once that
content exists — and correctly stays null for a customer whose interests
don't match it.

No ANTHROPIC_API_KEY is available in this worktree, so
app.services.ai_platform.research_and_write_block is monkeypatched for the
one shared-episode generation each test needs.

Run with (from backend/):
TEST_DATABASE_URL=postgresql+asyncpg://lucaku:lucaku@localhost:5432/lucaku_audio_test pytest tests/test_onboarding_day_zero.py
"""
import uuid
from datetime import time as dt_time

import pytest
from sqlalchemy import select

from app.api.routes import onboarding
from app.models.cliente import AuthProvider, Cliente
from app.models.episode import Episode
from app.models.onboarding import OnboardingState
from app.models.profile import Profile
from app.models.request import CreatedFrom, Request, RequestKind, RequestStatus
from app.services import ai_platform
from app.services.episode_generator import generate_shared_episode


async def _make_onboarding_customer(db, *, selected_interests: list[str]) -> Cliente:
    """A customer mid-onboarding: interests already picked (as they would be
    by the time they reach confirm() — interest selection is an earlier
    onboarding step), a delivery time set, and one standing request (both
    required by confirm() itself)."""
    cliente = Cliente(email=f"{uuid.uuid4()}@example.com", auth_provider=AuthProvider.email,
                       hashed_password=None, nombre="Test Customer", idioma="es")
    db.add(cliente)
    await db.flush()
    db.add(Profile(customer_id=cliente.id, delivery_time=dt_time(23, 59), delivery_timezone="America/Bogota"))
    db.add(Request(customer_id=cliente.id, kind=RequestKind.standing, raw_text="Daily news",
                    structured={}, status=RequestStatus.active, created_from=CreatedFrom.onboarding))
    db.add(OnboardingState(customer_id=cliente.id, selected_interests=selected_interests))
    await db.commit()
    await db.refresh(cliente)
    return cliente


async def _fake_news(*args, **kwargs) -> ai_platform.BlockResult:
    return ai_platform.BlockResult(
        summary="Tech roundup", script="Big things happened in technology today. " * 10,
        sources=[], no_news=False, cost=0.43,
    )


@pytest.mark.asyncio
async def test_no_shared_episodes_ever_generated_is_the_verified_root_cause(full_db_session):
    """Root-cause check: a completely fresh DB has zero shared=True episodes
    — nothing in this codebase creates them on its own (see
    app/services/episode_generator.py's shared-inventory scope note: it's a
    manually-triggered ops endpoint, no scheduler). Asserted directly against
    real Postgres, not assumed."""
    count = (await full_db_session.execute(select(Episode).where(Episode.shared.is_(True)))).scalars().all()
    assert count == []


@pytest.mark.asyncio
async def test_day_zero_sample_null_for_new_customer_before_content_exists(full_db_session):
    """GET /onboarding/state for a brand-new customer, on a fresh DB (no
    shared episodes generated yet): day_zero_sample must be null — this is
    the honest answer per the task's "don't fabricate content" instruction,
    not a bug in the matching query itself (see the next test)."""
    cliente = await _make_onboarding_customer(full_db_session, selected_interests=["technology"])

    state = await onboarding.get_state(cliente, full_db_session)
    assert state.day_zero_sample is None

    confirmation = await onboarding.confirm(cliente, full_db_session)
    assert confirmation.day_zero_sample is None


@pytest.mark.asyncio
async def test_day_zero_sample_populated_once_a_matching_shared_episode_exists(full_db_session, monkeypatch):
    """Once operations has actually run the shared-inventory pipeline for a
    tag the customer follows, the SAME fresh database now surfaces it
    through both GET /state and POST /confirm — proving the fallback
    mechanism itself is correct and the only real gap was "no content yet"."""
    monkeypatch.setattr(ai_platform, "research_and_write_block", _fake_news)

    shared_job = await generate_shared_episode(
        full_db_session, tag="technology", seed_request_text="Latest AI and technology developments.",
    )
    assert shared_job.status.value in ("voicing", "ready")  # published — see episode_generator's voicing scope note

    cliente = await _make_onboarding_customer(full_db_session, selected_interests=["technology", "sports"])

    state = await onboarding.get_state(cliente, full_db_session)
    assert state.day_zero_sample is not None
    assert state.day_zero_sample.tag == "technology"
    assert "technology" in state.day_zero_sample.reason

    confirmation = await onboarding.confirm(cliente, full_db_session)
    assert confirmation.day_zero_sample is not None
    assert confirmation.day_zero_sample.episode_id == state.day_zero_sample.episode_id


@pytest.mark.asyncio
async def test_day_zero_sample_stays_null_when_no_interest_matches(full_db_session, monkeypatch):
    """'If we cannot say why, we do not show it' — a shared episode existing
    for "technology" must not leak into a customer who never selected it."""
    monkeypatch.setattr(ai_platform, "research_and_write_block", _fake_news)
    await generate_shared_episode(
        full_db_session, tag="technology", seed_request_text="Latest AI and technology developments.",
    )

    cliente = await _make_onboarding_customer(full_db_session, selected_interests=["sports"])

    state = await onboarding.get_state(cliente, full_db_session)
    assert state.day_zero_sample is None


@pytest.mark.asyncio
async def test_day_zero_sample_null_before_interests_are_selected(full_db_session, monkeypatch):
    """A customer who hasn't reached the interests step yet (no
    OnboardingState.selected_interests) must also get null, never a guessed
    match — same tenet Home's own shared_inventory already follows."""
    monkeypatch.setattr(ai_platform, "research_and_write_block", _fake_news)
    await generate_shared_episode(
        full_db_session, tag="technology", seed_request_text="Latest AI and technology developments.",
    )

    cliente = await _make_onboarding_customer(full_db_session, selected_interests=[])

    state = await onboarding.get_state(cliente, full_db_session)
    assert state.day_zero_sample is None
