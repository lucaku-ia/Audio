"""
Shared fakes for the AI pipeline.

PR #36 split ai_platform.research_and_write_block into two calls —
research_topic (customer-neutral, cacheable) and write_block (per listener) —
so research can later be shared between customers. Every suite that
monkeypatched the old single function broke the moment that split reached
main:

    AttributeError: module 'app.services.ai_platform' has no attribute
    'research_and_write_block'

Worth recording how it got through, because the shape of the mistake matters
more than the fix: #31 and #36 were each individually mergeable, git merged
the text with no conflict at all, and the breakage is purely semantic — one
PR deleted a function the other's tests patched by name. Neither PR's suite
was ever run against the other's merged result. Nothing in the tooling was
going to catch that; only running the combined result would.

These fakes live in one module so the next change to the pipeline's shape
updates one file instead of four. Nothing here mocks at the HTTP or SDK
level — they substitute the two coroutines the generator calls, exactly as
these suites always did.
"""

def fake_findings(*, no_news: bool = False, cost: float = 0.43):
    """Research output. `no_news=True` is an honest quiet day, NOT a parse
    failure — parse_failed stays False, which is what keeps the generator
    from escalating to a more expensive model over a correct answer."""
    from app.services import ai_platform
    return ai_platform.Findings(
        findings=[] if no_news else [
            ai_platform.Finding(
                headline="Something happened today.",
                detail="A test fixture's idea of a newsworthy development.",
                source_urls=["https://example.com/story"],
            )
        ],
        sources=[] if no_news else [{"url": "https://example.com/story", "title": "A story"}],
        no_news=no_news,
        parse_failed=False,
        cost=cost,
    )


def fake_block(*, no_news: bool = False, cost: float = 0.43):
    """Writing output, for a topic that had findings."""
    from app.services import ai_platform
    return ai_platform.BlockResult(
        summary="" if no_news else "Something happened",
        script="" if no_news else "Here is today's real news. " * 10,
        sources=[],
        no_news=no_news,
        cost=cost,
    )


def patch_ai_pipeline(monkeypatch, *, no_news: bool = False, cost: float = 0.43) -> None:
    """Swap BOTH halves of the pipeline for fakes.

    Never mocks at the HTTP/SDK level — just substitutes the two coroutines
    the generator calls, the way these suites always have. `no_news=True`
    fakes a genuinely quiet day end to end: research returns nothing, and the
    generator skips writing entirely rather than paying a model to say so.
    """
    from app.services import ai_platform

    async def _research(*a, **kw):
        return fake_findings(no_news=no_news, cost=cost)

    async def _write(*a, **kw):
        return fake_block(cost=cost)

    monkeypatch.setattr(ai_platform, "research_topic", _research)
    monkeypatch.setattr(ai_platform, "write_block", _write)


def patch_ai_pipeline_slow(monkeypatch, *, delay: float = 0.35, cost: float = 0.43) -> None:
    """Like patch_ai_pipeline, but research sleeps first.

    Used to prove a caller returned BEFORE the pipeline finished — the shape
    of the "confirm() blocks on the whole generation" defect. The sleep lives
    in research because that's the first call the generator makes, so nothing
    downstream needs to run for the timing assertion to hold.
    """
    import asyncio

    from app.services import ai_platform

    async def _slow_research(*a, **kw):
        await asyncio.sleep(delay)
        return fake_findings(no_news=True, cost=cost)

    async def _write(*a, **kw):
        return fake_block(cost=cost)

    monkeypatch.setattr(ai_platform, "research_topic", _slow_research)
    monkeypatch.setattr(ai_platform, "write_block", _write)


def patch_ai_pipeline_forbidden(monkeypatch, message: str) -> None:
    """Make ANY pipeline call an immediate test failure.

    For paths that must not generate at all. Both halves are patched: after
    the research/write split, patching only one leaves a real call reachable,
    which would turn "this path must never generate" into a test that quietly
    stopped checking.
    """
    from app.services import ai_platform

    async def _forbidden(*a, **kw):
        raise AssertionError(message)

    monkeypatch.setattr(ai_platform, "research_topic", _forbidden)
    monkeypatch.setattr(ai_platform, "write_block", _forbidden)
