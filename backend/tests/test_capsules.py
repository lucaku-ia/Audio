"""
Audio capsules, Phase 1a: per-block voicing, failure isolation, concatenated
file offsets from real durations, told_log, the playlist endpoint, budget.

Fakes only: research/write are the usual pipeline fakes, and
`ai_platform.synthesize` is replaced by FakeTTS (known durations, scripted
failures). Nothing here reaches Anthropic or ElevenLabs.
"""
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, time as dt_time, timezone
from pathlib import Path

import httpx
import pytest
from sqlalchemy import select

from app.api.deps import get_current_cliente
from app.db.session import get_db
from app.main import app
from app.models.cliente import AuthProvider, Cliente
from app.models.episode import Block, Episode, EpisodePath
from app.models.generation_job import JobStatus
from app.models.instrumentation import AICall, Event
from app.models.profile import Profile
from app.models.request import CreatedFrom, Request, RequestKind, RequestStatus
from app.services import ai_platform, capsules, told_log
from app.services.episode_generator import run_generation
from tests.fakes import fake_findings

TOPICS = {"alpha": 10, "beta": 20, "gamma": 30}  # marker -> real audio seconds


class FakeTTS:
    """Stands in for ai_platform.synthesize. Audio bytes name the capsule so the
    concatenated file's order is checkable; the last word timestamp carries the
    'real' duration. `fail[marker]` = how many calls for it raise first."""

    def __init__(self, fail: dict[str, int] | None = None, guard: bool = False, charge: float = 0.0):
        self.fail = dict(fail or {})
        self.calls: list[str] = []
        self.guard, self.charge = guard, charge

    async def __call__(self, db, text, voice_id, customer_id, request_id=None, episode_id=None,
                       with_timestamps=True):
        marker = next(m for m in TOPICS if m in text)
        if self.guard:
            await ai_platform.guard_paid_call(db, customer_id, "synthesize")
        self.calls.append(marker)
        if self.fail.get(marker, 0) > 0:
            self.fail[marker] -= 1
            raise RuntimeError(f"provider 503 for {marker}")
        if self.charge:
            db.add(AICall(call_id=uuid.uuid4(), prompt="synthesize", version="v1", purpose="synthesize",
                          model="m", provider="elevenlabs", characters=len(text), cost=self.charge,
                          latency_ms=1, context={"customer_id": str(customer_id)},
                          creado_en=datetime.now(timezone.utc)))
        words = [{"word": "w", "start_s": 0.0, "end_s": float(TOPICS[marker])}]
        return f"AUDIO[{marker}]".encode(), self.charge or 0.1, words


def _arrange(monkeypatch, tts: FakeTTS):
    async def _research(*a, **kw):
        return fake_findings(cost=0.0)

    async def _write(*a, **kw):
        raw = kw["raw_text"]
        return ai_platform.BlockResult(summary=f"Summary {raw}", script=f"Script {raw}. " * 8,
                                       sources=[], no_news=False, cost=0.0)

    monkeypatch.setattr(ai_platform, "research_topic", _research)
    monkeypatch.setattr(ai_platform, "write_block", _write)
    monkeypatch.setattr(ai_platform, "elevenlabs_configured", lambda: True)
    monkeypatch.setattr(ai_platform, "synthesize", tts)


async def _customer(db, *, one_off: tuple[str, ...] = ()) -> Cliente:
    c = Cliente(email=f"{uuid.uuid4()}@example.com", auth_provider=AuthProvider.email,
                hashed_password=None, nombre="Capsule Test", idioma="en")
    db.add(c)
    await db.flush()
    db.add(Profile(customer_id=c.id, delivery_time=dt_time(7, 0), delivery_timezone="UTC"))
    for marker in TOPICS:
        db.add(Request(customer_id=c.id,
                       kind=RequestKind.one_off if marker in one_off else RequestKind.standing,
                       raw_text=f"{marker} topic", structured={}, status=RequestStatus.active,
                       created_from=CreatedFrom.onboarding))
    await db.commit()
    await db.refresh(c)
    return c


async def _episode(db, c) -> Episode:
    return (await db.execute(select(Episode).where(Episode.customer_id == c.id))).scalar_one()


async def _blocks(db, ep) -> list[Block]:
    rows = (await db.execute(select(Block).where(Block.episode_id == ep.id))).scalars().all()
    return sorted(rows, key=capsules.sort_key)


def _marker(block: Block) -> str:
    return next(m for m in TOPICS if m in block.summary)


def _file_bytes(url: str) -> bytes:
    return capsules._media_path(url).read_bytes()


@asynccontextmanager
async def _client(db, cliente):
    async def _db():
        yield db
    app.dependency_overrides[get_db] = _db
    app.dependency_overrides[get_current_cliente] = lambda: cliente
    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
            yield client
    finally:
        app.dependency_overrides.clear()


# ── failure isolation ───────────────────────────────────────────────────────

async def test_one_of_three_capsules_failing_still_publishes_the_other_two(full_db_session, monkeypatch):
    tts = FakeTTS(fail={"beta": 99})
    _arrange(monkeypatch, tts)
    db = full_db_session
    c = await _customer(db)

    job = await run_generation(db, c)

    assert job.status == JobStatus.ready
    ep = await _episode(db, c)
    assert ep.audio_url and ep.published_at is not None and ep.playlist_version == 2
    blocks = await _blocks(db, ep)
    by_marker = {_marker(b): b for b in blocks}
    assert by_marker["alpha"].audio_status == by_marker["gamma"].audio_status == "voiced"
    assert by_marker["beta"].audio_status == "failed"
    assert by_marker["beta"].audio_url is None
    # bounded: exactly the per-pass cap, no more
    assert by_marker["beta"].voice_attempts == capsules.VOICE_MAX_ATTEMPTS
    assert tts.calls.count("beta") == capsules.VOICE_MAX_ATTEMPTS
    assert job.stages[-1]["capsules"] == {"voiced": 2, "failed": 1}


async def test_a_transient_failure_is_retried_inside_the_pass(full_db_session, monkeypatch):
    tts = FakeTTS(fail={"beta": 1})
    _arrange(monkeypatch, tts)
    c = await _customer(full_db_session)

    job = await run_generation(full_db_session, c)

    blocks = await _blocks(full_db_session, await _episode(full_db_session, c))
    assert job.status == JobStatus.ready
    assert [b.audio_status for b in blocks] == ["voiced"] * 3
    assert {_marker(b): b.voice_attempts for b in blocks}["beta"] == 2


async def test_nothing_voiced_still_fails_the_job_and_keeps_scripts(full_db_session, monkeypatch):
    _arrange(monkeypatch, FakeTTS(fail={m: 99 for m in TOPICS}))
    c = await _customer(full_db_session)

    job = await run_generation(full_db_session, c)

    assert job.status == JobStatus.failed
    ep = await _episode(full_db_session, c)
    assert ep.published_at is None and ep.audio_url is None
    assert all(b.script for b in await _blocks(full_db_session, ep))


# ── concatenation order and offsets from real durations ─────────────────────

async def test_concatenation_order_and_offsets_use_real_durations(full_db_session, monkeypatch):
    _arrange(monkeypatch, FakeTTS(fail={"beta": 99}))
    db = full_db_session
    c = await _customer(db)
    await run_generation(db, c)
    ep = await _episode(db, c)
    blocks = await _blocks(db, ep)

    voiced = [b for b in blocks if b.audio_status == "voiced"]
    expected_bytes = b"".join(f"AUDIO[{_marker(b)}]".encode() for b in voiced)
    assert _file_bytes(ep.audio_url) == expected_bytes

    cursor = 0
    for b in voiced:
        assert b.duration_s == TOPICS[_marker(b)]  # real, not the 150 wpm estimate
        assert (b.start_s, b.end_s) == (cursor, cursor + TOPICS[_marker(b)])
        assert _file_bytes(b.audio_url) == f"AUDIO[{_marker(b)}]".encode()
        assert b.word_timestamps[-1]["end_s"] == TOPICS[_marker(b)]  # capsule-relative
        cursor += TOPICS[_marker(b)]
    assert ep.duration_s == cursor
    failed = next(b for b in blocks if b.audio_status == "failed")
    assert failed.start_s == failed.end_s  # zero-length: not in the file


async def test_audio_urls_are_random_and_under_media(full_db_session, monkeypatch):
    _arrange(monkeypatch, FakeTTS())
    c = await _customer(full_db_session)
    await run_generation(full_db_session, c)
    for b in await _blocks(full_db_session, await _episode(full_db_session, c)):
        name = Path(b.audio_url).name
        assert b.audio_url.endswith(f"/media/{name}")
        assert name.startswith("capsule-") and uuid.UUID(name[len("capsule-"):-4])
        assert str(c.id) not in b.audio_url and "topic" not in b.audio_url


def test_mp3_probe_and_duration_fallbacks():
    frame = bytes([0xFF, 0xFB, 0x90, 0x00]) + b"\x00" * (417 - 4)  # MPEG-1 L3, 128 kbps, 44.1 kHz
    audio = frame * 100
    assert capsules.probe_mp3_duration(audio) == pytest.approx(100 * 1152 / 44100)
    tagged = b"ID3\x04\x00\x00\x00\x00\x00\x0a" + b"\x00" * 10 + audio
    assert capsules.probe_mp3_duration(tagged) == pytest.approx(100 * 1152 / 44100)
    assert capsules.probe_mp3_duration(b"not an mp3") is None
    # probe beats a misleading alignment; alignment beats bytes; wpm is the last resort
    assert capsules.real_duration_s(audio, [{"end_s": 99.0}], "x") == pytest.approx(100 * 1152 / 44100)
    assert capsules.real_duration_s(b"junk", [{"end_s": 7.5}], "x") == 7.5
    assert capsules.real_duration_s(b"\x00" * 16000, None, "x") == pytest.approx(1.0)
    assert capsules.real_duration_s(b"junk", [], "word " * 150) == pytest.approx(60.0)


# ── never rewritten after publish; late retry; bounded ──────────────────────

async def test_late_retry_voices_the_capsule_without_touching_the_published_file(full_db_session, monkeypatch):
    tts = FakeTTS(fail={"beta": 3})  # exactly the first pass's tries
    _arrange(monkeypatch, tts)
    db = full_db_session
    c = await _customer(db)
    await run_generation(db, c)
    ep = await _episode(db, c)
    before = [(b.id, b.start_s, b.end_s) for b in await _blocks(db, ep)]
    url, data, published = ep.audio_url, _file_bytes(ep.audio_url), ep.published_at

    again = await run_generation(db, c)  # beta is due and the provider recovered

    assert again.status == JobStatus.ready
    blocks = await _blocks(db, ep)
    beta = next(b for b in blocks if _marker(b) == "beta")
    assert beta.audio_status == "voiced" and beta.audio_url and beta.duration_s == TOPICS["beta"]
    assert [(b.id, b.start_s, b.end_s) for b in blocks] == before  # offsets untouched
    assert ep.audio_url == url and ep.published_at == published
    assert _file_bytes(ep.audio_url) == data  # the published file is never rewritten
    # legacy view still lists only what is in the file; the playlist has all three
    async with _client(db, c) as client:
        legacy = (await client.get(f"/api/generation/episodes/{ep.id}")).json()
        plist = (await client.get(f"/api/generation/episodes/{ep.id}/playlist")).json()
    assert len(legacy["blocks"]) == 2
    assert [i["audio_status"] for i in plist["items"]] == ["voiced"] * 3
    late = next(i for i in plist["items"] if i["block_id"] == str(beta.id))
    assert late["audio_url"] and late["start_s"] is None and late["end_s"] is None


async def test_retries_are_bounded_over_many_polls(full_db_session, monkeypatch):
    tts = FakeTTS(fail={"beta": 10_000})
    _arrange(monkeypatch, tts)
    db = full_db_session
    c = await _customer(db)
    for _ in range(12):
        await run_generation(db, c)
    assert tts.calls.count("beta") == capsules.VOICE_MAX_TOTAL_ATTEMPTS
    beta = next(b for b in await _blocks(db, await _episode(db, c)) if _marker(b) == "beta")
    assert beta.audio_status == "failed"


async def test_late_retry_respects_its_backoff_window(full_db_session, monkeypatch):
    tts = FakeTTS(fail={"beta": 10_000})
    _arrange(monkeypatch, tts)
    db = full_db_session
    c = await _customer(db)
    await run_generation(db, c)
    monkeypatch.setattr(capsules, "LATE_REVOICE_BACKOFF_S", 3600.0)
    n = tts.calls.count("beta")
    await run_generation(db, c)
    assert tts.calls.count("beta") == n  # published just now: not due yet


async def test_job_level_revoice_is_capped(full_db_session, monkeypatch):
    tts = FakeTTS(fail={m: 10_000 for m in TOPICS})
    _arrange(monkeypatch, tts)
    c = await _customer(full_db_session)
    for _ in range(10):
        job = await run_generation(full_db_session, c)
    assert job.status == JobStatus.failed
    assert max(tts.calls.count(m) for m in TOPICS) <= capsules.VOICE_MAX_TOTAL_ATTEMPTS


# ── told_log and one-off fulfilment ─────────────────────────────────────────

async def test_a_failed_capsule_does_not_count_as_told(full_db_session, monkeypatch):
    _arrange(monkeypatch, FakeTTS(fail={"beta": 99}))
    db = full_db_session
    c = await _customer(db)
    await run_generation(db, c)
    ep = await _episode(db, c)
    blocks = await _blocks(db, ep)
    for b in blocks:
        told = await told_log.recent_for_request(db, customer_id=c.id, request_id=b.request_id)
        if b.audio_status == "voiced":
            assert told == [b.summary]
        else:
            assert told == []  # published episode, but this capsule was never heard


async def test_legacy_null_status_still_counts_as_told(full_db_session):
    db = full_db_session
    c = await _customer(db)
    req = (await db.execute(select(Request).where(Request.customer_id == c.id).limit(1))).scalar_one()
    ep = Episode(customer_id=c.id, fecha=datetime.now(timezone.utc).date(), path=EpisodePath.scheduled,
                 published_at=datetime.now(timezone.utc), audio_url="https://x/y.mp3")
    db.add(ep)
    await db.flush()
    db.add(Block(episode_id=ep.id, request_id=req.id, start_s=0, end_s=30, summary="old row", script="x"))
    await db.commit()
    assert await told_log.recent_for_request(db, customer_id=c.id, request_id=req.id) == ["old row"]


async def test_one_off_is_fulfilled_only_once_its_capsule_is_voiced(full_db_session, monkeypatch):
    tts = FakeTTS(fail={"beta": 3})
    _arrange(monkeypatch, tts)
    db = full_db_session
    c = await _customer(db, one_off=("beta",))
    await run_generation(db, c)
    beta_req = (await db.execute(select(Request).where(Request.customer_id == c.id,
                                                       Request.raw_text == "beta topic"))).scalar_one()
    assert beta_req.status == RequestStatus.active and beta_req.fulfilled_episode_id is None

    await run_generation(db, c)  # late retry succeeds
    await run_generation(db, c)  # and a further poll must not answer it twice
    await db.refresh(beta_req)
    ep = await _episode(db, c)
    assert beta_req.status == RequestStatus.fulfilled and beta_req.fulfilled_episode_id == ep.id
    answered = [e for e in (await db.execute(select(Event).where(Event.name == "request_answered"))).scalars()
                if e.payload.get("request_id") == str(beta_req.id)]
    assert len(answered) == 1


# ── budget ──────────────────────────────────────────────────────────────────

@pytest.mark.budget_guard
async def test_budget_block_mid_episode_keeps_the_capsules_already_voiced(full_db_session, monkeypatch):
    monkeypatch.setenv("AI_DAILY_BUDGET_PER_CUSTOMER_USD", "0.25")
    tts = FakeTTS(guard=True, charge=0.30)  # the first capsule alone exhausts the day's budget
    _arrange(monkeypatch, tts)
    db = full_db_session
    c = await _customer(db)

    job = await run_generation(db, c)

    assert job.status == JobStatus.ready  # assembled from what was already voiced
    ep = await _episode(db, c)
    assert ep.audio_url and ep.published_at
    blocks = await _blocks(db, ep)
    assert [b.audio_status for b in blocks] == ["voiced", "blocked", "blocked"]
    assert len(tts.calls) == 1  # the guard stopped the pass; no paid call was attempted for the rest
    assert all((b.voice_attempts or 0) == 0 for b in blocks[1:])  # a refusal is not an attempt
    assert len((await db.execute(select(Event).where(Event.name == "budget_exceeded"))).scalars().all()) == 1
    # still blocked on the next poll: no spending, no new attempts
    await run_generation(db, c)
    assert len(tts.calls) == 1


@pytest.mark.budget_guard
async def test_blocked_user_with_nothing_voiced_fails_with_the_stable_code(full_db_session, monkeypatch):
    monkeypatch.setenv("AI_GLOBAL_KILL_SWITCH", "1")
    tts = FakeTTS(guard=True)
    _arrange(monkeypatch, tts)
    c = await _customer(full_db_session)

    job = await run_generation(full_db_session, c)

    assert job.status == JobStatus.failed
    assert any(s.get("code") == "ai_paused" for s in job.stages)
    assert tts.calls == []
    ep = await _episode(full_db_session, c)
    assert [b.audio_status for b in await _blocks(full_db_session, ep)] == ["blocked"] * 3


# ── playlist endpoint and legacy shapes ─────────────────────────────────────

async def test_playlist_shape_ownership_and_404(full_db_session, monkeypatch):
    _arrange(monkeypatch, FakeTTS(fail={"beta": 99}))
    db = full_db_session
    c = await _customer(db)
    other = await _customer(db)
    await run_generation(db, c)
    ep = await _episode(db, c)
    shared = Episode(customer_id=None, shared=True, fecha=ep.fecha, path=EpisodePath.shared,
                     published_at=datetime.now(timezone.utc), audio_url="https://x/s.mp3")
    db.add(shared)
    await db.commit()

    async with _client(db, c) as client:
        r = await client.get(f"/api/generation/episodes/{ep.id}/playlist")
        assert (await client.get(f"/api/generation/episodes/{shared.id}/playlist")).status_code == 404
        assert (await client.get(f"/api/generation/episodes/{uuid.uuid4()}/playlist")).status_code == 404
    async with _client(db, other) as client:
        assert (await client.get(f"/api/generation/episodes/{ep.id}/playlist")).status_code == 404

    body = r.json()
    assert set(body) == {"episode_id", "playlist_version", "published", "audio_url", "items"}
    assert body["playlist_version"] == 2 and body["published"] is True and body["audio_url"] == ep.audio_url
    assert [i["sequence"] for i in body["items"]] == [0, 1, 2]
    blocks = await _blocks(db, ep)
    assert [i["block_id"] for i in body["items"]] == [str(b.id) for b in blocks]
    for item, b in zip(body["items"], blocks):
        assert set(item) == {"block_id", "request_id", "sequence", "title", "summary", "duration_s",
                             "audio_url", "audio_status", "start_s", "end_s"}
        assert item["request_id"] == str(b.request_id) and item["title"] == b.summary
    failed = next(i for i in body["items"] if i["audio_status"] == "failed")
    assert failed["audio_url"] is None and failed["duration_s"] is None
    assert failed["start_s"] is None and failed["end_s"] is None
    ok = [i for i in body["items"] if i["audio_status"] == "voiced"]
    expected, cursor = [], 0
    for b in (b for b in blocks if b.audio_status == "voiced"):
        d = TOPICS[_marker(b)]
        expected.append((cursor, cursor + d, d))
        cursor += d
    assert [(i["start_s"], i["end_s"], i["duration_s"]) for i in ok] == expected


async def test_playlist_works_before_publish(full_db_session, monkeypatch):
    _arrange(monkeypatch, FakeTTS(fail={m: 99 for m in TOPICS}))
    db = full_db_session
    c = await _customer(db)
    await run_generation(db, c)
    ep = await _episode(db, c)
    async with _client(db, c) as client:
        body = (await client.get(f"/api/generation/episodes/{ep.id}/playlist")).json()
    assert body["published"] is False and body["audio_url"] is None
    assert [i["audio_status"] for i in body["items"]] == ["failed"] * 3


async def test_legacy_episode_fields_unchanged_and_failed_capsule_hidden(full_db_session, monkeypatch):
    _arrange(monkeypatch, FakeTTS(fail={"beta": 99}))
    db = full_db_session
    c = await _customer(db)
    await run_generation(db, c)
    async with _client(db, c) as client:
        ep_json = (await client.get("/api/generation/episodes/latest")).json()
    assert set(ep_json) == {"id", "fecha", "headline", "language", "style", "voice_id", "duration_s",
                            "audio_url", "had_more_any", "published_at", "blocks", "playlist_version"}
    assert set(ep_json["blocks"][0]) == {"id", "request_id", "start_s", "end_s", "duration_s", "summary",
                                         "script", "sources", "had_more", "word_timestamps"}
    assert len(ep_json["blocks"]) == 2 and all("beta" not in b["summary"] for b in ep_json["blocks"])
    assert ep_json["blocks"][0]["start_s"] == 0
    assert ep_json["blocks"][1]["start_s"] == ep_json["blocks"][0]["end_s"]
    assert ep_json["duration_s"] == ep_json["blocks"][1]["end_s"]
    assert ep_json["playlist_version"] == 2


async def test_home_banner_and_history_state_for_a_partial_episode(full_db_session, monkeypatch):
    from app.api.routes.home import _derive_banner
    _arrange(monkeypatch, FakeTTS(fail={"beta": 99}))
    db = full_db_session
    c = await _customer(db)
    await run_generation(db, c)
    banner = await _derive_banner(db, c)
    assert banner.state == "ready" and len(banner.blocks) == 2
    async with _client(db, c) as client:
        hist = (await client.get("/api/search/history")).json()
    assert [i["state"] for i in hist["items"]] == ["ready"]


async def test_without_tts_everything_stays_legacy(full_db_session, monkeypatch):
    _arrange(monkeypatch, FakeTTS())
    monkeypatch.setattr(ai_platform, "elevenlabs_configured", lambda: False)
    db = full_db_session
    c = await _customer(db)
    await run_generation(db, c)
    ep = await _episode(db, c)
    assert ep.audio_url is None and ep.published_at is not None and ep.playlist_version == 1
    blocks = await _blocks(db, ep)
    assert all(b.audio_status is None and b.audio_url is None for b in blocks)
    assert all(b.end_s > b.start_s for b in blocks)
    async with _client(db, c) as client:
        body = (await client.get(f"/api/generation/episodes/{ep.id}/playlist")).json()
    assert [i["audio_status"] for i in body["items"]] == ["legacy"] * 3
