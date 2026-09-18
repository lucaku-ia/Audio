"""
Episode Generator PRD (Juan, Draft v1) — HTTP surface for the pipeline in
app/services/episode_generator.py. See that module's docstring for what's
built vs. deferred.

POST /generation/run is the on-demand path: trigger now, run the shared
pipeline for the calling customer. The scheduled path (T-60 per customer's
own timezone, per the PRD) now runs separately via
app/services/scheduler.py, started from app.main's lifespan — it calls the
same run_generation() this route calls, just with path=EpisodePath.scheduled
and no HTTP request involved, per the PRD's "they share the pipeline and
differ only in trigger and latency budget."
"""
import uuid
from datetime import date, datetime

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from sqlalchemy import select

from app.api.deps import get_current_cliente
from app.db.session import get_db
from app.models.cliente import Cliente
from app.models.episode import Block, Episode
from app.models.generation_job import GenerationJob
from app.services.episode_generator import run_generation

router = APIRouter(prefix="/generation", tags=["Episode Generator"])


class JobOut(BaseModel):
    id: str
    fecha: date
    path: str
    status: str
    creado_en: datetime
    stages: list = []  # carries the {"error": ...} entry when status == "failed"


class BlockOut(BaseModel):
    request_id: str | None
    start_s: int
    end_s: int
    summary: str
    script: str
    sources: list
    had_more: bool
    # [{"word": str, "start_s": float, "end_s": float}, ...] relative to this
    # block's own audio (add start_s above for the episode-relative offset), or
    # null if this block's audio wasn't synthesized with ElevenLabs timestamps
    # (e.g. TTS not configured, or the block predates this field) — see
    # Block.word_timestamps' docstring in app/models/episode.py.
    word_timestamps: list | None = None


class EpisodeOut(BaseModel):
    id: str
    fecha: date
    headline: str | None
    language: str | None
    style: str | None
    voice_id: str | None
    duration_s: int | None
    audio_url: str | None
    had_more_any: bool
    published_at: datetime | None
    blocks: list[BlockOut]


def _job_out(job: GenerationJob) -> JobOut:
    return JobOut(
        id=str(job.id), fecha=job.fecha, path=job.path.value, status=job.status.value,
        creado_en=job.creado_en, stages=job.stages or [],
    )


@router.post("/run", response_model=JobOut)
async def run(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """
    Runs the pipeline synchronously and returns the finished job. This is
    slow (multiple sequential model calls with web search, one per active
    request) and will time out on a customer with many requests — a real
    deployment should queue this as a background job per PRD §5 (per-stage
    status streamed to Home), not run it inline in a request handler. Fine
    for manual testing at this stage.
    """
    job = await run_generation(db, cliente)
    return _job_out(job)


@router.get("/jobs/{job_id}", response_model=JobOut)
async def get_job(
    job_id: uuid.UUID,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    job = await db.get(GenerationJob, job_id)
    if not job or job.customer_id != cliente.id:
        raise HTTPException(404, "Job not found")
    return _job_out(job)


@router.get("/episodes/latest", response_model=EpisodeOut)
async def latest_episode(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """Not a Player/Home endpoint (neither exists yet) — exists so a generated
    episode's script and sources can actually be inspected without one."""
    result = await db.execute(
        select(Episode).where(Episode.customer_id == cliente.id).order_by(Episode.published_at.desc()).limit(1)
    )
    episode = result.scalar_one_or_none()
    if not episode:
        raise HTTPException(404, "No episode yet")

    blocks_result = await db.execute(select(Block).where(Block.episode_id == episode.id).order_by(Block.start_s))
    blocks = blocks_result.scalars().all()

    return EpisodeOut(
        id=str(episode.id), fecha=episode.fecha, headline=episode.headline, language=episode.language,
        style=episode.style, voice_id=episode.voice_id, duration_s=episode.duration_s,
        audio_url=episode.audio_url, had_more_any=episode.had_more_any, published_at=episode.published_at,
        blocks=[
            BlockOut(
                request_id=str(b.request_id) if b.request_id else None, start_s=b.start_s, end_s=b.end_s,
                summary=b.summary, script=b.script, sources=b.sources, had_more=b.had_more,
                word_timestamps=b.word_timestamps,
            )
            for b in blocks
        ],
    )
