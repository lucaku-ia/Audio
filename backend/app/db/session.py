import os
import time
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase


def _normalizar_database_url(url: str) -> str:
    """Ensures the URL uses the asyncpg driver (Railway/Heroku hand back postgres:// or postgresql:// with no driver)."""
    if url.startswith("postgres://"):
        url = url.replace("postgres://", "postgresql+asyncpg://", 1)
    elif url.startswith("postgresql://") and "+asyncpg" not in url:
        url = url.replace("postgresql://", "postgresql+asyncpg://", 1)
    return url


DATABASE_URL = _normalizar_database_url(
    os.getenv("DATABASE_URL", "postgresql+asyncpg://lucaku:lucaku@localhost:5432/lucaku_audio")
)

# Pool sizing. SQLAlchemy's defaults are pool_size=5, max_overflow=10 — 15
# connections — which are fine for handlers that borrow a connection for
# milliseconds. They are not fine here: episode generation currently runs
# INLINE in the request handler and holds its connection for the whole run
# (~40s of research, writing and synthesis). Fifteen concurrent generations
# exhaust the pool, and every other request — including the health check and
# the login route — then blocks for pool_timeout before failing. Production
# logs showed exactly that: "QueuePool limit of size 5 overflow 10 reached".
#
# These numbers are a stopgap sized to Railway's Postgres connection ceiling,
# not a fix. The real fix is to get generation off the request path onto a
# worker, after which the pool can go back down. Until then: a bigger pool, a
# SHORT pool_timeout so a saturated pool fails fast and visibly instead of
# hanging every caller for 30s, and pool_recycle to stay under the proxy's
# idle-connection cutoff.

# Force this PROCESS to UTC, before any connection is made.
#
# This is no longer the fix for the timestamp bug — it was, and the record of
# why it was not enough is worth keeping. asyncpg encodes a NAIVE datetime
# bound to a timestamptz parameter by assuming the process's local timezone
# (Python's naive .astimezone() does exactly that), so on a machine running
# UTC-8 a value meaning 17:20 UTC was written as 01:20 UTC the next day:
#
#     sent naive : 2026-11-11 17:20:48
#     echoed     : 2026-11-12 01:20:48+00:00    (TZ unset, machine on Pacific)
#     echoed     : 2026-11-11 17:20:48+00:00    (TZ=UTC)
#
# Pinning the process to UTC made the naive values accidentally correct, which
# is containment, not a cure. It held only inside this process, said nothing
# about any other consumer of the same database, and the hasattr guard below
# exists because time.tzset() does not exist on Windows at all — a correctness
# property that evaporates on an unsupported platform is not a correctness
# property. Every timestamp this backend writes is now timezone-aware UTC
# (app/core/clock.py), which removes the ambiguity at the source instead.
#
# Kept anyway, as belt and braces, for two reasons that are still real:
#
#   date.today() is LOCAL. home.py and episode_generator both derive "today"
#   from it to pick an episode's `fecha`, and nothing about aware datetimes
#   touches that call. Without this pin, a developer west of Greenwich gets a
#   different day than production for several hours each evening.
#
#   Any naive datetime that slips back in — a dependency's default, a row
#   written by a script, a line that gets past the guard test — lands on UTC
#   rather than on whatever the host happens to be set to. That turns a silent
#   multi-hour shift back into a no-op.
#
# What it must NOT be mistaken for again: a reason to write naive timestamps.
# The conversion happens client-side, in asyncpg, before Postgres is involved;
# a process-wide setting is the wrong altitude for a per-value property.
os.environ["TZ"] = "UTC"
if hasattr(time, "tzset"):  # Unix only; absent on Windows, where this would
    time.tzset()            # raise AttributeError at import and kill the app

# The DB session's timezone is a separate matter and is genuinely load-bearing:
# func.date() on a timestamptz column buckets per this setting, server-side,
# which is what instrumentation's cost-summary and event-count day-bucketing
# rely on to line up with the UTC cutoffs in the same queries. Aware timestamps
# do not help there — the bucketing decision is made by Postgres, not by us.
# See the caveat recorded in app/api/routes/instrumentation.py.
ENGINE_CONNECT_ARGS = {"server_settings": {"timezone": "UTC"}}

engine = create_async_engine(
    DATABASE_URL,
    echo=False,
    pool_pre_ping=True,
    connect_args=ENGINE_CONNECT_ARGS,
    pool_size=int(os.getenv("DB_POOL_SIZE", "20")),
    max_overflow=int(os.getenv("DB_MAX_OVERFLOW", "10")),
    pool_timeout=float(os.getenv("DB_POOL_TIMEOUT", "10")),
    pool_recycle=int(os.getenv("DB_POOL_RECYCLE", "1800")),
)
AsyncSessionLocal = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


async def get_db():
    async with AsyncSessionLocal() as session:
        try:
            yield session
        finally:
            await session.close()
