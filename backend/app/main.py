from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.db.session import engine, Base
# Importar todos los modelos para que create_all() los vea
from app.models import cliente, request, profile, episode, generation_job, instrumentation  # noqa: F401
from app.api.routes import auth


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield


app = FastAPI(
    title="Lucaku Audio — API",
    description="Servicio de investigación personal entregado en audio. Fundación técnica v0.1 (System Contracts).",
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


@app.get("/health")
async def health():
    return {"estado": "ok", "version": "0.1.0"}
