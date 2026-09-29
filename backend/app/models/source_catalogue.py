"""
Episode Generator PRD §5 ("Source catalogue. Config file: source, API,
license, language, topics. Only licensed or API sources. No scraping.")
and §4's Search & AI row ("Every block stores its sources (url, title,
publisher, license)...").

Scope note — what this table is and is NOT (read before assuming it
restricts search): this is a provenance/licensing *record*, not a search
allowlist. The Generator's actual research call
(app/services/ai_platform.research_topic) uses Claude's
server-side `web_search` tool, which is a general open-web tool — the
`anthropic` SDK's `web_search_20260209` tool type, as used in this
codebase, has no "restrict to these domains" parameter that would let a
caller scope it to a fixed catalogue. So this table cannot make Claude
only search these domains. What it CAN do: let app/services/
source_catalogue.py best-effort match a returned source's domain against
this curated list and attach the matching license_name to that source
(see Block.sources and app/services/source_catalogue.attach_licenses) —
a provenance/labelling layer on top of search that is already API-based
and not scraping, not a domain-restriction mechanism. See
app/services/episode_generator.py's module docstring, "Source catalogue"
bullet, for the same caveat from the pipeline's point of view.

New table (source_catalogue_entries) — like app/models/prompt_registry.py's
PromptVersion, this rides in on Base.metadata.create_all() in
app/main.py's lifespan; there is no Alembic-style migration tool in this
repo (see app/db/migraciones.py's own docstring), so a brand-new table
with all its constraints declared here needs no entry in migraciones.py —
create_all() creates the table, its unique index and its default values
in one shot the first time this model exists. (migraciones.py's own
COLUMNAS_ESPERADAS/INDICES_ESPERADOS lists only exist to backfill a column
or index onto a table Postgres *already has* without it — not applicable
to a table that doesn't exist yet anywhere this migrates from.)

Seeded from app/data/source_catalogue_seeds.json by
app/services/source_catalogue.seed_source_catalogue, called once per boot
from app/main.py's lifespan (same pattern as seed_prompt_registry) —
insert-if-domain-missing, never overwrites/reactivates a row that already
exists, so a developer or (future) admin UI flipping `active` off on a
source survives redeploys instead of being silently re-seeded back on.
"""
import enum
import uuid
from datetime import datetime

from sqlalchemy import String, Boolean, DateTime, JSON, Enum as SAEnum
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.session import Base


class SourceAccessType(str, enum.Enum):
    api = "api"                    # has a documented API (may still require a paid/commercial tier for our use)
    license = "license"            # requires a negotiated/commercial content license, not a self-serve API
    api_and_license = "api_and_license"  # both: an API gated behind a paid license agreement


class SourceCatalogueEntry(Base):
    """
    One row per catalogued source. `domain` is the matching key used by
    app/services/source_catalogue.attach_licenses to label a web_search
    result's source with a license, so it is stored normalized (lowercase,
    no scheme, no leading "www.", no path) and unique — see
    source_catalogue._normalize_domain.
    """
    __tablename__ = "source_catalogue_entries"

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(200))
    domain: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    access_type: Mapped[SourceAccessType] = mapped_column(SAEnum(SourceAccessType, name="source_access_type"))
    license_name: Mapped[str] = mapped_column(String(300))  # e.g. "US Government Work (public domain)", "AP Content API license"
    language: Mapped[str | None] = mapped_column(String(10), nullable=True)  # ISO 639-1, null = multilingual/not language-specific
    topics: Mapped[list] = mapped_column(JSON, default=lambda: [])  # e.g. ["markets", "technology"] — matches onboarding_seeds.json tag vocabulary where applicable, but isn't restricted to it
    active: Mapped[bool] = mapped_column(Boolean, default=True, index=True)
    notes: Mapped[str | None] = mapped_column(String(1000), nullable=True)  # why this is genuinely licensed/API-based — audit trail, not customer-facing
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
