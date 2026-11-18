"""
Discovery audio and the news <-> capsule link (capsules design rev 3, Phase 2).

DISCOVERY AUDIO. A news item can be voiced on tap, once per (item, voice), and
the file is then served free to everyone. The text voiced is the stored NewsItem
(title + short_version, falling back to body): listener-independent, no user data.

Flow of POST /news/{id}/audio (see request_audio):
  1. voiced already -> 200 immediately, no guard, no spend.
  2. voicing under a live lease -> 202 'voicing' (single-flight: nobody else pays).
  3. otherwise the caller may START a voicing: age limit and per-user daily rate
     limit are checked, then ai_platform.guard_paid_call for the DISCOVERY
     sentinel (kill switch + daily ceiling from the committed ledger).
  4. the claim is one atomic UPDATE ... RETURNING (attempt counted before the
     paid call, committed before the provider is contacted). Exactly one caller
     wins; the winner's request returns 202 at once and the paid call runs in a
     background task on its OWN session, so a slow provider or a client that
     disconnects never blocks the request or strands a half-paid voicing. The
     client polls GET /news/{id}/audio (free).
  5. failures: bounded (MAX_ATTEMPTS lifetime tries, RETRY_BACKOFF_S between
     them); a crashed worker's lease (LEASE_S) can be reclaimed, consuming an attempt.

States reported (additive `status`): none | voicing | voiced | failed | blocked.
`blocked` carries a stable `code` (ai_paused | discovery_ceiling |
discovery_rate_limited | discovery_too_old) and a localized `message`.

NEWS <-> CAPSULE LINK. enrich() adds, per news item and WITHOUT per-item queries
(a constant 3-4 queries for any page size): the caller's voiced/voicing audio
and `related_capsule`, the caller's OWN published block of the last 2 days whose
request topic normalises (findings_store.normalize) to the item's topic_key, with
cluster mates (same cluster_id) as a secondary hint.
"""
import asyncio
import logging
import uuid
from datetime import datetime, timedelta, timezone

from pydantic import BaseModel
from sqlalchemy import and_, func, or_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core import config as ai_config
from app.core.config import settings
from app.core.errors import CodedHTTPException
from app.core.i18n import language_for, msg
from app.core.voices import canonical_key, default_voice_key
from app.db.session import AsyncSessionLocal
from app.models.cliente import Cliente
from app.models.discovery import DiscoveryVoicingLog, NewsItemAudio
from app.models.episode import Block, Episode
from app.models.news import NewsItem
from app.models.profile import Profile
from app.models.request import Request
from app.services import ai_platform, capsules, findings_store
from app.services.news_pipeline import request_topic

logger = logging.getLogger(__name__)

PENDING, VOICING, VOICED, FAILED = "pending", "voicing", "voiced", "failed"
NONE, BLOCKED = "none", "blocked"  # response-only states

MAX_ATTEMPTS = 3
RETRY_BACKOFF_S = 45 * 60
LEASE_S = 30 * 60
POLL_HINT_S = 3
MAX_TEXT_CHARS = 2500
RELATED_WINDOW = timedelta(days=2)

# Tests point this at a sessionmaker bound to the test engine.
session_factory = AsyncSessionLocal
_tasks: set[asyncio.Task] = set()


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _aware(value: datetime | None) -> datetime | None:
    return value.replace(tzinfo=timezone.utc) if value is not None and value.tzinfo is None else value


# ── schemas ──────────────────────────────────────────────────────────────────

class NewsAudioOut(BaseModel):
    status: str  # none | voicing | voiced | failed | blocked
    url: str | None = None
    duration_s: int | None = None
    voice: str | None = None  # the voice key
    language: str | None = None
    code: str | None = None  # stable reason for failed / blocked
    message: str | None = None  # localized, show as is
    retry_after_s: int | None = None  # when to poll again (voicing) or retry (failed)


class NewsAudioStatusOut(NewsAudioOut):
    news_id: str


class RelatedCapsuleOut(BaseModel):
    episode_id: str
    block_id: str
    audio_status: str  # voiced | voicing | pending | failed | blocked | legacy (in the episode file only)
    audio_url: str | None = None  # the capsule's own file, when it has one


# ── state ────────────────────────────────────────────────────────────────────

def _state(row: NewsItemAudio | None, now: datetime) -> tuple[str, str | None, int | None]:
    """(status, code, retry_after_s) for a row. 'none' means: a POST may start a voicing."""
    if row is None:
        return NONE, None, None
    if row.status == VOICED:
        return VOICED, None, None
    started = _aware(row.voicing_started_at)
    if row.status == VOICING:
        if started is not None and (now - started).total_seconds() < LEASE_S:
            return VOICING, None, POLL_HINT_S
        if (row.attempts or 0) >= MAX_ATTEMPTS:
            return FAILED, "discovery_failed", None
        return NONE, None, None  # crashed worker: reclaimable
    if row.status == FAILED:
        if (row.attempts or 0) >= MAX_ATTEMPTS:
            return FAILED, "discovery_failed", None
        wait = RETRY_BACKOFF_S - (now - _aware(row.updated_at)).total_seconds()
        return (FAILED, "discovery_failed", int(wait) + 1) if wait > 0 else (NONE, None, None)
    if row.error:  # pending after a spend-guard refusal
        return BLOCKED, row.error, None
    return NONE, None, None


def _out(row: NewsItemAudio | None, status: str, code: str | None, retry: int | None, *,
         language, voice: str | None, news_id=None, with_message=True):
    kwargs = dict(
        status=status, voice=voice, code=code, retry_after_s=retry,
        url=row.audio_url if row is not None and status == VOICED else None,
        duration_s=row.duration_s if row is not None and status == VOICED else None,
        language=row.language if row is not None else None,
    )
    if with_message:
        text_code = "discovery_voicing" if status == VOICING else code
        kwargs["message"] = msg(text_code, language) if text_code else None
    return NewsAudioStatusOut(news_id=str(news_id), **kwargs) if news_id is not None else NewsAudioOut(**kwargs)


# ── voice and text ───────────────────────────────────────────────────────────

def voice_key_for(item_language: str | None, profile_voice: str | None) -> str:
    """The caller's voice for an item: their profile voice if it is in the allowlist of the
    language the item is written in, else that language's default."""
    lang = language_for(item_language)
    return canonical_key(lang, profile_voice) or default_voice_key(lang)


async def resolve_voice_key(db: AsyncSession, cliente: Cliente, item: NewsItem, requested: str | None) -> str:
    lang = language_for(item.language)
    if requested:
        key = canonical_key(lang, requested)
        if key is None:
            raise CodedHTTPException(422, msg("voice_not_allowed", cliente), "voice_not_allowed")
        return key
    profile_voice = (await db.execute(
        select(Profile.voice_id).where(Profile.customer_id == cliente.id))).scalar_one_or_none()
    return voice_key_for(lang, profile_voice)


def spoken_text(item: NewsItem) -> str:
    """The item's own text. No greeting, no name, nothing about any listener."""
    text = f"{item.title.strip()}. {(item.short_version or item.body or '').strip()}"
    return text[:MAX_TEXT_CHARS]


# ── endpoints' logic ─────────────────────────────────────────────────────────

async def _get_row(db: AsyncSession, news_id: uuid.UUID, key: str) -> NewsItemAudio | None:
    return (await db.execute(select(NewsItemAudio).where(
        NewsItemAudio.news_item_id == news_id, NewsItemAudio.voice_key == key))).scalar_one_or_none()


async def get_status(db: AsyncSession, cliente: Cliente, item: NewsItem, key: str) -> NewsAudioStatusOut:
    """Free: reports the row, never starts anything."""
    row = await _get_row(db, item.id, key)
    status, code, retry = _state(row, _utcnow())
    return _out(row, status, code, retry, language=cliente, voice=key, news_id=item.id)


async def _blocked_reason(db: AsyncSession, cliente: Cliente, item: NewsItem, now: datetime) -> tuple[str, int | None] | None:
    age_limit = ai_config.discovery_item_max_age_hours()
    if age_limit > 0 and (now - _aware(item.published_at)).total_seconds() > age_limit * 3600:
        return "discovery_too_old", None
    per_user = ai_config.discovery_max_voicings_per_user_day()
    used = (await db.execute(select(func.count()).select_from(DiscoveryVoicingLog).where(
        DiscoveryVoicingLog.customer_id == cliente.id,
        DiscoveryVoicingLog.created_at >= ai_platform._utc_day_start(now)))).scalar_one()
    if used >= per_user:
        return "discovery_rate_limited", None
    try:  # kill switch + daily ceiling live in the one choke point
        await ai_platform.guard_paid_call(db, ai_platform.DISCOVERY_SENTINEL, "discovery_voicing", emit=False)
    except ai_platform.AIBlocked as exc:
        return exc.code, None
    return None


async def request_audio(db: AsyncSession, cliente: Cliente, item: NewsItem, key: str) -> tuple[NewsAudioStatusOut, int]:
    """POST /news/{id}/audio. Returns (body, http_status): 200 terminal, 202 voicing."""
    now = _utcnow()

    def done(row, status, code, retry):
        return _out(row, status, code, retry, language=cliente, voice=key, news_id=item.id), \
            (202 if status == VOICING else 200)

    row = await _get_row(db, item.id, key)
    status, code, retry = _state(row, now)
    if status in (VOICED, VOICING, FAILED):
        return done(row, status, code, retry)

    reason = await _blocked_reason(db, cliente, item, now)
    if reason is not None:
        return done(row, BLOCKED, reason[0], None)

    await db.execute(pg_insert(NewsItemAudio).values(
        id=uuid.uuid4(), news_item_id=item.id, voice_key=key, language=language_for(item.language),
        status=PENDING, attempts=0, cost=0.0, created_at=now, updated_at=now,
    ).on_conflict_do_nothing(constraint="uq_news_item_audio_item_voice"))
    cutoff = now - timedelta(seconds=LEASE_S)
    claimed = (await db.execute(
        update(NewsItemAudio)
        .where(
            NewsItemAudio.news_item_id == item.id, NewsItemAudio.voice_key == key,
            NewsItemAudio.attempts < MAX_ATTEMPTS,
            or_(
                NewsItemAudio.status == PENDING,
                and_(NewsItemAudio.status == FAILED, NewsItemAudio.updated_at <= now - timedelta(seconds=RETRY_BACKOFF_S)),
                and_(NewsItemAudio.status == VOICING,
                     or_(NewsItemAudio.voicing_started_at.is_(None), NewsItemAudio.voicing_started_at < cutoff)),
            ),
        )
        .values(status=VOICING, attempts=NewsItemAudio.attempts + 1, voicing_started_at=now, updated_at=now, error=None)
        .returning(NewsItemAudio.id)
        .execution_options(synchronize_session=False)
    )).scalar_one_or_none()
    log_id = None
    if claimed is not None:
        log_id = uuid.uuid4()
        db.add(DiscoveryVoicingLog(id=log_id, customer_id=cliente.id, news_item_id=item.id, voice_key=key,
                                   cost=0.0, created_at=now))
    await db.commit()
    if claimed is None:  # lost the race (or exhausted): report whatever the winner left
        row = await _get_row(db, item.id, key)
        status, code, retry = _state(row, _utcnow())
        return done(row, status if status != NONE else VOICING, code, retry or POLL_HINT_S)

    task = asyncio.create_task(_voice(claimed, log_id, spoken_text(item), key, language_for(item.language)))
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)
    row = await _get_row(db, item.id, key)
    return done(row, VOICING, None, POLL_HINT_S)


async def drain() -> None:
    """Wait for in-flight background voicings (tests; graceful shutdown)."""
    if _tasks:
        await asyncio.gather(*list(_tasks), return_exceptions=True)


# ── the paid step ────────────────────────────────────────────────────────────

def _write_file(audio: bytes) -> str:
    """Random name, never derived from content or user data (/media is static and unauthenticated)."""
    settings.MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    name = f"discovery-{uuid.uuid4().hex}.mp3"
    (settings.MEDIA_DIR / name).write_bytes(audio)
    return f"{settings.PUBLIC_BASE_URL}/media/{name}"


async def _voice(row_id: uuid.UUID, log_id: uuid.UUID, text: str, key: str, language: str) -> None:
    try:
        async with session_factory() as db:
            await _voice_with(db, row_id, log_id, text, key)
    except Exception:  # noqa: BLE001 — a background task must never die silently
        logger.exception("discovery voicing task crashed")


async def _voice_with(db: AsyncSession, row_id, log_id, text: str, key: str) -> None:
    row = await db.get(NewsItemAudio, row_id)
    log = await db.get(DiscoveryVoicingLog, log_id)
    try:
        audio, cost, timestamps = await ai_platform.synthesize(
            db, text, key, customer_id=ai_platform.DISCOVERY_SENTINEL)
    except ai_platform.AIBlocked as exc:
        row.status, row.attempts, row.voicing_started_at = PENDING, max(0, (row.attempts or 1) - 1), None
        row.error, row.updated_at = exc.code, _utcnow()  # never reached the provider: attempt refunded
        await db.commit()
        return
    except Exception as exc:  # noqa: BLE001 — provider failure
        billed = "transport error" in str(exc)  # timeout/drop: the provider may have charged
        estimate = (len(text) / 1000) * ai_platform._ELEVENLABS_PRICE_PER_1K_CHARS if billed else 0.0
        row.status, row.voicing_started_at, row.error, row.updated_at = FAILED, None, "synthesis_failed", _utcnow()
        row.cost = (row.cost or 0.0) + estimate
        log.cost = estimate
        logger.warning("discovery voicing failed: %s", exc)
        await db.commit()
        return
    # Paid for from here on: the ledger is written whatever happens next.
    log.cost = cost
    row.cost = (row.cost or 0.0) + cost
    try:
        duration = capsules.real_duration_s(audio, timestamps, text)
        url = _write_file(audio)
    except Exception as exc:  # noqa: BLE001 — persistence failure
        row.status, row.voicing_started_at, row.error, row.updated_at = FAILED, None, "storage_failed", _utcnow()
        logger.error("discovery audio could not be stored: %s", exc)
        await db.commit()
        return
    row.audio_url, row.duration_s, row.word_timestamps = url, max(1, round(duration)), timestamps
    row.chars, row.status, row.voicing_started_at, row.error, row.updated_at = len(text), VOICED, None, None, _utcnow()
    await db.commit()


# ── news <-> capsule link, batched ───────────────────────────────────────────

async def enrich(db: AsyncSession, cliente: Cliente, items: list[NewsItem]
                 ) -> tuple[dict[uuid.UUID, NewsAudioOut], dict[uuid.UUID, RelatedCapsuleOut]]:
    """Audio state (caller's voice, no spend) and related capsule per item id, in a constant
    number of queries (profile voice, audio rows, caller's recent blocks, cluster mates)."""
    if not items:
        return {}, {}
    now = _utcnow()
    ids = [i.id for i in items]
    profile_voice = (await db.execute(
        select(Profile.voice_id).where(Profile.customer_id == cliente.id))).scalar_one_or_none()
    key_of = {i.id: voice_key_for(i.language, profile_voice) for i in items}

    rows = (await db.execute(select(NewsItemAudio).where(
        NewsItemAudio.news_item_id.in_(ids), NewsItemAudio.voice_key.in_(set(key_of.values()))))).scalars().all()
    by_item = {(r.news_item_id, r.voice_key): r for r in rows}
    audio: dict[uuid.UUID, NewsAudioOut] = {}
    for item in items:
        row = by_item.get((item.id, key_of[item.id]))
        status, code, retry = _state(row, now)
        if row is not None and status != NONE:
            audio[item.id] = _out(row, status, code, retry, language=cliente, voice=key_of[item.id],
                                  with_message=False)

    block_rows = (await db.execute(
        select(Block.id, Block.episode_id, Block.audio_status, Block.audio_url, Request.structured)
        .join(Episode, Episode.id == Block.episode_id)
        .join(Request, Request.id == Block.request_id)
        .where(Episode.customer_id == cliente.id, Episode.published_at.is_not(None),
               Episode.published_at >= now - RELATED_WINDOW, Block.no_news.is_(False))
        .order_by(Episode.published_at.desc(), Block.sequence)
    )).all()
    by_topic: dict[str, RelatedCapsuleOut] = {}
    for block_id, episode_id, audio_status, audio_url, structured in block_rows:
        topic_key = findings_store.normalize(request_topic(structured))
        if topic_key and topic_key not in by_topic:  # newest published episode wins
            by_topic[topic_key] = RelatedCapsuleOut(
                episode_id=str(episode_id), block_id=str(block_id),
                audio_status=audio_status or "legacy", audio_url=audio_url if audio_status == VOICED else None)

    related: dict[uuid.UUID, RelatedCapsuleOut] = {}
    unmatched = []
    for item in items:
        hit = by_topic.get(item.topic_key)
        if hit is not None:
            related[item.id] = hit
        elif item.cluster_id is not None:
            unmatched.append(item)
    if unmatched and by_topic:
        mates = (await db.execute(select(NewsItem.cluster_id, NewsItem.topic_key).where(
            NewsItem.cluster_id.in_({i.cluster_id for i in unmatched})))).all()
        topics_by_cluster: dict[uuid.UUID, list[str]] = {}
        for cluster_id, topic_key in mates:
            topics_by_cluster.setdefault(cluster_id, []).append(topic_key)
        for item in unmatched:
            hit = next((by_topic[t] for t in topics_by_cluster.get(item.cluster_id, []) if t in by_topic), None)
            if hit is not None:
                related[item.id] = hit
    return audio, related
