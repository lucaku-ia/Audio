"""
The shared findings store — lookup and write-through for research results.

Why this exists, in the founder's own framing: "if 2 people are researching
for same thing, then the info is there and no need to research again." Not
one podcast for everyone — never that. Shared FACTS, bespoke episodes.

Cost context (measured, see README): after model routing, one researched +
written block costs ~$0.11, of which research is by far the larger part. A
cache hit drops a block's research cost to zero. The saving scales with how
many customers overlap on a topic, which is why the seed/standing topics
(markets, a league, a country's politics) are where this pays.

Freshness is the whole design problem. Stale news is worse than expensive
news, so entries expire, and the two kinds of result expire differently:

  FRESH_TTL (findings with news)
      A few hours. Research done this morning is still broadly true this
      afternoon, and the write step — which is per listener and never cached
      — is what makes each episode feel current and specific.

  EMPTY_TTL (no_news)
      Much shorter. "Nothing happened yet" is the single most time-sensitive
      answer in the system: a quiet topic at 7am can be the day's big story
      by 10am. Caching an empty result for hours would mean one early quiet
      check locks every later listener out of the news — exactly the
      empty-day lockout that was just fixed in the generator (PR #31), and
      it would be a shame to reintroduce it here by the back door.

A parse failure is never stored at all. It is a lost block, not a finding;
caching it would turn one malformed model response into everybody's.
"""
import re
import unicodedata
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core import clock
from app.models.findings_cache import FindingsCache

# Tunable without a deploy if they turn out wrong — but the ordering between
# them (empty expires much sooner than fresh) is a correctness property, not
# a preference. See the module docstring.
FRESH_TTL = timedelta(hours=6)
EMPTY_TTL = timedelta(minutes=45)


def normalize(value: str | None) -> str:
    """
    Canonical form of a key part.

    Casefold + accent-fold + whitespace-collapse, so "Premier League",
    "premier league " and "PREMIER LEAGUE" are one cache entry rather than
    three. Accent folding matters here specifically because customers write
    in Spanish: "Elecciones Colombia" and "elecciones colombia" must collide,
    and so should "Bogotá" and "Bogota".

    Deliberately conservative — no stemming, no synonym mapping, no
    translation. A false MISS costs one research call. A false HIT serves a
    customer findings about something they did not ask about, which is the
    kind of error this product cannot afford.
    """
    if not value:
        return ""
    folded = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")
    return re.sub(r"\s+", " ", folded).strip().casefold()[:300]


def _ttl_for(no_news: bool) -> timedelta:
    return EMPTY_TTL if no_news else FRESH_TTL


# Aware UTC, from the one clock the whole backend now shares. This module had
# its own copy first, because this is the table where the naive-utcnow() bug
# was found: a row stamped "now" came back hours in the FUTURE, every
# freshness check computed a negative age, every entry looked fresh forever,
# and the cache would have served yesterday's news indefinitely while looking
# like it worked. The sweep that followed made aware UTC the rule everywhere;
# these two names stay as the local vocabulary of a module that reads better
# with them. See app/core/clock.py for the mechanism.
_now = clock.utcnow
_as_utc = clock.as_utc


async def lookup(
    db: AsyncSession, *, topic: str, scope: str, geography: str | None, now: datetime | None = None
) -> FindingsCache | None:
    """Return a live cache entry, or None. Expired entries are treated as a
    miss and left in place — deleting them is a separate concern (and a
    useful record of what was researched when)."""
    now = now or _now()
    row = (await db.execute(
        select(FindingsCache).where(
            FindingsCache.topic_key == normalize(topic),
            FindingsCache.scope_key == normalize(scope),
            FindingsCache.geography_key == normalize(geography),
        )
    )).scalar_one_or_none()

    if row is None:
        return None
    if now - _as_utc(row.creado_en) > _ttl_for(row.no_news):
        return None
    return row


async def record_hit(db: AsyncSession, row: FindingsCache) -> None:
    """Bookkeeping so the saving is measurable rather than asserted."""
    row.hit_count += 1
    row.last_hit_at = _now()


async def store(
    db: AsyncSession, *, topic: str, scope: str, geography: str | None,
    payload: dict, no_news: bool, researched_from: str | None, cost: float,
) -> None:
    """
    Write through after a real research call.

    Upserts by key: a second customer researching the same topic after the
    first entry expired replaces it rather than accumulating duplicates (the
    UNIQUE constraint would reject the insert anyway).
    """
    topic_key, scope_key, geography_key = normalize(topic), normalize(scope), normalize(geography)
    existing = (await db.execute(
        select(FindingsCache).where(
            FindingsCache.topic_key == topic_key,
            FindingsCache.scope_key == scope_key,
            FindingsCache.geography_key == geography_key,
        )
    )).scalar_one_or_none()

    if existing is not None:
        existing.payload = payload
        existing.no_news = no_news
        existing.researched_from = researched_from
        existing.original_cost = cost
        existing.creado_en = _now()  # restarts the freshness window
        existing.hit_count = 0
        existing.last_hit_at = None
        return

    db.add(FindingsCache(
        topic_key=topic_key, scope_key=scope_key, geography_key=geography_key,
        payload=payload, no_news=no_news, researched_from=researched_from, original_cost=cost,
    ))
