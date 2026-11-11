import os
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
engine = create_async_engine(
    DATABASE_URL,
    echo=False,
    pool_pre_ping=True,
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
