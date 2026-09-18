"""
AI Platform PRD (Andrés + Juan, Draft v1) — prompt registry lookup + seed.

See app/models/prompt_registry.py for the scope note (what a prompt
registry is here, and what's explicitly deferred: the shared semantic
index, evals). This module is the runtime half: looking up the active
prompt for a name, and seeding the table from the hardcoded constants in
app/services/ai_platform.py on first boot.

Fallback-safety design (read before changing get_active_prompt):
get_active_prompt() is now on the hot path for every AI Platform call —
structure_request, research_and_write_block, and (once merged) refine.
If it raised on a missing active row — an empty table because seeding
never ran, or someone flipped is_active off without activating a
replacement — every one of those call paths would start throwing 500s
straight out of customer-facing endpoints (POST/PATCH /requests,
POST /generation/run). A registry that can take down request creation
because of an empty table is strictly worse than no registry. So instead:
on a lookup miss, get_active_prompt() logs a warning and returns a
PromptVersion-shaped fallback built from the hardcoded (name, version,
system_prompt) the caller passes in — the same constants that seed the
table in the first place. The caller's behavior is therefore identical to
before the registry existed; the registry can only ever add a path to a
*different* (deliberately activated) prompt, never remove the guarantee
that a call succeeds.
"""
import logging
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.prompt_registry import PromptVersion

logger = logging.getLogger(__name__)


async def get_active_prompt(
    db: AsyncSession,
    name: str,
    *,
    fallback_version: str,
    fallback_system_prompt: str,
) -> tuple[str, str]:
    """
    Returns (system_prompt, version) for the active row named `name`.

    Falls back to (fallback_system_prompt, fallback_version) — the
    hardcoded module constants in ai_platform.py — if no active row
    exists, logging a warning rather than raising. See this module's
    docstring for why: an empty or misconfigured registry must degrade to
    "exactly what ran before the registry existed," never break the
    caller.
    """
    result = await db.execute(
        select(PromptVersion).where(PromptVersion.name == name, PromptVersion.is_active.is_(True))
    )
    row = result.scalars().first()
    if row is None:
        logger.warning(
            "prompt_registry: no active PromptVersion for name=%r — falling back to hardcoded %s",
            name, fallback_version,
        )
        return fallback_system_prompt, fallback_version
    return row.system_prompt, row.version


async def seed_prompt_registry(db: AsyncSession, prompts: list[tuple[str, str, str]], created_by: str | None = None) -> None:
    """
    Idempotent: for each (name, version, system_prompt), inserts an
    is_active=True row only if `name` has no row at all yet. Called once
    from app/main.py's lifespan on every boot — cheap (one SELECT per
    name) and safe to run repeatedly; it never overwrites a row that
    already exists, including one a developer has since edited via a new
    version, so a redeploy can't silently revert an intentional prompt
    change back to the seed text.
    """
    for name, version, system_prompt in prompts:
        existing = await db.execute(select(PromptVersion.id).where(PromptVersion.name == name))
        if existing.scalars().first() is not None:
            continue
        db.add(PromptVersion(
            id=uuid.uuid4(),
            name=name,
            version=version,
            system_prompt=system_prompt,
            is_active=True,
            created_by=created_by,
        ))
    await db.commit()
