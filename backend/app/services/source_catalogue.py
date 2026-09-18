"""
Episode Generator PRD §5's source catalogue — seeding and license
resolution. See app/models/source_catalogue.py's module docstring for the
full scope note, especially the "this labels, it does not restrict
web_search" caveat repeated once more at attach_licenses below since
that's the function most likely to be misread as doing more than it does.
"""
import json
import logging
import uuid
from pathlib import Path
from urllib.parse import urlparse

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.source_catalogue import SourceCatalogueEntry

logger = logging.getLogger(__name__)

_SEEDS_PATH = Path(__file__).resolve().parents[1] / "data" / "source_catalogue_seeds.json"


def _normalize_domain(raw: str) -> str:
    """Lowercase, no scheme, no leading 'www.', no path/port — the canonical
    form both seed rows and attach_licenses' url-derived domains are
    compared in."""
    domain = raw.strip().lower()
    if "://" in domain:
        domain = urlparse(domain).netloc or domain
    domain = domain.split("@")[-1]  # strip userinfo, if any
    domain = domain.split(":")[0]   # strip port, if any
    if domain.startswith("www."):
        domain = domain[4:]
    return domain.rstrip(".")


def _domain_from_url(url: str) -> str | None:
    try:
        netloc = urlparse(url).netloc
    except Exception:
        return None
    if not netloc:
        return None
    return _normalize_domain(netloc) or None


async def seed_source_catalogue(db: AsyncSession) -> None:
    """
    Idempotent, insert-if-domain-missing (same shape as
    app/services/prompt_registry.seed_prompt_registry): loads
    app/data/source_catalogue_seeds.json fresh from disk on every boot and
    inserts any `domain` not already present, but never touches a row that
    already exists — so a developer (or a future admin UI) toggling
    `active` off on a source, or editing its license_name, survives
    redeploys instead of being silently reset by the seed file.

    Uses a single `INSERT ... ON CONFLICT (domain) DO NOTHING` statement
    rather than a per-row check-then-insert: the latter has a race window
    between the SELECT and the INSERT, so two callers seeding concurrently
    (e.g. multiple app workers/replicas booting at once, or a rolling
    deploy) can both decide a domain is missing and both try to insert it,
    crashing one of them with an uncaught IntegrityError on the `domain`
    unique constraint. ON CONFLICT DO NOTHING pushes the missing-check down
    into Postgres itself, atomically, so concurrent callers can't race.

    Called once from app/main.py's lifespan, same place/pattern as
    seed_prompt_registry.
    """
    seeds = json.loads(_SEEDS_PATH.read_text(encoding="utf-8"))["sources"]
    if not seeds:
        return

    rows = [
        {
            "id": uuid.uuid4(),
            "name": seed["name"],
            "domain": _normalize_domain(seed["domain"]),
            "access_type": seed["access_type"],
            "license_name": seed["license_name"],
            "language": seed.get("language"),
            "topics": seed.get("topics", []),
            "active": seed.get("active", True),
            "notes": seed.get("notes"),
        }
        for seed in seeds
    ]

    stmt = pg_insert(SourceCatalogueEntry).values(rows)
    stmt = stmt.on_conflict_do_nothing(index_elements=["domain"])
    await db.execute(stmt)
    await db.commit()


async def attach_licenses(db: AsyncSession, sources: list[dict]) -> list[dict]:
    """
    Best-effort: for each source dict (as returned by
    ai_platform._parse_block_result — {"url", "title", "publisher"}),
    matches its URL's domain against the active catalogue and returns a new
    list of dicts with a "license" key added — the matching entry's
    license_name, or None (explicit, never fabricated) if the domain isn't
    in the catalogue or doesn't match any entry.

    Domain match is exact-or-subdomain (e.g. "efts.sec.gov" matches a
    catalogue entry for "sec.gov"), not a broader fuzzy match, so a
    coincidentally similar but unrelated domain is never mislabeled.

    This does NOT mean the source was actually restricted to catalogued
    domains — Claude's web_search tool call in
    app/services/ai_platform.research_and_write_block is a general
    open-web search with no API-level allowlist parameter this codebase
    uses. A source with license=None here is simply "not one of our
    catalogued licensed/API sources" — it may still be a perfectly good,
    freely-citable source; it's just not one this table can vouch the
    licensing status of.
    """
    if not sources:
        return sources

    result = await db.execute(
        select(SourceCatalogueEntry.domain, SourceCatalogueEntry.license_name)
        .where(SourceCatalogueEntry.active.is_(True))
    )
    catalogue = result.all()  # list[(domain, license_name)]

    out = []
    for source in sources:
        domain = _domain_from_url(source.get("url", "") or "")
        license_name = None
        if domain:
            for cat_domain, cat_license in catalogue:
                if domain == cat_domain or domain.endswith("." + cat_domain):
                    license_name = cat_license
                    break
        out.append({**source, "license": license_name})
    return out
