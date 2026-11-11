"""
Guards the per-purpose model routing in app/services/ai_platform.py.

Routing is a cost control that is invisible when it breaks: if a call silently
falls back to the expensive model, nothing fails, no test goes red, and the
bill goes up. These tests are the thing that goes red.
"""
import json
import types

import pytest

from app.services import ai_platform
from app.services.ai_platform import (
    Findings,
    _cost,
    escalation_for,
    model_for,
)


class _FakeResponse:
    def __init__(self, payload: str, input_tokens: int = 50_000, output_tokens: int = 500):
        self.content = [types.SimpleNamespace(type="text", text=payload)]
        self.usage = types.SimpleNamespace(input_tokens=input_tokens, output_tokens=output_tokens)


_GOOD_FINDINGS = json.dumps({
    "findings": [{"headline": "h", "detail": "d", "source_urls": ["https://a.com"]}],
    "sources": [{"url": "https://a.com", "title": "T", "publisher": "P"}],
    "no_news": False,
})


def test_research_does_not_run_on_haiku():
    """`web_search_20260209` — the variant this module declares — is not
    available on Haiku. Routing research there would quietly degrade the search
    rather than the cost, which is the one trade this routing must never make."""
    assert model_for("research_topic") != "claude-haiku-5-5"
    assert model_for("research_topic") in ai_platform._PRICE_PER_1M


def test_the_cheap_work_is_actually_routed_cheap():
    """Writing and the two classifiers are the calls that should not be paying
    Opus rates. If any of these drifts back to the strong model, the saving
    this whole change exists for is gone."""
    strong = ai_platform._STRONG
    for purpose in ("write_block", "structure_request", "refine_request"):
        assert model_for(purpose) != strong, f"{purpose} drifted back to the strong model"


def test_an_unknown_purpose_is_expensive_not_degraded():
    """A new call site should cost too much, not quietly get the weakest model
    and produce worse output nobody traced back to here."""
    assert model_for("some_future_call") == ai_platform._STRONG


def test_every_routed_model_has_a_price():
    """A model with no price entry logs cost 0.0, which looks like free work in
    the dashboard rather than missing data."""
    for purpose in ("research_topic", "write_block", "structure_request", "refine_request"):
        assert model_for(purpose) in ai_platform._PRICE_PER_1M


def test_haiku_long_prompts_are_not_underpriced():
    """Haiku's headline rate only holds under 100K input tokens. Pricing a
    longer prompt at the cheap rate would make the dashboard understate spend
    exactly where it is growing."""
    usage = types.SimpleNamespace(input_tokens=150_000, output_tokens=1_000)
    cheap = types.SimpleNamespace(input_tokens=50_000, output_tokens=1_000)
    long_cost = _cost(usage, "claude-haiku-5-5")
    short_cost = _cost(cheap, "claude-haiku-5-5")
    # 150K at the long rate is 0.075; at the headline rate it would be 0.015.
    assert long_cost == pytest.approx(150_000 / 1e6 * 0.50 + 1_000 / 1e6 * 2.50)
    assert long_cost > short_cost * 3


def test_routing_is_cheaper_than_running_everything_on_opus():
    """The claim the change rests on, stated as arithmetic: one researched and
    written block costs less routed than it did on one strong model."""
    research = types.SimpleNamespace(input_tokens=50_000, output_tokens=1_000)
    writing = types.SimpleNamespace(input_tokens=2_000, output_tokens=800)
    routed = _cost(research, model_for("research_topic")) + _cost(writing, model_for("write_block"))
    all_opus = _cost(research, "claude-opus-5") + _cost(writing, "claude-opus-5")
    assert routed < all_opus / 2, f"routed {routed:.4f} vs opus {all_opus:.4f}"


@pytest.mark.asyncio
async def test_unparseable_output_escalates_once(monkeypatch):
    """A cheap model that returns something unreadable is retried on a stronger
    one. Before `parse_failed` existed this case was indistinguishable from a
    quiet day, so a malformed response became an empty episode."""
    calls: list[str] = []

    async def fake_log_call(*a, **k):
        return 0.01

    monkeypatch.setattr(ai_platform, "_log_call", fake_log_call)

    def call(model: str):
        calls.append(model)
        # first attempt unreadable, retry fine
        return _FakeResponse("not json at all" if len(calls) == 1 else _GOOD_FINDINGS)

    result, cost = await ai_platform._run_with_escalation(
        None, purpose="write_block", version="v1", call=call,
        parse=ai_platform._parse_findings,
        customer_id=__import__("uuid").uuid4(), context={},
    )

    assert len(calls) == 2, "should have retried exactly once"
    assert calls[0] == model_for("write_block")
    assert calls[1] == escalation_for("write_block")
    assert result.no_news is False, "the retry's good answer should be the one returned"
    assert cost == pytest.approx(0.02), "both attempts should be billed, not just one"


@pytest.mark.asyncio
async def test_an_honestly_quiet_day_is_not_escalated(monkeypatch):
    """The important negative. A model reporting nothing new is giving the
    correct answer; retrying it on a stronger model to get a different one
    would be paying extra to manufacture news that does not exist."""
    calls: list[str] = []

    async def fake_log_call(*a, **k):
        return 0.01

    monkeypatch.setattr(ai_platform, "_log_call", fake_log_call)

    quiet = json.dumps({"findings": [], "sources": [], "no_news": True})

    def call(model: str):
        calls.append(model)
        return _FakeResponse(quiet)

    result, _ = await ai_platform._run_with_escalation(
        None, purpose="write_block", version="v1", call=call,
        parse=ai_platform._parse_findings,
        customer_id=__import__("uuid").uuid4(), context={},
    )

    assert len(calls) == 1, "a quiet day must not trigger a retry"
    assert result.no_news is True
    assert result.parse_failed is False


def test_parse_failure_and_quiet_day_are_distinguishable():
    """Both produce no_news=True and mean opposite things."""
    assert ai_platform._parse_findings("garbage").parse_failed is True
    quiet = ai_platform._parse_findings(json.dumps({"findings": [], "sources": [], "no_news": True}))
    assert quiet.no_news is True and quiet.parse_failed is False
