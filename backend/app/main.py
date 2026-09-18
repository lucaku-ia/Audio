from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app.core.config import settings
from app.db.session import engine, Base
from app.db.migraciones import ejecutar_migraciones
# Import every model so create_all() sees them
from app.models import cliente, request, profile, episode, generation_job, instrumentation, onboarding  # noqa: F401
from app.api.routes import (
    auth, requests as requests_routes, profile as profile_routes,
    onboarding as onboarding_routes, generation as generation_routes,
)
from app.services.scheduler import scheduler


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    await ejecutar_migraciones(engine)
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
app.include_router(profile_routes.router, prefix="/api")
app.include_router(onboarding_routes.router, prefix="/api")
app.include_router(generation_routes.router, prefix="/api")

settings.MEDIA_DIR.mkdir(parents=True, exist_ok=True)  # StaticFiles needs the dir to exist at mount time
app.mount("/media", StaticFiles(directory=settings.MEDIA_DIR), name="media")


@app.get("/health")
async def health():
    return {"estado": "ok", "version": "0.1.0"}
