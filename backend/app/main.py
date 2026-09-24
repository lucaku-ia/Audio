from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app.core.config import settings
from app.db.session import engine, Base, AsyncSessionLocal
from app.db.migraciones import ejecutar_migraciones
# Import every model so create_all() sees them
from app.models import (
    cliente, request, profile, episode, generation_job, instrumentation, onboarding, prompt_registry,
    source_catalogue,
)  # noqa: F401
from app.services.ai_platform import (
    STRUCTURE_REQUEST_SYSTEM, STRUCTURE_REQUEST_VERSION,
    RESEARCH_TOPIC_SYSTEM, RESEARCH_TOPIC_VERSION,
    WRITE_BLOCK_SYSTEM, WRITE_BLOCK_VERSION,
)
from app.services.prompt_registry import seed_prompt_registry
from app.services.source_catalogue import seed_source_catalogue
from app.api.routes import (
    auth, requests as requests_routes, profile as profile_routes,
    onboarding as onboarding_routes, generation as generation_routes, internal as internal_routes,
    search as search_routes, account as account_routes,
    home as home_routes, instrumentation as instrumentation_routes,
)
from app.services.scheduler import scheduler


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    await ejecutar_migraciones(engine)

    # Migrate the current hardcoded ai_platform.py prompt constants into the
    # prompt registry as the initial is_active version of each — idempotent,
    # a no-op on every boot after the first. See
    # app/services/prompt_registry.seed_prompt_registry for the guarantee
    # that this never overwrites a prompt a developer has since edited.
    async with AsyncSessionLocal() as db:
        await seed_prompt_registry(db, [
            ("structure_request", STRUCTURE_REQUEST_VERSION, STRUCTURE_REQUEST_SYSTEM),
            ("research_topic", RESEARCH_TOPIC_VERSION, RESEARCH_TOPIC_SYSTEM),
            ("write_block", WRITE_BLOCK_VERSION, WRITE_BLOCK_SYSTEM),
        ], created_by="seed:ai_platform.py")

        # Episode Generator PRD §5's source catalogue (app/models/source_catalogue.py)
        # — same insert-if-missing seeding pattern as seed_prompt_registry above,
        # loaded fresh from app/data/source_catalogue_seeds.json on every boot.
        await seed_source_catalogue(db)

    scheduler.start()  # Episode Generator PRD's scheduled path — see app.services.scheduler
    try:
        yield
    finally:
        await scheduler.stop()


app = FastAPI(
    title="Lucaku Audio — API",
    description="A personal research service delivered in audio. Technical foundation v0.1 (System Contracts).",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router, prefix="/api")
app.include_router(requests_routes.router, prefix="/api")
app.include_router(requests_routes.episodes_router, prefix="/api")
app.include_router(profile_routes.router, prefix="/api")
app.include_router(onboarding_routes.router, prefix="/api")
app.include_router(generation_routes.router, prefix="/api")
app.include_router(internal_routes.router, prefix="/api")
app.include_router(search_routes.router, prefix="/api")
app.include_router(account_routes.router, prefix="/api")
app.include_router(home_routes.router, prefix="/api")
app.include_router(instrumentation_routes.router, prefix="/api")

settings.MEDIA_DIR.mkdir(parents=True, exist_ok=True)  # StaticFiles needs the dir to exist at mount time
app.mount("/media", StaticFiles(directory=settings.MEDIA_DIR), name="media")


@app.get("/health")
async def health():
    return {"estado": "ok", "version": "0.1.0"}
