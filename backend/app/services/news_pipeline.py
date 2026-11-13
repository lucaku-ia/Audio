"""
News pipeline (T-301/T-302/T-303 adapted to this FastAPI stack).

One run = one (topic_key, UTC date, slot). The run is TOPIC-scoped and knows
nothing about followers, so its cost is the same for 1 follower or 5,000:

  1. research  ai_platform.research_topic -> findings_store. Web search is
               paid once per topic per freshness window, whoever asks.
  2. cluster   findings with near-identical headlines collapse into one.
  3. novelty   clusters that match an item already published for this topic in
               the last NOVELTY_DAYS days are dropped (deterministic check;
               the writer is also told what was already published).
  4. write     ai_platform.write_news_items, at most MAX_ITEMS items.
  5. grounding "no source, no item": every URL an item cites must be one the
               research actually returned; an item left with none is dropped.
               Summaries over 70 characters are shortened, never stored long.

Idempotency: NewsRun has a unique (topic_key, run_date, slot). A run is
claimed by inserting that row; done / no_news / fresh-running rows make a
second call a no-op, failed or stale-running rows can be retried.

Source provider note: research uses Claude's web_search tool via ai_platform
(same as episodes), not a licensed news API.
"""
import logging
import re
import uuid
from datetime import date, datetime, timedelta, timezone
from difflib import SequenceMatcher
from urllib.parse import urlparse
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from sqlalchemy import and_, func, or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.news import NewsItem, NewsRun
from app.models.profile import Profile
from app.models.request import Request, RequestStatus
from app.services import ai_platform
from app.services.findings_store import normalize

logger = logging.getLogger(__name__)

MAX_ITEMS = 3
SUMMARY_MAX = 70
NOVELTY_DAYS = 3
SIMILARITY_THRESHOLD = 0.6
STALE_RUNNING = timedelta(minutes=30)
FAILED_BACKOFF = timedelta(minutes=45)
MAX_ATTEMPTS = 3

SLOT_MORNING = "0500"
SLOT_MIDDAY = "1300"
SLOT_ADHOC = "adhoc"
VALID_SLOTS = (SLOT_MORNING, SLOT_MIDDAY, SLOT_ADHOC)

CATEGORIES = (
    "local", "politics", "world", "markets", "personalFinance", "technology",
    "science", "health", "climate", "sports", "entertainment", "lifestyle",
)

# Mirrors NewsCategory.infer in the iOS app (HomeNews.swift): same rules, same
# order, so a topic maps to the same category on both sides.
_CATEGORY_RULES: list[tuple[str, list[str]]] = [
    ("sports", ["fc", "football", "soccer", "league", "cup", "nba", "nfl", "f1", "formula", "tennis", "arsenal", "madrid", "barcelona", "millonarios", "match", "team", "sport"]),
    ("personalFinance", ["saving", "savings", "mortgage", "tax", "budget", "money"]),
    ("markets", ["stock", "market", "econom", "rate", "inflation", "bank", "dollar", "peso", "shares", "bitcoin", "oil"]),
    ("technology", ["ai", "artificial", "intelligence", "tech", "startup", "apple", "google", "software", "chip", "crypto", "cyber"]),
    ("local", ["colombia", "bogot", "medell", "cali"]),
    ("politics", ["election", "politic", "congress", "president", "government", "court"]),
    ("climate", ["climate", "weather", "energy", "solar", "environment"]),
    ("health", ["health", "medic", "fitness", "nutrition", "sleep", "wellness"]),
    ("science", ["science", "space", "nasa", "physics", "research"]),
    ("entertainment", ["movie", "music", "film", "series", "tv", "streaming", "culture", "concert"]),
    ("lifestyle", ["travel", "food", "restaurant", "car", "flight", "fashion"]),
    ("world", ["world", "war", "international", "europe", "china", "middle east"]),
]


def infer_category(text: str | None) -> str | None:
    t = (text or "").lower()
    tokens = [w for w in re.split(r"[^\w]+", t) if w]
    for category, keywords in _CATEGORY_RULES:
        for word in keywords:
            hit = word in tokens if len(word) <= 3 else word in t
            if hit:
                return category
    return None


def _now() -> datetime:
    return datetime.now(timezone.utc)


def slot_for(now: datetime) -> str | None:
    """The scheduled slot a UTC instant falls in: 05:00-12:59 -> 0500,
    13:00-23:59 -> 1300, before 05:00 -> None (nothing scheduled)."""
    if now.hour >= 13:
        return SLOT_MIDDAY
    if now.hour >= 5:
        return SLOT_MORNING
    return None


def resolve_tz(name: str | None) -> tuple[str, ZoneInfo]:
    """(canonical name, tzinfo) for an IANA name; missing or invalid -> UTC."""
    if name:
        try:
            return name, ZoneInfo(name)
        except (ZoneInfoNotFoundError, ValueError, OSError):
            logger.warning("news: unknown timezone %r, falling back to UTC", name)
    return "UTC", ZoneInfo("UTC")


def local_slot(now: datetime, tz_name: str | None) -> tuple[str, date] | None:
    """(slot, local date) a UTC instant falls in for a timezone: local
    05:00-12:59 -> 0500, 13:00-23:59 -> 1300, 00:00-04:59 -> None (quiet)."""
    _, tz = resolve_tz(tz_name)
    local = now.astimezone(tz)
    slot = slot_for(local)
    return (slot, local.date()) if slot else None


# ---------------------------------------------------------------------------
# Text helpers
# ---------------------------------------------------------------------------

def _words(text: str) -> set[str]:
    return {w for w in re.split(r"[^a-z0-9]+", normalize(text)) if len(w) > 2}


def title_similarity(a: str, b: str) -> float:
    wa, wb = _words(a), _words(b)
    jaccard = len(wa & wb) / len(wa | wb) if wa and wb else 0.0
    ratio = SequenceMatcher(None, normalize(a), normalize(b)).ratio()
    return max(jaccard, ratio)


def clamp_summary(text: str) -> str:
    text = re.sub(r"\s+", " ", (text or "")).strip()
    if len(text) <= SUMMARY_MAX:
        return text
    cut = text[: SUMMARY_MAX - 1].rsplit(" ", 1)[0].rstrip(" ,;:.-")
    return (cut or text[: SUMMARY_MAX - 1]) + "…"


def _is_http_url(url: str) -> bool:
    try:
        parsed = urlparse(url)
    except Exception:
        return False
    return parsed.scheme in ("http", "https") and bool(parsed.netloc)


def _source_name(url: str, title: str | None) -> str:
    if title and title.strip():
        return title.strip()[:120]
    host = urlparse(url).netloc
    return host[4:] if host.startswith("www.") else host


def cluster_findings(findings: list) -> list[list]:
    """Greedy clustering by headline similarity. Each cluster is a list of
    Finding objects describing the same story."""
    clusters: list[list] = []
    for f in findings:
        for cluster in clusters:
            if title_similarity(f.headline, cluster[0].headline) >= SIMILARITY_THRESHOLD:
                cluster.append(f)
                break
        else:
            clusters.append([f])
    return clusters


def _merge_cluster(cluster: list):
    head = cluster[0].model_copy()
    urls: list[str] = []
    for f in cluster:
        for u in f.source_urls:
            if u not in urls:
                urls.append(u)
    head.source_urls = urls
    if len(cluster) > 1:
        head.detail = " ".join(dict.fromkeys(f.detail for f in cluster))
    return head


def ground_sources(draft_urls: list[str], findings) -> list[dict]:
    """Keep only URLs the research really returned. Unknown / invented / non-
    http URLs contribute nothing."""
    # Only the research `sources` list is trusted; a URL a finding mentions
    # that is not in it is logged and never citable.
    known: dict[str, str | None] = {}
    for s in findings.sources:
        if isinstance(s, dict) and s.get("url"):
            known[s["url"]] = s.get("title") or s.get("name")
    for f in findings.findings:
        for u in f.source_urls:
            if u not in known:
                logger.warning("news: finding %r cites %s which is not in research sources", f.headline, u)
    out: list[dict] = []
    for url in draft_urls:
        if url in known and _is_http_url(url) and all(o["url"] != url for o in out):
            out.append({"name": _source_name(url, known[url]), "url": url})
    return out


# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------

async def _claim_run(db: AsyncSession, topic_key: str, run_date: date, slot: str) -> uuid.UUID | None:
    """Returns the NewsRun id this caller now owns, or None.

    First run: the unique (topic_key, run_date, slot) insert is the claim.
    Re-claim (failed after BACKOFF, or running but STALE): ONE conditional
    UPDATE ... RETURNING, so two replicas can never both win. Capped at
    MAX_ATTEMPTS claims per key, because a failed research is not cached and
    every retry pays a fresh web search."""
    now = _now()
    run = NewsRun(topic_key=topic_key, run_date=run_date, slot=slot, status="running", attempts=1,
                  created_at=now, updated_at=now)
    try:
        async with db.begin_nested():
            db.add(run)
        await db.commit()
        return run.id
    except IntegrityError:
        await db.rollback()

    claimed = (await db.execute(
        update(NewsRun)
        .where(
            NewsRun.topic_key == topic_key, NewsRun.run_date == run_date, NewsRun.slot == slot,
            NewsRun.attempts < MAX_ATTEMPTS,
            or_(
                and_(NewsRun.status == "failed", NewsRun.updated_at < now - FAILED_BACKOFF),
                and_(NewsRun.status == "running", NewsRun.updated_at < now - STALE_RUNNING),
            ),
        )
        .values(status="running", attempts=NewsRun.attempts + 1, updated_at=now, error=None)
        .returning(NewsRun.id)
    )).scalar_one_or_none()
    await db.commit()
    return claimed


async def _finish_run(db: AsyncSession, run_id: uuid.UUID, **fields) -> None:
    await db.execute(update(NewsRun).where(NewsRun.id == run_id).values(updated_at=_now(), **fields))
    await db.commit()


# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

class NewsRunResult:
    def __init__(self, status: str, items: list[NewsItem] | None = None, cost: float = 0.0):
        self.status = status  # skipped | no_news | done
        self.items = items or []
        self.cost = cost


async def run_news_for_topic(
    db: AsyncSession,
    topic: str,
    *,
    slot: str,
    run_date: date | None = None,
    now: datetime | None = None,
    language: str = "en",
) -> NewsRunResult:
    now = now or _now()
    run_date = run_date or now.date()
    topic_key = normalize(topic)
    if not topic_key:
        return NewsRunResult("skipped")

    run_id = await _claim_run(db, topic_key, run_date, slot)
    if run_id is None:
        return NewsRunResult("skipped")

    try:
        # 1. Research: shared via findings_store, so followers never multiply it.
        findings = await ai_platform.research_topic(
            db, f"Latest news about {topic}", topic, "latest news", None,
            None, uuid.UUID(int=0),
        )
        cost = findings.cost
        if findings.parse_failed:
            await _finish_run(db, run_id, status="failed", error="research parse failed", cost=cost)
            return NewsRunResult("failed", cost=cost)
        if findings.no_news or not findings.findings:
            await _finish_run(db, run_id, status="no_news", cost=cost)
            return NewsRunResult("no_news", cost=cost)

        # 2-3. Cluster, then judge novelty against what is already published.
        since = now - timedelta(days=NOVELTY_DAYS)
        existing_titles = list((await db.execute(
            select(NewsItem.title).where(NewsItem.topic_key == topic_key, NewsItem.published_at >= since)
        )).scalars().all())

        fresh: list = []
        cluster_ids: list[uuid.UUID] = []
        for cluster in cluster_findings(findings.findings):
            merged = _merge_cluster(cluster)
            if any(title_similarity(merged.headline, t) >= SIMILARITY_THRESHOLD for t in existing_titles):
                continue
            fresh.append(merged)
            cluster_ids.append(uuid.uuid4())
        if not fresh:
            await _finish_run(db, run_id, status="no_news", cost=cost)
            return NewsRunResult("no_news", cost=cost)

        narrowed = findings.model_copy(update={"findings": fresh})

        # 4. Write (at most MAX_ITEMS).
        drafts = await ai_platform.write_news_items(
            db, narrowed, topic, max_items=MAX_ITEMS, already_published=existing_titles, language=language,
        )
        cost += drafts.cost

        # 5. Grounding + shape checks; every rejection is silent, never published.
        items: list[NewsItem] = []
        for draft in drafts.items:
            if len(items) >= MAX_ITEMS:
                break
            title = (draft.title or "").strip()
            summary = clamp_summary(draft.summary)
            sources = ground_sources(draft.source_urls, narrowed)
            if not title or not summary or not draft.body.strip() or not sources:
                logger.info("news: dropped draft %r (missing field or no grounded source)", title)
                continue
            if any(title_similarity(title, t) >= SIMILARITY_THRESHOLD for t in existing_titles + [i.title for i in items]):
                continue
            best = max(range(len(fresh)), key=lambda i: title_similarity(title, fresh[i].headline))
            category = draft.category if draft.category in CATEGORIES else (infer_category(topic) or "world")
            items.append(NewsItem(
                topic_key=topic_key, category=category, title=title[:300], summary=summary,
                short_version=draft.short_version.strip(), body=draft.body.strip(), sources=sources,
                image_hint=(draft.image_hint or None), published_at=now, slot=slot,
                cluster_id=cluster_ids[best],
            ))
        db.add_all(items)
        await _finish_run(db, run_id, status="done" if items else "no_news", items_count=len(items), cost=cost)
        return NewsRunResult("done" if items else "no_news", items, cost)
    except Exception as exc:
        await db.rollback()
        await _finish_run(db, run_id, status="failed", error=str(exc)[:300])
        raise


# ---------------------------------------------------------------------------
# Who follows what
# ---------------------------------------------------------------------------

def request_topic(structured: dict | None) -> str:
    return ((structured or {}).get("topic") or "").strip()


async def followed_topics_for(db: AsyncSession, cliente_id: uuid.UUID) -> tuple[set[str], set[str]]:
    """(topic_keys, categories) for one customer's active requests."""
    rows = (await db.execute(
        select(Request.structured, Request.raw_text).where(
            Request.customer_id == cliente_id, Request.status == RequestStatus.active
        )
    )).all()
    keys: set[str] = set()
    cats: set[str] = set()
    for structured, raw_text in rows:
        topic = request_topic(structured)
        if topic:
            keys.add(normalize(topic))
        cat = infer_category(topic or raw_text)
        if cat:
            cats.add(cat)
    return keys, cats


async def topics_with_followers(db: AsyncSession) -> list[str]:
    """Distinct topics (original wording of the first follower) of active
    requests, most-followed first. Followers only ORDER the list; they never
    multiply the work."""
    rows = (await db.execute(
        select(Request.structured).where(Request.status == RequestStatus.active)
    )).scalars().all()
    counts: dict[str, int] = {}
    display: dict[str, str] = {}
    for structured in rows:
        topic = request_topic(structured)
        key = normalize(topic)
        if not key:
            continue
        counts[key] = counts.get(key, 0) + 1
        display.setdefault(key, topic)
    return [display[k] for k in sorted(counts, key=lambda k: (-counts[k], k))]


async def followers_by_timezone(db: AsyncSession) -> dict[str, dict[str, tuple[str, int]]]:
    """{timezone: {topic_key: (display topic, follower count)}} for active
    requests. The timezone is the follower's Profile.delivery_timezone; a
    customer with no profile, or an invalid zone, counts under UTC."""
    rows = (await db.execute(
        select(Request.structured, Profile.delivery_timezone)
        .outerjoin(Profile, Profile.customer_id == Request.customer_id)
        .where(Request.status == RequestStatus.active)
    )).all()
    out: dict[str, dict[str, tuple[str, int]]] = {}
    for structured, tz_name in rows:
        topic = request_topic(structured)
        key = normalize(topic)
        if not key:
            continue
        tz_key, _ = resolve_tz(tz_name)
        topics = out.setdefault(tz_key, {})
        display, n = topics.get(key, (topic, 0))
        topics[key] = (display, n + 1)
    return out


def due_work(now: datetime, by_tz: dict[str, dict[str, tuple[str, int]]]) -> dict[tuple[date, str], dict[str, tuple[str, int]]]:
    """Which (local date, slot) pairs are open right now, and the topics each
    covers. Timezones that land on the same (date, slot) merge into one entry,
    so a topic is never scheduled twice for the same key."""
    work: dict[tuple[date, str], dict[str, tuple[str, int]]] = {}
    for tz_name, topics in by_tz.items():
        due = local_slot(now, tz_name)
        if due is None:
            continue
        slot, local_date = due
        merged = work.setdefault((local_date, slot), {})
        for key, (display, n) in topics.items():
            prev = merged.get(key)
            merged[key] = (prev[0] if prev else display, (prev[1] if prev else 0) + n)
    return work


async def run_scheduled_slot(db: AsyncSession, *, now: datetime | None = None, max_topics: int = 60,
                             ceiling: float | None = None) -> dict:
    """Runs every slot that is currently open in at least one customer
    timezone. The unit of work is still (topic_key, date, slot): the date is the
    LOCAL date in the timezone that opened the slot, and the work is deduped on
    that key, so cost grows with distinct (date, slot) pairs, never with
    followers. Safe to call as often as you like: finished keys are skipped."""
    now = now or _now()
    work = due_work(now, await followers_by_timezone(db))
    summary = {"slots": sorted(f"{d.isoformat()}:{s}" for d, s in work), "topics": 0, "ran": 0, "skipped": 0,
               "failed": 0, "ceiling_hit": False}
    ceiling = settings.NEWS_DAILY_COST_CEILING_USD if ceiling is None else ceiling
    for (run_date, slot), topics in sorted(work.items()):
        ordered = sorted(topics, key=lambda k: (-topics[k][1], k))[:max_topics]
        for key in ordered:
            spent = (await db.execute(
                select(func.coalesce(func.sum(NewsRun.cost), 0.0)).where(NewsRun.run_date == run_date)
            )).scalar_one()
            if spent >= ceiling:
                logger.warning("news: daily cost ceiling reached (%.2f >= %.2f), stopping slot", spent, ceiling)
                summary["ceiling_hit"] = True
                return summary
            summary["topics"] += 1
            try:
                result = await run_news_for_topic(db, topics[key][0], slot=slot, run_date=run_date, now=now)
            except Exception:
                logger.exception("news: run failed for topic %r", key)
                summary["failed"] += 1
                continue
            outcome = result.status if result.status in ("skipped", "failed") else "ran"
            summary[outcome] += 1
    return summary
