"""
Search & AI PRD (Juan, Draft v1) — P0 slice only: History + Keyword search.

Built:
- GET /search/history — chronological read of the calling customer's own
  Episodes, newest first, with "No news" entries synthesized for days that
  produced an empty GenerationJob (System Contracts: no Episode row exists
  for those days by design — the Generator's "never fill" tenet). Direct
  read, no AI involved, per the PRD's own engineering notes.
- GET /search/query — keyword (not semantic) full-text search over
  Episode.headline, Block.summary and Request.raw_text, scoped to the
  calling customer, grouped by episode. PostgreSQL full-text search
  (to_tsvector/plainto_tsquery), not a vector/semantic index.

Explicitly NOT built — the natural-language question-answering feature
(chat-style "answer_from_history"): the PRD itself marks it P1 ("ships soon
after" keyword search) and its own engineering notes draw the line between
"keyword search... not the semantic index" (this file) and the AI-answering
feature, which needs the AI Platform's shared semantic index. That index
does not exist yet (see app/services/ai_platform.py's scope note and the
README's AI Platform section — only structure_request and
research_and_write_block are built). Building even a stub answer endpoint
without that index would violate the PRD's own tenet, "answers come only
from what exists" — there would be nothing real to ground an answer in, so
it is skipped entirely rather than half-built. Pick this up once the AI
Platform's shared index ships.

Full-text search config: 'simple' (no stemming/stopwords), not 'english' or
'spanish'. Customers can be in either language (Cliente.idioma / a
Profile's Language enum is 'es' or 'en'), and content on a single account
can mix both (e.g. an English headline over a Spanish request). Picking one
language config would silently under-match the other; running a
language-aware query would need a per-row language tag that doesn't exist
today. 'simple' folds case and tokenizes without a language-specific
dictionary, which is a deliberate precision/recall trade-off for the pilot:
worse recall than real stemming (a search for "research" won't match
"researching"), but correct regardless of which language a row happens to
be in. Revisit once content actually gets tagged with a language.

Indexing: a GIN index per searched column, over the exact
`to_tsvector('simple', ...)` expression used in these queries, added via the
INDICES_ESPERADOS pattern in app/db/migraciones.py — see that module's
docstring for why (create_all() never backfills an index onto a table
Railway's production Postgres already has).

Pagination: no other list endpoint in this codebase paginates yet
(app/api/routes/requests.py's `listar_requests` returns the full list), so
there's no existing convention to follow. Plain offset/limit query params
were chosen over a cursor for simplicity — a customer's history is one
entry per calendar day, so even a customer of several years still has a
small, boundable row count for a single pilot account.
"""
import time
import uuid
from datetime import date, datetime

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_cliente
from app.db.session import get_db
from app.models.cliente import Cliente
from app.models.episode import Episode
from app.models.generation_job import GenerationJob, JobStatus

router = APIRouter(prefix="/search", tags=["Search & AI"])

TS_CONFIG = "simple"  # see module docstring for why not 'english'/'spanish'


# ── History ──────────────────────────────────────────────────────────────────

class HistoryEntryOut(BaseModel):
    episode_id: str | None
    fecha: date
    headline: str
    duration_s: int | None
    style: str | None
    path: str | None  # None for a synthesized "No news" entry
    state: str  # "ready" | "voicing" | "empty"


class HistoryOut(BaseModel):
    items: list[HistoryEntryOut]
    offset: int
    limit: int
    total: int
    has_more: bool


@router.get("/history", response_model=HistoryOut)
async def history(
    offset: int = Query(default=0, ge=0),
    limit: int = Query(default=20, ge=1, le=100),
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """Chronological list of every Episode for the customer, across both paths
    (on_demand and scheduled), newest first — PRD: "date chip, headline,
    duration, state". Empty days (a GenerationJob that finished with
    status == empty and produced no Episode row) are merged in as "No news"
    entries; a real Episode always wins over a synthesized one on the same
    date. Merged and paginated in Python rather than in SQL — see module
    docstring on why that's an acceptable trade-off at this scale.
    """
    episodes_result = await db.execute(
        select(Episode)
        .where(Episode.customer_id == cliente.id)
        .order_by(Episode.fecha.desc(), Episode.published_at.desc())
    )
    episodes = episodes_result.scalars().all()
    covered_dates = {ep.fecha for ep in episodes}

    empty_result = await db.execute(
        select(GenerationJob.fecha)
        .where(GenerationJob.customer_id == cliente.id, GenerationJob.status == JobStatus.empty)
        .distinct()
    )
    empty_dates = {row[0] for row in empty_result.all() if row[0] not in covered_dates}

    entries: list[tuple[date, HistoryEntryOut]] = []
    for ep in episodes:
        state = "ready" if ep.audio_url else "voicing"
        entries.append((ep.fecha, HistoryEntryOut(
            episode_id=str(ep.id), fecha=ep.fecha, headline=ep.headline or "Untitled episode",
            duration_s=ep.duration_s, style=ep.style, path=ep.path.value, state=state,
        )))
    for d in empty_dates:
        entries.append((d, HistoryEntryOut(
            episode_id=None, fecha=d, headline="No news", duration_s=None, style=None,
            path=None, state="empty",
        )))

    # Stable sort on fecha only: episodes for the same date arrive from SQL
    # already ordered by published_at desc, and no synthesized entry shares a
    # date with a real one (covered_dates was subtracted above), so a stable
    # sort preserves the right order without needing a second tie-break key
    # (published_at is tz-aware and not comparable against a naive sentinel).
    entries.sort(key=lambda pair: pair[0], reverse=True)

    total = len(entries)
    page = entries[offset: offset + limit]
    return HistoryOut(
        items=[item for _, item in page], offset=offset, limit=limit,
        total=total, has_more=offset + limit < total,
    )


# ── Keyword search ───────────────────────────────────────────────────────────

class MatchedBlockOut(BaseModel):
    block_id: str
    start_s: int
    snippet: str


class RequestTextMatchOut(BaseModel):
    request_id: str
    block_id: str | None
    snippet: str


class EpisodeMatchOut(BaseModel):
    episode_id: str
    fecha: date
    headline: str | None
    path: str
    headline_match: bool
    headline_snippet: str | None = None
    matched_blocks: list[MatchedBlockOut] = []
    matched_request_texts: list[RequestTextMatchOut] = []


class UnmatchedRequestOut(BaseModel):
    """A Request whose raw_text matched but that hasn't produced any Block yet
    (no episode to attach the hit to) — e.g. a brand-new standing request."""
    request_id: str
    snippet: str
    status: str


class SearchOut(BaseModel):
    query: str
    took_ms: float
    episodes: list[EpisodeMatchOut]
    unmatched_requests: list[UnmatchedRequestOut]


_SNIPPET_OPTS = "StartSel=**, StopSel=**, MaxWords=24, MinWords=6, HighlightAll=false"

_SQL_HEADLINES = text(f"""
    SELECT id, fecha, headline, path,
           ts_headline('{TS_CONFIG}', coalesce(headline, ''), plainto_tsquery('{TS_CONFIG}', :q), :opts) AS snippet
    FROM episodes
    WHERE customer_id = :customer_id
      AND to_tsvector('{TS_CONFIG}', coalesce(headline, '')) @@ plainto_tsquery('{TS_CONFIG}', :q)
    ORDER BY fecha DESC
    LIMIT :limit
""")

_SQL_BLOCKS = text(f"""
    SELECT b.id AS block_id, b.episode_id, b.start_s,
           e.fecha, e.headline, e.path,
           ts_headline('{TS_CONFIG}', b.summary, plainto_tsquery('{TS_CONFIG}', :q), :opts) AS snippet
    FROM blocks b
    JOIN episodes e ON e.id = b.episode_id
    WHERE e.customer_id = :customer_id
      AND to_tsvector('{TS_CONFIG}', coalesce(b.summary, '')) @@ plainto_tsquery('{TS_CONFIG}', :q)
    ORDER BY e.fecha DESC
    LIMIT :limit
""")

_SQL_REQUESTS = text(f"""
    SELECT r.id AS request_id, r.status,
           ts_headline('{TS_CONFIG}', r.raw_text, plainto_tsquery('{TS_CONFIG}', :q), :opts) AS snippet,
           b.id AS block_id, b.episode_id, e.fecha AS episode_fecha, e.headline AS episode_headline,
           e.path AS episode_path
    FROM requests r
    LEFT JOIN blocks b ON b.request_id = r.id
    LEFT JOIN episodes e ON e.id = b.episode_id
    WHERE r.customer_id = :customer_id
      AND to_tsvector('{TS_CONFIG}', r.raw_text) @@ plainto_tsquery('{TS_CONFIG}', :q)
    ORDER BY r.creado_en DESC
    LIMIT :limit
""")


def _get_or_create_episode_entry(
    episodes_map: dict[uuid.UUID, EpisodeMatchOut], episode_id, fecha, headline, path
) -> EpisodeMatchOut:
    entry = episodes_map.get(episode_id)
    if entry is None:
        entry = EpisodeMatchOut(
            episode_id=str(episode_id), fecha=fecha, headline=headline, path=path,
            headline_match=False,
        )
        episodes_map[episode_id] = entry
    return entry


@router.get("/query", response_model=SearchOut)
async def query(
    q: str = Query(min_length=1, max_length=200),
    limit: int = Query(default=20, ge=1, le=50),
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """Keyword search over Episode.headline, Block.summary and
    Request.raw_text, scoped to the calling customer only, results grouped
    by episode with the matching block(s) noted per the PRD. All matching
    happens in SQL via the GIN-indexed to_tsvector expressions (see module
    docstring) — nothing is fetched into Python and grepped.
    """
    started = time.perf_counter()
    params = {"q": q, "customer_id": cliente.id, "limit": limit, "opts": _SNIPPET_OPTS}

    headline_rows = (await db.execute(_SQL_HEADLINES, params)).mappings().all()
    block_rows = (await db.execute(_SQL_BLOCKS, params)).mappings().all()
    request_rows = (await db.execute(_SQL_REQUESTS, params)).mappings().all()

    episodes_map: dict[uuid.UUID, EpisodeMatchOut] = {}

    for row in headline_rows:
        entry = _get_or_create_episode_entry(episodes_map, row["id"], row["fecha"], row["headline"], row["path"])
        entry.headline_match = True
        entry.headline_snippet = row["snippet"]

    for row in block_rows:
        entry = _get_or_create_episode_entry(
            episodes_map, row["episode_id"], row["fecha"], row["headline"], row["path"]
        )
        entry.matched_blocks.append(MatchedBlockOut(
            block_id=str(row["block_id"]), start_s=row["start_s"], snippet=row["snippet"],
        ))

    unmatched_requests: list[UnmatchedRequestOut] = []
    for row in request_rows:
        if row["episode_id"] is None:
            unmatched_requests.append(UnmatchedRequestOut(
                request_id=str(row["request_id"]), snippet=row["snippet"], status=row["status"],
            ))
            continue
        entry = _get_or_create_episode_entry(
            episodes_map, row["episode_id"], row["episode_fecha"], row["episode_headline"], row["episode_path"]
        )
        entry.matched_request_texts.append(RequestTextMatchOut(
            request_id=str(row["request_id"]), block_id=str(row["block_id"]), snippet=row["snippet"],
        ))

    episodes_out = sorted(episodes_map.values(), key=lambda e: e.fecha, reverse=True)
    took_ms = (time.perf_counter() - started) * 1000

    return SearchOut(
        query=q, took_ms=round(took_ms, 2), episodes=episodes_out,
        unmatched_requests=unmatched_requests,
    )
