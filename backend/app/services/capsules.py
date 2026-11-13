"""
Audio capsules, Phase 1a (docs/capsules-design.md rev 3, sections 3, 4.1, 6).

A capsule is the existing `Block`, now with its OWN audio file. This module
owns everything about that audio so episode_generator stays a pipeline:

  - voicing each block separately, with FAILURE ISOLATION: one failed voicing
    marks only that capsule `failed`; the others stay voiced;
  - an ATOMIC CLAIM before every paid call (UPDATE ... WHERE status claimable
    RETURNING, committed before the provider is called), so overlapping
    requests / scheduler ticks never pay twice for the same capsule;
  - bounded retries (attempts cap, backoff, no retry of 4xx, early stop when
    the provider is clearly down) and a budget refusal that marks the
    remaining capsules `blocked` instead of failing the job;
  - building the legacy single concatenated file from the voiced capsules,
    with Block.start_s/end_s computed from REAL audio durations;
  - the optional late re-voicing of capsules that failed after publish, which
    NEVER touches the concatenated file or Episode.audio_url.

Statuses (Block.audio_status): pending | voicing | voiced | failed | blocked.
NULL means a legacy block (pre-capsule row, or an episode built with no TTS
configured) and counts as delivered everywhere, exactly as before.
"Delivered" (told_log, request fulfilment, legacy blocks[]) means the audio is
inside the episode's concatenated file: see is_in_legacy_file.

Paid steps: every capsule is voiced through ai_platform.synthesize, which
calls guard_paid_call("synthesize") before spending, so the per-customer
budget and the kill switch apply to each capsule individually.
"""
import asyncio
import logging
import re
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

from sqlalchemy import and_, func, or_, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.episode import Block, Episode
from app.services import ai_platform

logger = logging.getLogger(__name__)

VOICED, FAILED, BLOCKED, PENDING, VOICING = "voiced", "failed", "blocked", "pending", "voicing"

# Tries per capsule inside ONE voicing pass (first try + retries).
VOICE_MAX_ATTEMPTS = 3
# Seconds before retry n (n = 1, 2...): VOICE_BACKOFF_S * 2 ** (n - 1). Tests set 0.
VOICE_BACKOFF_S = 2.0
# Lifetime cap of tries per capsule (in-pass + late). Budget refusals do not count.
VOICE_MAX_TOTAL_ATTEMPTS = 6
# A published episode's failed capsule is retried again no sooner than
# published_at + LATE_REVOICE_BACKOFF_S * tries_so_far. Tests set 0.
LATE_REVOICE_BACKOFF_S = 600.0
# A 'voicing' claim older than this is a crashed worker's and may be reclaimed
# (the provider call itself times out at 120 s).
VOICE_LEASE_S = 300.0
# Stop a pass after this many consecutive capsules that exhausted their tries:
# the provider is down or refusing, and more calls only burn time in the request.
MAX_CONSECUTIVE_EXHAUSTED = 2
# At most this many capsules get a late retry per run_generation call.
LATE_REVOICE_PER_CALL = 1

_NON_RETRYABLE_EXCEPT = (408, 409, 425, 429)


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def sort_key(block: Block) -> tuple[int, int]:
    return (block.sequence or 0, block.start_s)


def is_in_legacy_file(block: Block) -> bool:
    """
    Whether a block's audio is part of Episode.audio_url (the concatenated
    file): the only audio the shipped iOS plays, and so the only thing that
    counts as delivered. NULL status = legacy row, in the file. A voiced
    capsule that was voiced after publish has a zero-length span: not in it.
    """
    if block.audio_status is None:
        return True
    if block.audio_status == VOICED:
        return block.end_s > block.start_s
    return False


def counts_as_delivered(block: Block) -> bool:
    return is_in_legacy_file(block)


def delivered_clause():
    """SQL twin of counts_as_delivered, for queries (told_log)."""
    return or_(Block.audio_status.is_(None),
               and_(Block.audio_status == VOICED, Block.end_s > Block.start_s))


# ── mp3 inspection ───────────────────────────────────────────────────────────

# (bitrate table, sample rates, samples per frame, coefficient) per MPEG version.
_BR_V1 = (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320)
_BR_V2 = (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160)
_SR = {3: (44100, 48000, 32000), 2: (22050, 24000, 16000), 0: (11025, 12000, 8000)}
_ASSUMED_BITRATE_BPS = 128_000  # ElevenLabs default (mp3_44100_128); we send no output_format
_MIN_BYTES_FOR_BITRATE_ESTIMATE = 4096


def _scan_mp3(data: bytes) -> tuple[int, int, float] | None:
    """
    Walk an MPEG Layer III stream's frame headers (no decoding, no dependency).
    Returns (first_audio_byte, end_of_last_frame, seconds), skipping a leading
    ID3v2 tag and a Xing/Info metadata frame, or None when the data does not
    parse as one clean stream: no frames, or the walk stops well short of the
    end (garbage in the middle). A trailing ID3v1/APE tag or one partial final
    frame is tolerated.
    """
    n, pos = len(data), 0
    if data[:3] == b"ID3" and n >= 10:
        pos = 10 + ((data[6] & 0x7F) << 21 | (data[7] & 0x7F) << 14 | (data[8] & 0x7F) << 7 | (data[9] & 0x7F))
    first, frames, seconds, last_len = None, 0, 0.0, 0
    while pos + 4 <= n:
        h = int.from_bytes(data[pos:pos + 4], "big")
        version, layer = (h >> 19) & 3, (h >> 17) & 3
        if (h >> 21) & 0x7FF != 0x7FF or version == 1 or layer != 1:
            break
        br_idx, sr_idx = (h >> 12) & 0xF, (h >> 10) & 3
        if br_idx in (0, 15) or sr_idx == 3:
            break
        mpeg1 = version == 3
        bitrate = (_BR_V1 if mpeg1 else _BR_V2)[br_idx] * 1000
        rate = _SR[version][sr_idx]
        samples = 1152 if mpeg1 else 576
        length = (144 if mpeg1 else 72) * bitrate // rate + ((h >> 9) & 1)
        if pos + length > n:
            break  # partial final frame
        mono = (h >> 6) & 3 == 3
        side = (17 if mono else 32) if mpeg1 else (9 if mono else 17)
        tag_at = pos + 4 + side
        if first is None and data[tag_at:tag_at + 4] in (b"Xing", b"Info"):
            pos += length  # silent metadata frame, not audio
            continue
        if first is None:
            first = pos
        frames += 1
        seconds += samples / rate
        pos += length
        last_len = length
    if not frames:
        return None
    rest = n - pos
    trailer_ok = (data[pos:pos + 3] == b"TAG" and rest == 128) or data[pos:pos + 8] == b"APETAGEX"
    if rest and not trailer_ok and rest > last_len:
        return None
    return first, pos, seconds


def probe_mp3_duration(data: bytes) -> float | None:
    scanned = _scan_mp3(data)
    return scanned[2] if scanned else None


def strip_mp3_container(data: bytes) -> bytes:
    """Audio frames only (no ID3v2/Xing/Info/trailer), so parts join cleanly.
    Anything that is not a clean mp3 stream is returned unchanged."""
    scanned = _scan_mp3(data)
    return data[scanned[0]:scanned[1]] if scanned else data


def real_duration_s(audio: bytes, word_timestamps: list[dict] | None, script: str) -> float:
    """
    Best available REAL length of one capsule's audio, in seconds:
    mp3 frame walk > last word-alignment end > bytes at the assumed bitrate >
    the 150 wpm estimate (last resort, only for degenerate/fake audio).
    """
    probed = probe_mp3_duration(audio)
    if probed:
        return probed
    if word_timestamps:
        end = max((float(w.get("end_s") or 0) for w in word_timestamps), default=0.0)
        if end > 0:
            return end
    if len(audio) >= _MIN_BYTES_FOR_BITRATE_ESTIMATE:
        return len(audio) * 8 / _ASSUMED_BITRATE_BPS
    return max(1.0, len(script.split()) / 150 * 60)


# ── files ────────────────────────────────────────────────────────────────────

def media_path(url: str) -> Path:
    return settings.MEDIA_DIR / Path(url).name


_media_path = media_path  # kept for tests


def _write_capsule_file(audio: bytes) -> str:
    """Random name, never derived from user data (/media is static and unauthenticated)."""
    settings.MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    name = f"capsule-{uuid.uuid4().hex}.mp3"
    (settings.MEDIA_DIR / name).write_bytes(audio)
    return f"{settings.PUBLIC_BASE_URL}/media/{name}"


# ── voicing ──────────────────────────────────────────────────────────────────

@dataclass
class VoicingOutcome:
    spent: float = 0.0
    error: Exception | None = None          # last provider/persistence failure
    blocked_error: Exception | None = None  # a spend-guard refusal (preferred when reporting)
    voiced: list[Block] = field(default_factory=list)
    failed: list[Block] = field(default_factory=list)
    blocked: list[Block] = field(default_factory=list)
    skipped: list[Block] = field(default_factory=list)  # claimed by another worker

    @property
    def report_error(self) -> Exception | None:
        return self.blocked_error or self.error


def _non_retryable(exc: Exception) -> bool:
    m = re.search(r"HTTP (\d{3})", str(exc))
    return bool(m) and 400 <= int(m.group(1)) < 500 and int(m.group(1)) not in _NON_RETRYABLE_EXCEPT


async def _claim(db: AsyncSession, block: Block) -> bool:
    """
    Atomic claim: only one caller wins a given capsule, and the attempt is
    counted BEFORE the paid call. Committed before the provider is contacted.
    A 'voicing' row whose lease expired (crashed worker) is reclaimable.
    """
    now = _utcnow()
    cutoff = now - timedelta(seconds=VOICE_LEASE_S)
    result = await db.execute(
        update(Block)
        .where(
            Block.id == block.id,
            or_(
                Block.audio_status.is_(None),
                Block.audio_status.in_((FAILED, BLOCKED, PENDING)),
                and_(Block.audio_status == VOICING,
                     or_(Block.voicing_started_at.is_(None), Block.voicing_started_at < cutoff)),
            ),
            func.coalesce(Block.voice_attempts, 0) < VOICE_MAX_TOTAL_ATTEMPTS,
        )
        .values(audio_status=VOICING, voice_attempts=func.coalesce(Block.voice_attempts, 0) + 1,
                voicing_started_at=now)
        .execution_options(synchronize_session=False)
    )
    await db.commit()
    await db.refresh(block)
    return result.rowcount == 1


async def _voice_one(db: AsyncSession, *, cliente_id, episode: Episode, block: Block,
                     voice_id: str | None, max_tries: int, outcome: VoicingOutcome) -> str:
    """
    Voice one capsule with up to `max_tries` tries. Returns one of
    'voiced', 'exhausted', 'skipped' (another worker owns it) or 'refused'
    (the spend guard said no: the caller stops the whole pass).
    """
    for attempt in range(1, max_tries + 1):
        if not await _claim(db, block):
            if block.audio_status in (VOICING, VOICED):
                outcome.skipped.append(block)
                return "skipped"
            if block.audio_status != FAILED:
                block.audio_status = FAILED  # attempts used up
                await db.commit()
            return "exhausted"
        try:
            audio, cost, timestamps = await ai_platform.synthesize(
                db, block.script, voice_id, customer_id=cliente_id,
                request_id=block.request_id, episode_id=episode.id,
            )
        except ai_platform.AIBlocked as exc:
            block.voice_attempts = max(0, (block.voice_attempts or 1) - 1)  # never reached the provider
            block.audio_status = BLOCKED
            block.voicing_started_at = None
            outcome.blocked_error = outcome.blocked_error or exc
            await db.commit()  # the guard's own budget_exceeded event persists
            return "refused"
        except Exception as exc:  # noqa: BLE001 — provider failure isolated to this capsule
            outcome.error = exc
            block.audio_status = FAILED
            block.voicing_started_at = None
            logger.warning("capsule voicing failed (try %d/%d): %s", attempt, max_tries, exc)
            await db.commit()
            if _non_retryable(exc):
                return "exhausted"  # quota / auth / bad request: retrying cannot help
            if attempt < max_tries and VOICE_BACKOFF_S > 0:
                await asyncio.sleep(VOICE_BACKOFF_S * 2 ** (attempt - 1))
            continue
        outcome.spent += cost
        try:
            duration = real_duration_s(audio, timestamps, block.script)
            block.audio_url = _write_capsule_file(audio)
        except Exception as exc:  # noqa: BLE001 — persistence failure: paid for, counts as an attempt
            outcome.error = exc
            block.audio_status = FAILED
            block.voicing_started_at = None
            logger.error("capsule audio could not be stored: %s", exc)
            await db.commit()  # the AICall row for the paid synthesis persists
            continue
        block.duration_s = max(1, round(duration))
        block.word_timestamps = timestamps  # capsule-relative, as it always was block-relative
        block.audio_status = VOICED
        block.voicing_started_at = None
        await db.commit()
        return "voiced"
    return "exhausted"


async def voice_pending(db: AsyncSession, *, cliente_id, episode: Episode, blocks: list[Block],
                        voice_id: str | None, max_tries: int = VOICE_MAX_ATTEMPTS) -> VoicingOutcome:
    """
    Voice every capsule that is not voiced yet, in order. One capsule failing
    never stops the next, except that two capsules in a row exhausting their
    tries ends the pass (provider down). A budget/kill-switch refusal marks the
    remaining unvoiced capsules `blocked` and ends the pass.
    """
    outcome = VoicingOutcome()
    todo = [b for b in sorted(blocks, key=sort_key) if b.audio_status != VOICED]
    consecutive = 0
    for i, block in enumerate(todo):
        result = await _voice_one(db, cliente_id=cliente_id, episode=episode, block=block,
                                  voice_id=voice_id, max_tries=max_tries, outcome=outcome)
        if result == "refused":
            for rest in todo[i + 1:]:
                if rest.audio_status in (None, PENDING, FAILED, BLOCKED) \
                        and (rest.voice_attempts or 0) < VOICE_MAX_TOTAL_ATTEMPTS:
                    rest.audio_status = BLOCKED
            await db.commit()
            break
        consecutive = consecutive + 1 if result == "exhausted" else 0
        if consecutive >= MAX_CONSECUTIVE_EXHAUSTED:
            for rest in todo[i + 1:]:
                if rest.audio_status in (None, PENDING):
                    rest.audio_status = FAILED  # not tried this pass; eligible for a later retry
            await db.commit()
            break
    for b in blocks:
        {VOICED: outcome.voiced, FAILED: outcome.failed, BLOCKED: outcome.blocked}.get(
            b.audio_status or "", []).append(b)
    return outcome


async def build_concatenated_file(db: AsyncSession, episode: Episode, blocks: list[Block]) -> int:
    """
    Concatenate the voiced capsules (in sequence) into the legacy episode file,
    set Block.start_s/end_s from the REAL durations of the bytes being joined
    (accumulated as floats, rounded only at the edges, so there is no drift)
    and publish, ONCE. Capsules not voiced get a zero-length span at the
    position they would have had. Returns how many capsules went into the
    file. Never rewrites an already-published file or audio_url.
    """
    if episode.audio_url:
        raise RuntimeError("episode audio already built; it is never rewritten after publish")
    parts: list[bytes] = []
    cursor = 0.0
    for b in sorted(blocks, key=sort_key):
        path = media_path(b.audio_url) if b.audio_url else None
        if b.audio_status == VOICED and path is not None and path.exists():
            raw = path.read_bytes()
            parts.append(strip_mp3_container(raw))
            start = cursor
            cursor += real_duration_s(raw, b.word_timestamps, b.script)
            b.start_s = round(start)
            b.end_s = max(round(cursor), b.start_s + 1)  # a voiced span is never empty
        else:
            if b.audio_status == VOICED:  # file lost: mark failed so a retry can re-voice it
                b.audio_status = FAILED
            b.start_s = b.end_s = round(cursor)
    if not parts:
        raise RuntimeError("no voiced capsule to build the episode from")
    settings.MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    (settings.MEDIA_DIR / f"{episode.id}.mp3").write_bytes(b"".join(parts))
    episode.audio_url = f"{settings.PUBLIC_BASE_URL}/media/{episode.id}.mp3"
    episode.duration_s = round(cursor)
    episode.playlist_version = 2
    episode.published_at = _utcnow()  # audio exists: only now is it an episode
    await db.commit()
    return len(parts)


def late_revoice_due(block: Block, episode: Episode, now: datetime | None = None) -> bool:
    """Whether a failed/blocked (or crashed-voicing) capsule of a PUBLISHED episode may get another try."""
    if episode.published_at is None:
        return False
    now = now or _utcnow()
    if block.audio_status == VOICING:
        started = block.voicing_started_at
        if started is not None and started.tzinfo is None:
            started = started.replace(tzinfo=timezone.utc)
        if started is not None and (now - started).total_seconds() < VOICE_LEASE_S:
            return False
    elif block.audio_status not in (FAILED, BLOCKED):
        return False
    tries = block.voice_attempts or 0
    if tries >= VOICE_MAX_TOTAL_ATTEMPTS:
        return False
    published = episode.published_at
    if published.tzinfo is None:
        published = published.replace(tzinfo=timezone.utc)
    return (now - published).total_seconds() >= LATE_REVOICE_BACKOFF_S * tries
