"""
Audio capsules, Phase 1a (docs/capsules-design.md rev 3, sections 3, 4.1, 6).

A capsule is the existing `Block`, now with its OWN audio file. This module
owns everything about that audio so episode_generator stays a pipeline:

  - voicing each block separately, with FAILURE ISOLATION: one failed voicing
    marks only that capsule `failed`; the others stay voiced;
  - bounded retries (attempts cap, exponential backoff) and a budget refusal
    that marks the remaining capsules `blocked` instead of failing the job;
  - building the legacy single concatenated file from the voiced capsules,
    with Block.start_s/end_s computed from REAL audio durations;
  - the (late) re-voicing of capsules that failed after the episode published,
    which NEVER touches the concatenated file or Episode.audio_url.

Statuses (Block.audio_status): pending | voiced | failed | blocked.
NULL means a legacy block (pre-capsule row, or an episode built with no TTS
configured) and counts as delivered everywhere, exactly as before.

Paid steps: every capsule is voiced through ai_platform.synthesize, which
calls guard_paid_call("synthesize") before spending, so the per-customer
budget and the kill switch apply to each capsule individually.
"""
import asyncio
import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import or_
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.episode import Block, Episode
from app.services import ai_platform

logger = logging.getLogger(__name__)

VOICED, FAILED, BLOCKED, PENDING = "voiced", "failed", "blocked", "pending"

# Tries per capsule inside ONE voicing pass (first try + retries).
VOICE_MAX_ATTEMPTS = 3
# Seconds before retry n (n = 1, 2...): VOICE_BACKOFF_S * 2 ** (n - 1). Tests set 0.
VOICE_BACKOFF_S = 2.0
# Lifetime cap of tries per capsule (in-pass + late). Budget refusals do not count.
VOICE_MAX_TOTAL_ATTEMPTS = 6
# A published episode's failed capsule is retried again no sooner than
# published_at + LATE_REVOICE_BACKOFF_S * tries_so_far. Tests set 0.
LATE_REVOICE_BACKOFF_S = 600.0

_MP3_BITRATES_V1_L3 = (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320)
_MP3_SAMPLE_RATES_V1 = (44100, 48000, 32000)
_ASSUMED_BITRATE_BPS = 128_000  # ElevenLabs default (mp3_44100_128); we send no output_format
_MIN_BYTES_FOR_BITRATE_ESTIMATE = 4096


def sort_key(block: Block) -> tuple[int, int]:
    return (block.sequence or 0, block.start_s)


def is_in_legacy_file(block: Block) -> bool:
    """
    Whether a block's audio is part of Episode.audio_url (the concatenated
    file) and so belongs in the legacy blocks[] the shipped iOS plays.
    NULL status = legacy row, in the file. A voiced capsule that was voiced
    after publish (or at a later pass) has a zero-length span and is not.
    """
    if block.audio_status is None:
        return True
    if block.audio_status == VOICED:
        return block.end_s > block.start_s
    return False


def counts_as_delivered(block: Block) -> bool:
    """Used by told_log's SQL twin below: legacy or voiced."""
    return block.audio_status is None or block.audio_status == VOICED


def delivered_clause():
    """SQLAlchemy clause form of counts_as_delivered, for queries."""
    return or_(Block.audio_status.is_(None), Block.audio_status == VOICED)


# ── real durations ───────────────────────────────────────────────────────────

def probe_mp3_duration(data: bytes) -> float | None:
    """
    Exact length of an MPEG-1 Layer III stream by walking its frame headers
    (no decoding, no dependency). None when it does not parse as such (not mp3,
    other MPEG version, truncated garbage), so callers can fall back.
    """
    pos, n = 0, len(data)
    if data[:3] == b"ID3" and n >= 10:
        size = (data[6] & 0x7F) << 21 | (data[7] & 0x7F) << 14 | (data[8] & 0x7F) << 7 | (data[9] & 0x7F)
        pos = 10 + size
    frames, seconds = 0, 0.0
    while pos + 4 <= n:
        h = int.from_bytes(data[pos:pos + 4], "big")
        if (h >> 21) & 0x7FF != 0x7FF or (h >> 19) & 3 != 3 or (h >> 17) & 3 != 1:
            break  # no sync / not MPEG-1 / not Layer III
        br_idx, sr_idx = (h >> 12) & 0xF, (h >> 10) & 3
        if br_idx in (0, 15) or sr_idx == 3:
            break
        bitrate, rate = _MP3_BITRATES_V1_L3[br_idx] * 1000, _MP3_SAMPLE_RATES_V1[sr_idx]
        length = 144 * bitrate // rate + ((h >> 9) & 1)
        frames += 1
        seconds += 1152 / rate
        pos += length
    return seconds if frames else None


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

def _media_path(url: str) -> Path:
    return settings.MEDIA_DIR / Path(url).name


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
    error: Exception | None = None  # the exception to report if NOTHING got voiced
    voiced: list[Block] = field(default_factory=list)
    failed: list[Block] = field(default_factory=list)
    blocked: list[Block] = field(default_factory=list)


async def _voice_one(db: AsyncSession, *, cliente_id, episode: Episode, block: Block,
                     voice_id: str | None, max_tries: int, outcome: VoicingOutcome) -> bool:
    """
    Voice one capsule with up to `max_tries` tries. Commits after each try so a
    failed attempt's AICall row and the attempt count persist. Returns False
    only when the spend guard refused (the caller then stops the whole pass).
    """
    for attempt in range(1, max_tries + 1):
        if (block.voice_attempts or 0) >= VOICE_MAX_TOTAL_ATTEMPTS:
            break
        block.voice_attempts = (block.voice_attempts or 0) + 1
        try:
            audio, cost, timestamps = await ai_platform.synthesize(
                db, block.script, voice_id, customer_id=cliente_id,
                request_id=block.request_id, episode_id=episode.id,
            )
        except ai_platform.AIBlocked as exc:
            block.voice_attempts -= 1  # a refusal never reached the provider: not an attempt
            outcome.error = outcome.error or exc
            await db.commit()  # the guard's own budget_exceeded event persists
            return False
        except Exception as exc:  # noqa: BLE001 — provider failure isolated to this capsule
            outcome.error = exc
            logger.warning("capsule voicing failed (try %d/%d): %s", attempt, max_tries, exc)
            await db.commit()
            if attempt < max_tries and VOICE_BACKOFF_S > 0:
                await asyncio.sleep(VOICE_BACKOFF_S * 2 ** (attempt - 1))
            continue
        outcome.spent += cost
        duration = real_duration_s(audio, timestamps, block.script)
        block.audio_url = _write_capsule_file(audio)
        block.duration_s = max(1, round(duration))
        block.word_timestamps = timestamps  # capsule-relative, as it always was block-relative
        block.audio_status = VOICED
        await db.commit()
        return True
    block.audio_status = FAILED
    await db.commit()
    return True


async def voice_pending(db: AsyncSession, *, cliente_id, episode: Episode, blocks: list[Block],
                        voice_id: str | None, max_tries: int = VOICE_MAX_ATTEMPTS) -> VoicingOutcome:
    """
    Voice every capsule that is not voiced yet, in order. One capsule failing
    never stops the next. A budget/kill-switch refusal marks that capsule and
    all remaining unvoiced ones `blocked` and ends the pass (calling the
    provider would only be refused again).
    """
    outcome = VoicingOutcome()
    todo = [b for b in sorted(blocks, key=sort_key) if b.audio_status != VOICED]
    for i, block in enumerate(todo):
        proceed = await _voice_one(db, cliente_id=cliente_id, episode=episode, block=block,
                                   voice_id=voice_id, max_tries=max_tries, outcome=outcome)
        if not proceed:
            for rest in todo[i:]:
                rest.audio_status = BLOCKED
            await db.commit()
            break
    for b in blocks:
        {VOICED: outcome.voiced, FAILED: outcome.failed, BLOCKED: outcome.blocked}.get(
            b.audio_status or "", outcome.failed).append(b)
    return outcome


async def build_concatenated_file(db: AsyncSession, episode: Episode, blocks: list[Block]) -> int:
    """
    Concatenate the voiced capsules (in sequence) into the legacy episode file,
    set Block.start_s/end_s from the real durations and publish, ONCE.
    Capsules not voiced get a zero-length span at the position they would have
    had. Returns how many capsules went into the file. Never rewrites an
    already-published file or audio_url.
    """
    if episode.audio_url:
        raise RuntimeError("episode audio already built; it is never rewritten after publish")
    ordered = sorted(blocks, key=sort_key)
    parts: list[bytes] = []
    cursor = 0.0
    for b in ordered:
        path = _media_path(b.audio_url) if b.audio_url else None
        if b.audio_status == VOICED and path is not None and path.exists():
            parts.append(path.read_bytes())
            b.start_s = round(cursor)
            cursor += float(b.duration_s or 0)
            b.end_s = round(cursor)
            if b.end_s <= b.start_s:
                b.end_s = b.start_s + 1  # keep a voiced capsule's span non-empty
        else:
            if b.audio_status == VOICED:  # file lost: needs a new voicing, not a ghost span
                b.audio_status = PENDING
            b.start_s = b.end_s = round(cursor)
    if not parts:
        raise RuntimeError("no voiced capsule to build the episode from")
    settings.MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    (settings.MEDIA_DIR / f"{episode.id}.mp3").write_bytes(b"".join(parts))
    episode.audio_url = f"{settings.PUBLIC_BASE_URL}/media/{episode.id}.mp3"
    episode.duration_s = round(cursor)
    episode.playlist_version = 2
    episode.published_at = datetime.now(timezone.utc)  # audio exists: only now is it an episode
    await db.commit()
    return len(parts)


def late_revoice_due(block: Block, episode: Episode, now: datetime | None = None) -> bool:
    """Whether a failed/blocked capsule of a PUBLISHED episode may get another try now."""
    if block.audio_status not in (FAILED, BLOCKED) or episode.published_at is None:
        return False
    tries = block.voice_attempts or 0
    if tries >= VOICE_MAX_TOTAL_ATTEMPTS:
        return False
    now = now or datetime.now(timezone.utc)
    published = episode.published_at
    if published.tzinfo is None:
        published = published.replace(tzinfo=timezone.utc)
    return (now - published).total_seconds() >= LATE_REVOICE_BACKOFF_S * tries
