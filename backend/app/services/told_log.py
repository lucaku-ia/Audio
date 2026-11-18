"""
What this listener has already been told.

The founder asked for the cache as a product feature, not only a cost one:
"I want the cache as this is also good for the customer no? like having a
connection from the previous episode?" The shared findings store
(app/services/findings_store.py) is the cost half. This is the other half,
and it is deliberately the opposite shape: findings are shared across
customers and keyed by topic, while the told-log is per customer and keyed by
their own standing request. One makes episodes cheaper; this one makes them
feel continuous.

No new table. "What we told this customer" is already in the database — every
Block carries a request_id and a one-line summary — so this is a read, not a
second source of truth that could drift from what was actually said.

The one rule that matters: ONLY PUBLISHED EPISODES COUNT.

An episode that failed in voicing has finished scripts sitting in the
database and was never heard by anyone. Treating it as "told" would have the
next episode open with "yesterday we covered the rate decision" to a listener
who heard silence — building continuity on something that never reached
their ears. published_at is the only honest record of what was delivered,
which is exactly why PR #43 stopped stamping it before the audio existed.
"""
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.episode import Block, Episode
from app.services import capsules

# How many previous segments to carry. Three is roughly a working week of a
# topic the listener follows daily — enough for "this is the third day of
# this story" without turning the writing prompt into a transcript archive,
# which costs tokens on every block and dilutes today's findings.
DEFAULT_LIMIT = 3


async def recent_for_request(
    db: AsyncSession,
    *,
    customer_id: uuid.UUID,
    request_id: uuid.UUID | None,
    before_episode_id: uuid.UUID | None = None,
    limit: int = DEFAULT_LIMIT,
) -> list[str]:
    """
    The last few things this listener was told about THIS standing request,
    newest first, as one-line summaries.

    Scoped to the request rather than the customer: continuity is per topic.
    Carrying yesterday's football into today's markets segment would be
    noise, and would spend tokens to produce it.

    `before_episode_id` excludes the episode currently being built, which has
    rows in the database before it is published.
    """
    if request_id is None:  # intro/outro blocks have no request
        return []

    query = (
        select(Block.summary)
        .join(Episode, Episode.id == Block.episode_id)
        .where(
            Block.request_id == request_id,
            Episode.customer_id == customer_id,
            # Only what was actually delivered — see the module docstring.
            Episode.published_at.is_not(None),
            Block.no_news.is_(False),
            # Capsules: a block whose own audio failed or was budget-blocked
            # was never heard even though its episode published. NULL status
            # is a legacy row and counts as delivered.
            capsules.delivered_clause(),
        )
        .order_by(Episode.published_at.desc(), Block.sequence, Block.start_s)
        .limit(limit)
    )
    if before_episode_id is not None:
        query = query.where(Block.episode_id != before_episode_id)

    rows = (await db.execute(query)).scalars().all()
    return [s for s in rows if (s or "").strip()]
