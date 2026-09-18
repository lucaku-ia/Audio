"""
Real-DB unit tests for app/services/source_catalogue.py's license-matching
logic — the piece research_and_write_block relies on (via attach_licenses)
to label Block.sources with a license. Uses actual domains from
app/data/source_catalogue_seeds.json (sec.gov, worldbank.org) rather than
invented ones, so this also doubles as a smoke test that those seed rows
are shaped the way attach_licenses expects.

Run with (from backend/): `TEST_DATABASE_URL=postgresql+asyncpg://<user>@localhost:5432/lucaku_audio_test pytest tests/`
"""
import json
import uuid
from pathlib import Path

import pytest

from app.models.source_catalogue import SourceCatalogueEntry
from app.services.source_catalogue import _domain_from_url, _normalize_domain, attach_licenses

_SEEDS = json.loads(
    (Path(__file__).resolve().parents[1] / "app" / "data" / "source_catalogue_seeds.json").read_text()
)["sources"]


def _seed_row(domain: str) -> dict:
    return next(s for s in _SEEDS if s["domain"] == domain)


# ── Pure functions — no DB needed ────────────────────────────────────────────

def test_normalize_domain_strips_scheme_www_port_path():
    assert _normalize_domain("https://www.SEC.gov:443/path?q=1") == "sec.gov"
    assert _normalize_domain("sec.gov") == "sec.gov"
    assert _normalize_domain("WWW.Worldbank.org.") == "worldbank.org"


def test_domain_from_url_handles_subdomains_and_bad_input():
    assert _domain_from_url("https://efts.sec.gov/LATEST/search-index?q=x") == "efts.sec.gov"
    assert _domain_from_url("not a url") is None
    assert _domain_from_url("") is None


# ── attach_licenses — real Postgres, real seed domains ───────────────────────

@pytest.mark.asyncio
async def test_attach_licenses_exact_domain_match(db_session):
    seed = _seed_row("sec.gov")
    db_session.add(SourceCatalogueEntry(
        id=uuid.uuid4(), name=seed["name"], domain="sec.gov", access_type=seed["access_type"],
        license_name=seed["license_name"], language=seed["language"], topics=seed["topics"], active=True,
    ))

    sources = [{"url": "https://www.sec.gov/cgi-bin/browse-edgar", "title": "EDGAR filing", "publisher": "SEC"}]
    result = await attach_licenses(db_session, sources)

    assert len(result) == 1
    assert result[0]["license"] == seed["license_name"]
    # original keys preserved, not just replaced
    assert result[0]["title"] == "EDGAR filing"
    assert result[0]["publisher"] == "SEC"


@pytest.mark.asyncio
async def test_attach_licenses_subdomain_matches_registered_domain(db_session):
    seed = _seed_row("sec.gov")
    db_session.add(SourceCatalogueEntry(
        id=uuid.uuid4(), name=seed["name"], domain="sec.gov", access_type=seed["access_type"],
        license_name=seed["license_name"], language=seed["language"], topics=seed["topics"], active=True,
    ))

    # efts.sec.gov is a real SEC EDGAR full-text-search subdomain, not the bare
    # registered domain — attach_licenses must still match it against "sec.gov".
    sources = [{"url": "https://efts.sec.gov/LATEST/search-index?q=acme", "title": "t", "publisher": "SEC"}]
    result = await attach_licenses(db_session, sources)

    assert result[0]["license"] == seed["license_name"]


@pytest.mark.asyncio
async def test_attach_licenses_no_match_is_explicit_none_not_fabricated(db_session):
    seed = _seed_row("worldbank.org")
    db_session.add(SourceCatalogueEntry(
        id=uuid.uuid4(), name=seed["name"], domain="worldbank.org", access_type=seed["access_type"],
        license_name=seed["license_name"], language=seed["language"], topics=seed["topics"], active=True,
    ))

    # A source from a real domain that is genuinely not in the catalogue.
    sources = [{"url": "https://www.some-random-blog.example/post", "title": "t", "publisher": "p"}]
    result = await attach_licenses(db_session, sources)

    assert result[0]["license"] is None


@pytest.mark.asyncio
async def test_attach_licenses_ignores_inactive_catalogue_entries(db_session):
    seed = _seed_row("newsapi.org")
    assert seed["active"] is False  # sanity check on the seed data itself
    db_session.add(SourceCatalogueEntry(
        id=uuid.uuid4(), name=seed["name"], domain="newsapi.org", access_type=seed["access_type"],
        license_name=seed["license_name"], language=seed["language"], topics=seed["topics"], active=False,
    ))

    sources = [{"url": "https://newsapi.org/v2/everything", "title": "t", "publisher": "NewsAPI"}]
    result = await attach_licenses(db_session, sources)

    # Inactive entries must not be used to label a source with a license we
    # haven't actually secured for production use — see the seed file's note
    # on newsapi.org's free-tier terms.
    assert result[0]["license"] is None


@pytest.mark.asyncio
async def test_attach_licenses_empty_list_returns_empty_list(db_session):
    assert await attach_licenses(db_session, []) == []


@pytest.mark.asyncio
async def test_attach_licenses_mixed_batch_multiple_sources(db_session):
    sec = _seed_row("sec.gov")
    wb = _seed_row("worldbank.org")
    db_session.add_all([
        SourceCatalogueEntry(
            id=uuid.uuid4(), name=sec["name"], domain="sec.gov", access_type=sec["access_type"],
            license_name=sec["license_name"], language=sec["language"], topics=sec["topics"], active=True,
        ),
        SourceCatalogueEntry(
            id=uuid.uuid4(), name=wb["name"], domain="worldbank.org", access_type=wb["access_type"],
            license_name=wb["license_name"], language=wb["language"], topics=wb["topics"], active=True,
        ),
    ])

    sources = [
        {"url": "https://www.sec.gov/x", "title": "a", "publisher": "SEC"},
        {"url": "https://api.worldbank.org/v2/x", "title": "b", "publisher": "World Bank"},
        {"url": "https://unrelated.example/x", "title": "c", "publisher": "Unrelated"},
    ]
    result = await attach_licenses(db_session, sources)

    assert result[0]["license"] == sec["license_name"]
    assert result[1]["license"] == wb["license_name"]
    assert result[2]["license"] is None
