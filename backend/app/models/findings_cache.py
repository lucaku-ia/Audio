"""
FindingsCache — the shared research store.

The point of splitting research_and_write_block into research_topic +
write_block was to make the expensive half cacheable. This is the cache.
Nothing about an entry is customer-specific: two people who follow the same
topic should pay for that research once between them, and still get two
different episodes, because only the WRITING is per listener. Audio is never
shared, and neither is a script.

The cache key is (topic_key, scope, geography) within a freshness window.

One honest caveat about that key. research_topic's prompt also includes the
customer's own `raw_text` ("What the person asked for, in their words"),
because the structured fields lose intent — "how did Arsenal do" wants
results, not transfers. So a cached entry was researched from SOMEBODY's
phrasing, and serving it to a second customer means serving findings shaped
by a request worded differently from theirs.

That is acceptable, deliberately, and not something to paper over:
`structured` (topic/scope/geography) is the system's own normalization of
raw_text — producing a canonical form is precisely what the structure step
exists for. Two requests that normalize to the same topic/scope/geography
have been judged equivalent by our own classifier, and if that judgement is
wrong the bug is in the classifier, not here. `researched_from` keeps the
originating raw_text so a bad hit can actually be diagnosed rather than
guessed at.

What is NEVER cached:
  - a parse failure (parse_failed) — that's a lost block, not a finding, and
    caching it would turn one bad response into everyone's bad response.
  - anything keyed by customer, style, language or depth. If any of those
    ever reach this table, the split has been undone.
"""
import uuid
from datetime import datetime, timezone

from sqlalchemy import String, DateTime, JSON, Boolean, Float, Integer, Text, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.session import Base


class FindingsCache(Base):
    __tablename__ = "findings_cache"
    __table_args__ = (
        UniqueConstraint("topic_key", "scope_key", "geography_key", name="uq_findings_cache_key"),
    )

    id: Mapped[uuid.UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4)

    # Normalized key parts. Normalized rather than raw so that "Premier League"
    # and "premier league " are one entry and not two — see
    # findings_store.normalize. Empty string rather than NULL for the optional
    # parts, because NULL != NULL in Postgres and a UNIQUE constraint over a
    # nullable column silently stops deduplicating.
    topic_key: Mapped[str] = mapped_column(String(300), index=True)
    scope_key: Mapped[str] = mapped_column(String(300), default="")
    geography_key: Mapped[str] = mapped_column(String(120), default="")

    # The Findings payload, minus the per-run fields (cost, parse_failed).
    payload: Mapped[dict] = mapped_column(JSON)
    no_news: Mapped[bool] = mapped_column(Boolean, default=False)

    # Diagnostics, not key material.
    researched_from: Mapped[str | None] = mapped_column(Text, nullable=True)
    original_cost: Mapped[float] = mapped_column(Float, default=0.0)
    hit_count: Mapped[int] = mapped_column(Integer, default=0)
    last_hit_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    creado_en: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), index=True)
