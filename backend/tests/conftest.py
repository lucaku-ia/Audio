import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault(
    "DATABASE_URL",
    os.environ.get("TEST_DATABASE_URL", "postgresql+asyncpg://localhost:5432/lucaku_audio_test"),
)

import pytest_asyncio  # noqa: E402
from sqlalchemy import text  # noqa: E402
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker  # noqa: E402

from app.db.session import Base, DATABASE_URL  # noqa: E402
from app.models.source_catalogue import SourceCatalogueEntry  # noqa: E402,F401 (registers the table on Base.metadata)
# Registers the rest of System Contracts' tables on Base.metadata for the
# onboarding/generation/home test suites below (test_source_catalogue.py's
# own db_session fixture above only ever needed SourceCatalogueEntry).
from app.models.cliente import Cliente  # noqa: E402,F401
from app.models.profile import Profile  # noqa: E402,F401
from app.models.onboarding import OnboardingState  # noqa: E402,F401
from app.models.request import Request, RequestVersion  # noqa: E402,F401
from app.models.generation_job import GenerationJob, InventoryItem  # noqa: E402,F401
from app.models.episode import Episode, Block  # noqa: E402,F401
from app.models.instrumentation import Event, AICall  # noqa: E402,F401


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


# Tables the onboarding/generation/home defect-fix tests exercise end to end
# (clientes -> profiles/onboarding_states/requests -> generation_jobs/episodes
# -> blocks/inventory_items, plus events). Listed with CASCADE below so
# deletion order relative to their own FKs doesn't have to be hand-maintained
# here — see COLUMNAS_ESPERADAS/INDICES_ESPERADOS in app/db/migraciones.py for
# why this codebase already treats "list of things to keep in sync by hand"
# as an established, acceptable pattern for exactly this kind of bookkeeping.
_FULL_SESSION_TABLES = (
    "ai_calls", "events", "inventory_items", "blocks", "episodes",
    "generation_jobs", "request_versions", "requests", "onboarding_states",
    "profiles", "clientes",
)


@pytest_asyncio.fixture
async def full_db_session():
    """
    Like db_session above, but for tests that exercise real route handlers
    (onboarding.confirm/get_state, generation.run, home.home) end to end
    against real Postgres — those commit inside their own transactions
    (session.rollback() in a fixture teardown only undoes uncommitted work,
    which isn't what these handlers do), so this truncates every table this
    suite writes to, via CASCADE so FK order isn't this fixture's problem,
    rather than relying on rollback for isolation between tests.
    """
    engine = create_async_engine(DATABASE_URL, echo=False)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as session:
        yield session
        await session.rollback()

    async with engine.begin() as conn:
        await conn.execute(text(f"TRUNCATE TABLE {', '.join(_FULL_SESSION_TABLES)} RESTART IDENTITY CASCADE"))
    await engine.dispose()
