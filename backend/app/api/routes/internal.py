"""
Internal-only, read-only endpoints. No product PRD owns this; it exists
to give a developer visibility into cross-cutting internals (right now:
the AI Platform's prompt registry) without reading source code or a DB
console. Gated by require_internal_dashboard_key (app/api/deps.py) — see
that function's docstring for the auth pattern (shared secret header,
fail closed if unset).

GET /internal/prompts returns full prompt text, not a truncated preview.
Reasoning: these are internal ops prompts (system prompts we wrote for
Claude), not customer data — no PII, no customer content, nothing a
truncation would meaningfully protect. The whole point of the endpoint is
letting a developer see "what prompt is actually live," so truncating it
would defeat the purpose. If this ever grows into a public-facing surface
or the prompts start embedding anything sensitive, revisit this.

POST /internal/generate-shared-inventory: runs the Episode Generator's
shared-inventory pipeline (app/services/episode_generator.generate_shared_
episode) once per tag in app/data/shared_inventory_seeds.json — see that
seed file's own "_note" and episode_generator.py's "Built: shared
inventory" section for the full design. Manually triggered rather than
scheduled: the Episode Generator PRD's own open question ("how often are
shared samples refreshed?") is unresolved, so this stays a manually-
triggered ops tool for now, same scope as this file's other endpoint.

GET /internal/source-catalogue: read-only listing of the Episode
Generator PRD §5 source catalogue (app/models/source_catalogue.py,
seeded from app/data/source_catalogue_seeds.json). Exists so a developer
can inspect what's catalogued — and which entries are active, i.e.
actually eligible to have their license attached to a block's sources by
app/services/source_catalogue.attach_licenses — without a DB console.
Same auth gate as this file's other routes; see that module's docstring
for the honest limits of what this catalogue does and doesn't do.
"""
import json
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_internal_dashboard_key
from app.db.session import get_db
from app.models.prompt_registry import PromptVersion
from app.models.source_catalogue import SourceCatalogueEntry
from app.services.episode_generator import generate_shared_episode

router = APIRouter(prefix="/internal", tags=["Internal"], dependencies=[Depends(require_internal_dashboard_key)])

_SHARED_SEEDS_PATH = Path(__file__).resolve().parents[2] / "data" / "shared_inventory_seeds.json"


class PromptOut(BaseModel):
    name: str
    version: str
    system_prompt: str
    created_at: str
    created_by: str | None


@router.get("/prompts", response_model=list[PromptOut])
async def list_active_prompts(db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(PromptVersion).where(PromptVersion.is_active.is_(True)).order_by(PromptVersion.name)
    )
    rows = result.scalars().all()
    return [
        PromptOut(
            name=row.name,
            version=row.version,
            system_prompt=row.system_prompt,
            created_at=row.created_at.isoformat(),
            created_by=row.created_by,
        )
        for row in rows
    ]


class SharedInventoryResultOut(BaseModel):
    tag: str
    job_id: str
    status: str


@router.post("/generate-shared-inventory", response_model=list[SharedInventoryResultOut])
async def generate_shared_inventory(
    tag: str | None = Query(default=None, description="Only this tag — each one takes ~1 min (research + voice), "
                                                       "so running all of them in one call can outlive an HTTP timeout."),
    db: AsyncSession = Depends(get_db),
):
    """
    Runs (or, if already run today, returns) one shared-inventory
    GenerationJob per tag in shared_inventory_seeds.json. Loaded fresh from
    disk on every call rather than at import time, so editing the seed file
    takes effect without a restart.
    """
    seeds = json.loads(_SHARED_SEEDS_PATH.read_text(encoding="utf-8"))["shared_seeds"]
    if tag:
        seeds = [s for s in seeds if s["tag"] == tag]
        if not seeds:
            raise HTTPException(404, f"Unknown tag '{tag}'")
    results = []
    for seed in seeds:
        job = await generate_shared_episode(db, tag=seed["tag"], seed_request_text=seed["seed_request_text"])
        results.append(SharedInventoryResultOut(tag=seed["tag"], job_id=str(job.id), status=job.status.value))
    return results


class SourceCatalogueEntryOut(BaseModel):
    name: str
    domain: str
    access_type: str
    license_name: str
    language: str | None
    topics: list[str]
    active: bool
    notes: str | None


@router.get("/source-catalogue", response_model=list[SourceCatalogueEntryOut])
async def list_source_catalogue(db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(SourceCatalogueEntry).order_by(SourceCatalogueEntry.name))
    rows = result.scalars().all()
    return [
        SourceCatalogueEntryOut(
            name=row.name,
            domain=row.domain,
            access_type=row.access_type.value,
            license_name=row.license_name,
            language=row.language,
            topics=row.topics,
            active=row.active,
            notes=row.notes,
        )
        for row in rows
    ]
