"""
AI spend guard: per-customer daily budget, optional global budget, and the
runtime kill switch (ai_platform.guard_paid_call).

Fakes only: the Anthropic client is replaced by an object that fails the test
if touched, and ElevenLabs/`synthesize` is never reached. Real Postgres is used
for AICall/Event rows, like the other full-pipeline suites.
"""
import types
import uuid
from datetime import datetime, time as dt_time, timedelta, timezone

import httpx
import pytest
from sqlalchemy import select

from app.api.deps import get_current_cliente
from app.db.session import get_db
from app.main import app
from app.models.cliente import AuthProvider, Cliente
from app.models.generation_job import JobStatus
from app.models.instrumentation import AICall, Event
from app.models.profile import Profile
from app.models.request import CreatedFrom, Request, RequestKind, RequestStatus
from app.services import ai_platform
from app.services.ai_platform import AIKillSwitchError, BudgetExceededError, guard_paid_call, spent_today
from app.services.episode_generator import run_generation
from app.api.routes.home import _derive_banner
from tests.fakes import patch_ai_pipeline

pytestmark = pytest.mark.budget_guard


@pytest.fixture(autouse=True)
def _clean_env_and_no_real_models(monkeypatch):
    for name in ("AI_GLOBAL_KILL_SWITCH", "AI_DAILY_BUDGET_PER_CUSTOMER_USD", "AI_DAILY_BUDGET_GLOBAL_USD"):
        monkeypatch.delenv(name, raising=False)

    def _forbidden(*a, **k):
        raise AssertionError("a real model call was attempted")

    monkeypatch.setattr(ai_platform, "_client", types.SimpleNamespace(
        messages=types.SimpleNamespace(create=_forbidden, parse=_forbidden)))


async def _customer(db) -> Cliente:
    c = Cliente(email=f"{uuid.uuid4()}@example.com", auth_provider=AuthProvider.email,
                hashed_password=None, nombre="Budget Test", idioma="en")
    db.add(c)
    await db.flush()
    db.add(Profile(customer_id=c.id, delivery_time=dt_time(7, 0), delivery_timezone="UTC"))
    db.add(Request(customer_id=c.id, kind=RequestKind.standing, raw_text="Daily markets summary",
                   structured={}, status=RequestStatus.active, created_from=CreatedFrom.onboarding))
    await db.commit()
    await db.refresh(c)
    return c


async def _spend(db, customer_id, cost, *, when=None, provider="anthropic"):
    db.add(AICall(
        call_id=uuid.uuid4(), prompt="x", version="v1", purpose="write_block", model="m", provider=provider,
        cost=cost, latency_ms=1, context={"customer_id": str(customer_id)},
        creado_en=when or datetime.now(timezone.utc),
    ))
    await db.commit()


async def _events(db, name="budget_exceeded"):
    return list((await db.execute(select(Event).where(Event.name == name))).scalars().all())


async def test_under_budget_passes(full_db_session, monkeypatch):
    monkeypatch.setenv("AI_DAILY_BUDGET_PER_CUSTOMER_USD", "1.00")
    c = await _customer(full_db_session)
    await _spend(full_db_session, c.id, 0.99)
    await guard_paid_call(full_db_session, c.id, "write_block")
    assert await _events(full_db_session) == []


async def test_default_budget_allows_a_normal_day_and_blocks_a_runaway(full_db_session):
    c = await _customer(full_db_session)
    await _spend(full_db_session, c.id, 0.58)  # one measured episode run
    await guard_paid_call(full_db_session, c.id, "write_block")
    await _spend(full_db_session, c.id, 0.95)  # ... then a runaway loop
    with pytest.raises(BudgetExceededError):
        await guard_paid_call(full_db_session, c.id, "write_block")


async def test_at_budget_raises_and_emits_event_without_free_text(full_db_session, monkeypatch):
    monkeypatch.setenv("AI_DAILY_BUDGET_PER_CUSTOMER_USD", "0.60")
    c = await _customer(full_db_session)
    await _spend(full_db_session, c.id, 0.60)  # exactly at the limit counts as exceeded
    with pytest.raises(BudgetExceededError) as info:
        await guard_paid_call(full_db_session, c.id, "research_topic")
    assert info.value.scope == "customer" and info.value.code == "budget_exceeded"
    await full_db_session.commit()
    [event] = await _events(full_db_session)
    assert event.customer_id == c.id
    assert set(event.payload) == {"scope", "purpose", "spent_usd", "limit_usd"}
    assert event.payload["limit_usd"] == 0.60 and event.payload["purpose"] == "research_topic"


async def test_budget_is_per_customer(full_db_session, monkeypatch):
    monkeypatch.setenv("AI_DAILY_BUDGET_PER_CUSTOMER_USD", "0.60")
    a, b = await _customer(full_db_session), await _customer(full_db_session)
    await _spend(full_db_session, a.id, 5.0)
    with pytest.raises(BudgetExceededError):
        await guard_paid_call(full_db_session, a.id, "write_block")
    await guard_paid_call(full_db_session, b.id, "write_block")  # b is untouched by a's spend


async def test_elevenlabs_spend_counts_toward_the_same_budget(full_db_session, monkeypatch):
    monkeypatch.setenv("AI_DAILY_BUDGET_PER_CUSTOMER_USD", "0.60")
    c = await _customer(full_db_session)
    await _spend(full_db_session, c.id, 0.40, provider="anthropic")
    await _spend(full_db_session, c.id, 0.25, provider="elevenlabs")
    with pytest.raises(BudgetExceededError):
        await guard_paid_call(full_db_session, c.id, "synthesize")


async def test_utc_day_rollover_resets_the_budget(full_db_session, monkeypatch):
    monkeypatch.setenv("AI_DAILY_BUDGET_PER_CUSTOMER_USD", "0.60")
    c = await _customer(full_db_session)
    late = datetime(2026, 3, 10, 23, 30, tzinfo=timezone.utc)
    await _spend(full_db_session, c.id, 0.70, when=late)
    assert await spent_today(full_db_session, c.id, now=late + timedelta(minutes=15)) == pytest.approx(0.70)
    assert await spent_today(full_db_session, c.id, now=late + timedelta(minutes=35)) == 0.0
    # Yesterday's spend (relative to the real clock) never blocks today.
    await _spend(full_db_session, c.id, 9.0, when=datetime.now(timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0) - timedelta(seconds=1))
    await guard_paid_call(full_db_session, c.id, "write_block")


async def test_kill_switch_toggles_at_runtime_and_covers_news(full_db_session, monkeypatch):
    c = await _customer(full_db_session)
    await guard_paid_call(full_db_session, c.id, "write_block")
    monkeypatch.setenv("AI_GLOBAL_KILL_SWITCH", "true")
    with pytest.raises(AIKillSwitchError):
        await guard_paid_call(full_db_session, c.id, "write_block")
    with pytest.raises(AIKillSwitchError):  # news is gated by the switch too
        await guard_paid_call(full_db_session, None, "news_write")
    with pytest.raises(AIKillSwitchError):
        await guard_paid_call(full_db_session, uuid.UUID(int=0), "research_topic")
    monkeypatch.setenv("AI_GLOBAL_KILL_SWITCH", "false")  # same process, no reload
    await guard_paid_call(full_db_session, c.id, "write_block")
    await guard_paid_call(full_db_session, None, "news_write")


async def test_news_callers_ignore_the_customer_budget(full_db_session, monkeypatch):
    monkeypatch.setenv("AI_DAILY_BUDGET_PER_CUSTOMER_USD", "0.01")
    news = uuid.UUID(int=0)
    await _spend(full_db_session, news, 50.0)
    await guard_paid_call(full_db_session, news, "research_topic")
    await guard_paid_call(full_db_session, None, "news_write")


async def test_global_budget_is_optional_and_refuses_customers_only(full_db_session, monkeypatch):
    c = await _customer(full_db_session)
    await _spend(full_db_session, c.id, 3.0)
    monkeypatch.setenv("AI_DAILY_BUDGET_PER_CUSTOMER_USD", "100")
    await guard_paid_call(full_db_session, c.id, "write_block")  # global unset = off
    monkeypatch.setenv("AI_DAILY_BUDGET_GLOBAL_USD", "2.5")
    with pytest.raises(BudgetExceededError) as info:
        await guard_paid_call(full_db_session, c.id, "write_block")
    assert info.value.scope == "global"
    await guard_paid_call(full_db_session, None, "news_write")


async def test_zero_disables_the_per_customer_check(full_db_session, monkeypatch):
    monkeypatch.setenv("AI_DAILY_BUDGET_PER_CUSTOMER_USD", "0")
    c = await _customer(full_db_session)
    await _spend(full_db_session, c.id, 100.0)
    await guard_paid_call(full_db_session, c.id, "write_block")


async def test_a_bad_env_value_falls_back_to_the_default(full_db_session, monkeypatch):
    monkeypatch.setenv("AI_DAILY_BUDGET_PER_CUSTOMER_USD", "banana")
    c = await _customer(full_db_session)
    await _spend(full_db_session, c.id, 1.6)
    with pytest.raises(BudgetExceededError):
        await guard_paid_call(full_db_session, c.id, "write_block")


async def test_every_paid_entry_point_is_guarded(full_db_session, monkeypatch):
    """The guard fires before the client is touched (the fake client fails the
    test if it is reached) for structure, escalation-runner and refine."""
    monkeypatch.setenv("AI_GLOBAL_KILL_SWITCH", "1")
    c = await _customer(full_db_session)

    async def prompt(db, name, fallback_version, fallback_system_prompt):
        return fallback_system_prompt, fallback_version
    monkeypatch.setattr(ai_platform, "get_active_prompt", prompt)

    with pytest.raises(AIKillSwitchError):
        await ai_platform.structure_request(full_db_session, "Top World stories", c.id)
    with pytest.raises(AIKillSwitchError):
        await ai_platform.refine_request(full_db_session, "x", {}, "less", "s", "t", c.id, uuid.uuid4())
    with pytest.raises(AIKillSwitchError):
        await ai_platform._run_with_escalation(
            full_db_session, purpose="write_block", version="v1", call=lambda m: None,
            parse=ai_platform._parse_findings, customer_id=c.id, context={})
    monkeypatch.setenv("ELEVENLABS_API_KEY", "fake")
    with pytest.raises(AIKillSwitchError):
        await ai_platform.synthesize(full_db_session, "hello", "voice", c.id)


# ── generation degrades gracefully ──────────────────────────────────────────

async def _run(db, cliente):
    """run_generation rolls back on failure, which expires `cliente`; real
    routes reload it per request, so the tests refresh it here."""
    job = await run_generation(db, cliente)
    await db.refresh(cliente)
    return job


def _real_guard_with_fake_pipeline(monkeypatch):
    """Research/write are faked but run the real guard first, like production."""
    patch_ai_pipeline(monkeypatch)
    fake_research = ai_platform.research_topic

    async def guarded_research(db, *a, customer_id=None, **kw):
        await guard_paid_call(db, customer_id, "research_topic")
        return await fake_research(db, *a, customer_id=customer_id, **kw)
    monkeypatch.setattr(ai_platform, "research_topic", guarded_research)


async def test_generation_over_budget_fails_cleanly_and_does_not_retry(full_db_session, monkeypatch):
    monkeypatch.setenv("AI_DAILY_BUDGET_PER_CUSTOMER_USD", "0.60")
    _real_guard_with_fake_pipeline(monkeypatch)
    c = await _customer(full_db_session)
    await _spend(full_db_session, c.id, 0.80)

    job = await _run(full_db_session, c)

    assert job.status == JobStatus.failed
    assert job.stages == [{"error": "budget_exceeded", "code": "budget_exceeded"}]  # no exception text leaks
    assert len(await _events(full_db_session)) == 1
    assert len(await _events(full_db_session, "job_failed")) == 1

    # Calling again while still over budget hands back the same job: no new
    # run, no retry_count bump, no extra events, no loop.
    again = await _run(full_db_session, c)
    assert again.id == job.id and again.started_new_run is False
    assert again.retry_count == job.retry_count
    assert len(await _events(full_db_session, "job_failed")) == 1


async def test_blocked_job_reruns_once_the_guard_allows_it(full_db_session, monkeypatch):
    monkeypatch.setenv("AI_GLOBAL_KILL_SWITCH", "1")
    _real_guard_with_fake_pipeline(monkeypatch)
    c = await _customer(full_db_session)

    job = await _run(full_db_session, c)
    assert job.status == JobStatus.failed and job.stages[0]["code"] == "ai_paused"
    assert (await _run(full_db_session, c)).started_new_run is False  # still paused

    monkeypatch.setenv("AI_GLOBAL_KILL_SWITCH", "false")
    job = await _run(full_db_session, c)
    # (With no TTS key the pipeline leaves the job on `voicing` — pre-existing;
    # what matters here is that it ran again and did not fail.)
    assert job.started_new_run is True and job.status != JobStatus.failed
    assert job.retry_count == 1


async def test_home_banner_keeps_its_existing_states_for_a_blocked_job(full_db_session, monkeypatch):
    monkeypatch.setenv("AI_GLOBAL_KILL_SWITCH", "1")
    _real_guard_with_fake_pipeline(monkeypatch)
    c = await _customer(full_db_session)
    job = await _run(full_db_session, c)
    assert job.status == JobStatus.failed

    banner = await _derive_banner(full_db_session, c)
    assert banner.state == "making"  # existing state; "failed" is never exposed


# ── HTTP: 429 on POST /requests ─────────────────────────────────────────────

async def test_post_requests_over_budget_is_a_clean_429(full_db_session, monkeypatch):
    monkeypatch.setenv("AI_DAILY_BUDGET_PER_CUSTOMER_USD", "0.60")
    c = await _customer(full_db_session)
    await _spend(full_db_session, c.id, 0.75)

    async def prompt(db, name, fallback_version, fallback_system_prompt):
        return fallback_system_prompt, fallback_version
    monkeypatch.setattr(ai_platform, "get_active_prompt", prompt)

    async def _db():
        yield full_db_session
    app.dependency_overrides[get_db] = _db
    app.dependency_overrides[get_current_cliente] = lambda: c
    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
            r = await client.post("/api/requests", json={"raw_text": "Tell me about Arsenal", "kind": "one_off"})
    finally:
        app.dependency_overrides.clear()

    assert r.status_code == 429
    assert r.json()["code"] == "budget_exceeded"
    assert len(r.json()["detail"]) < 100
    assert len(await _events(full_db_session)) == 1  # persisted despite the error
