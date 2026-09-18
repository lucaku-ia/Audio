import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault(
    "DATABASE_URL",
    os.environ.get("TEST_DATABASE_URL", "postgresql+asyncpg://localhost:5432/lucaku_audio_test"),
)

import pytest_asyncio  # noqa: E402
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker  # noqa: E402

from app.db.session import Base, DATABASE_URL  # noqa: E402
from app.models.source_catalogue import SourceCatalogueEntry  # noqa: E402,F401 (registers the table on Base.metadata)


@pytest_asyncio.fixture
async def db_session():
    """
    Real local Postgres (per this repo's DATABASE_URL convention — see
    app/db/session.py), not a mock. Creates just the tables this test suite
    touches, truncates source_catalogue_entries around each test so tests
    don't see each other's rows, and disposes the engine at the end.
    """
    engine = create_async_engine(DATABASE_URL, echo=False)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as session:
        yield session
        await session.rollback()

    async with engine.begin() as conn:
        await conn.execute(SourceCatalogueEntry.__table__.delete())
    await engine.dispose()
