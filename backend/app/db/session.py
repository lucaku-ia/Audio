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
# This codebase stores every timestamp as naive datetime.utcnow() into columns
# declared DateTime(timezone=True). asyncpg encodes a naive datetime for a
# timestamptz parameter by assuming it is in the PROCESS's local timezone
# (Python's naive .astimezone() does exactly that), so on a machine running
# UTC-8 a value meaning 17:20 UTC was written as 01:20 UTC the next day —
# eight hours in the future. Every age computed against utcnow() then came out
# negative, and anything time-based silently inverted.
#
# Measured, not assumed:
#     sent naive : 2026-11-11 17:20:48
#     echoed     : 2026-11-12 01:20:48+00:00    (TZ unset, machine on Pacific)
#     echoed     : 2026-11-11 17:20:48+00:00    (TZ=UTC)
#
# Note what does NOT fix it: setting the DB session's timezone. That conversion
# happens client-side in asyncpg, before Postgres sees anything, so the server
# setting below is powerless over writes. It was the first fix attempted here
# and it failed this module's own round-trip test.
#
# Why production has not visibly broken: Railway's containers already run UTC,
# so naive-local happens to equal UTC there. The convention has been correct by
# luck, not by construction — it would break on any host configured otherwise,
# and it has been breaking in local development all along.
#
# The genuinely correct fix is timezone-aware UTC at all 31 utcnow() call
# sites. That is a larger, riskier sweep and is listed in the README's next
# steps; this makes the existing convention correct everywhere in one place
# meanwhile. app/services/findings_store.py already uses aware UTC of its own
# and stays correct regardless of this setting.
os.environ["TZ"] = "UTC"
time.tzset()

# The DB session's timezone still matters for SERVER-side date arithmetic —
# func.date() on a timestamptz column buckets per this setting, which is what
# instrumentation's cost-summary and event-count day-bucketing rely on (see the
# caveat recorded in app/api/routes/instrumentation.py).
ENGINE_CONNECT_ARGS = {"server_settings": {"timezone": "UTC"}}

# Pin the DB session's timezone to UTC.
#
# This codebase standardizes on naive datetime.utcnow() for every stored
# timestamp, while the columns themselves are DateTime(timezone=True). Postgres
# interprets a naive value written to a timestamptz column as the SESSION's
# timezone and converts it to UTC — so that convention is only correct when the
# session timezone already IS UTC. It is not, by default: this machine's
# Postgres reports America/Los_Angeles, which stored a row stamped "now" eight
# hours in the FUTURE and made every age computed against utcnow() negative.
#
# Two places in this repo already carry comments warning about exactly this
# (episode_generator's check_late_jobs, and instrumentation's day-bucketing
# caveat). Rather than rewrite 31 call sites and hope none are missed, one line
# makes the existing convention correct by construction, everywhere, and makes
# local behaviour match production instead of differing by the developer's
# machine timezone.
#
# Anything comparing a stored time to utcnow() depends on this: the late-job
# watchdog, token expiry, the login rate limiter, cost day-bucketing and the
# findings cache's freshness windows. The findings store additionally uses
# aware UTC of its own, so it stays correct even if this setting is ever lost.
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
