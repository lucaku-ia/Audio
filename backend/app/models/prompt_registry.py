"""
AI Platform PRD (Andrés + Juan, Draft v1) — prompt registry.

Scope note: this is the PRD's own §9 delivery-order item that comes right
after the call wrapper (app/services/ai_platform.py, already built). What
a "prompt registry" means here, narrowly: versioning, storage, and
retrieval of the PROMPT TEXT sent to Claude, so a prompt edit becomes a DB
row (new version, activate it) instead of a code deploy that nobody can
diff against history.

Explicitly NOT built here (separate future pieces, per the PRD):
- The shared semantic index for Home/Search novelty judgment — that needs
  an embeddings provider decision (a new external API credential or a
  local model) that hasn't been made. Nothing here touches embeddings or
  vector storage.
- Evals — running a prompt candidate against a historical "evaluation
  set" before activating it. This table's shape (one row per version, a
  clear is_active pointer) is meant to make that buildable later without
  a data-model change, but no eval-running logic exists yet.

New table (prompt_versions) — this rides in on Base.metadata.create_all()
in app/main.py's lifespan like every other model here; there is no
Alembic-style migration file in this repo (see app/db/migraciones.py,
which is a small idempotent ad-hoc runner, not a schema-migration tool),
so no migration entry is needed for a new table.
"""
import uuid
from datetime import datetime

from sqlalchemy import String, Boolean, DateTime, Text
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.session import Base


class PromptVersion(Base):
    """
    One version of one named prompt. `name` matches the `purpose`/`prompt`
    strings already passed to `_log_call` in app/services/ai_platform.py
    (e.g. "structure_request", "research_and_write_block") so AICall rows
    and registry rows line up by the same key.

    Exactly one row per `name` should have `is_active=True` at a time —
    that is the version callers actually get from get_active_prompt(). This
    is enforced at the application level (see
    app/services/prompt_registry.py's seed/activate helpers), not with a
    DB constraint, since a partial-unique-index-on-boolean is more
    machinery than this MVP needs; nothing here fans out to multiple
    writers that could race on it today.
    """
    __tablename__ = "prompt_versions"

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(100), index=True)
    version: Mapped[str] = mapped_column(String(50))
    system_prompt: Mapped[str] = mapped_column(Text)
    is_active: Mapped[bool] = mapped_column(Boolean, default=False, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
    created_by: Mapped[str | None] = mapped_column(String(200), nullable=True)  # free-text note; no real admin identity exists yet
