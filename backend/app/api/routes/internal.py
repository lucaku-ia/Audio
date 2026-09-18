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
"""
from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_internal_dashboard_key
from app.db.session import get_db
from app.models.prompt_registry import PromptVersion

router = APIRouter(prefix="/internal", tags=["Internal"], dependencies=[Depends(require_internal_dashboard_key)])


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
