"""
Guards the research/writing split in app/services/ai_platform.py.

The split exists so the expensive half of block production can be cached and
shared across customers while the cheap half stays per-listener. That only
holds if research stays customer-neutral — the moment style, language or a
customer id leaks into the research prompt, its output stops being shareable
and the whole point is lost silently, with nothing failing. These tests are
the thing that fails instead.
"""
import json
import types

import pytest

from app.services import ai_platform
from app.services.ai_platform import (
    Finding,
    Findings,
    _parse_findings,
    _resolve_sources,
    research_topic,
    write_block,
)


class _FakeResponse:
    def __init__(self, payload: str):
        self.content = [types.SimpleNamespace(type="text", text=payload)]
        self.usage = types.SimpleNamespace(input_tokens=1000, output_tokens=100)


@pytest.fixture
def captured(monkeypatch):
    """Stubs the model call and records exactly what was sent to it."""
    calls: list[dict] = []

    def fake_create(**kwargs):
        calls.append(kwargs)
        return _FakeResponse(fake_create.payload)

    fake_create.payload = "{}"
    monkeypatch.setattr(ai_platform, "_client", types.SimpleNamespace(messages=types.SimpleNamespace(create=fake_create)))

    async def fake_log_call(*a, **k):
        return 0.42

    async def fake_get_active_prompt(db, name, fallback_version, fallback_system_prompt):
        return fallback_system_prompt, fallback_version

    async def fake_attach_licenses(db, sources):
        return [{**s, "license": None} for s in sources]

    monkeypatch.setattr(ai_platform, "_log_call", fake_log_call)
    monkeypatch.setattr(ai_platform, "get_active_prompt", fake_get_active_prompt)
    monkeypatch.setattr(ai_platform, "attach_licenses", fake_attach_licenses)
    return calls, fake_create


_FINDINGS_PAYLOAD = json.dumps({
    "findings": [{
        "headline": "Anthropic cut Opus prices 20%",
        "detail": "Input $4/M, output $20/M, announced Sept 22.",
        "source_urls": ["https://siliconangle.com/x"],
    }],
    "sources": [{"url": "https://siliconangle.com/x", "title": "T", "publisher": "SiliconANGLE"}],
    "no_news": False,
})


@pytest.mark.asyncio
async def test_research_prompt_is_customer_neutral(captured):
    """
    The load-bearing invariant. Research must not be able to tell who asked,
    what style they want, or what language they listen in — otherwise its
    findings can't be reused for the next person asking the same thing.
    """
    calls, fake = captured
    fake.payload = _FINDINGS_PAYLOAD
    import uuid
    customer_id, request_id = uuid.uuid4(), uuid.uuid4()

    await research_topic(
        None, raw_text="how did Arsenal do", topic="Arsenal", scope="results",
        geography="England", customer_id=customer_id, request_id=request_id,
    )

    sent = json.dumps(calls[0], default=str)
    assert str(customer_id) not in sent, "customer id leaked into the research prompt"
    # The listener-specific *values* are what must not appear. The prompt does
    # say the words "no style, no language" in its own instructions, so a naive
    # keyword sweep would fail on the very sentence enforcing neutrality.
    for value in ai_platform._STYLE_DESCRIPTIONS.values():
        assert value not in sent, "a style description leaked into research"
    for value in ("Spanish", *ai_platform._DEPTH_WORDS.values()):
        assert value not in sent, f"{value!r} leaked into the research prompt"


@pytest.mark.asyncio
async def test_same_topic_produces_an_identical_research_request(captured):
    """
    The invariant stated positively, and the one caching actually rests on:
    two different customers, in different languages and styles, asking for the
    same thing must produce byte-identical research requests. If they ever
    diverge, a findings cache keyed on the topic would serve one customer's
    research to another under a key that no longer describes it.
    """
    import uuid
    calls, fake = captured
    fake.payload = _FINDINGS_PAYLOAD

    for style, language in (("news", "en"), ("casual", "es")):
        await research_topic(
            None, raw_text="how did Arsenal do", topic="Arsenal", scope="results",
            geography="England", customer_id=uuid.uuid4(), request_id=uuid.uuid4(),
        )

    assert calls[0] == calls[1], "research request varies by customer — findings are not shareable"


@pytest.mark.asyncio
async def test_research_searches_and_writing_does_not(captured):
    """Research is the only half that touches the web; writing works from
    findings alone, which is what makes it the cheap half."""
    calls, fake = captured

    fake.payload = _FINDINGS_PAYLOAD
    await research_topic(None, raw_text="x", topic="t", scope="s", geography=None,
                         customer_id=__import__("uuid").uuid4(), request_id=__import__("uuid").uuid4())
    assert any(t.get("name") == "web_search" for t in calls[0].get("tools", [])), "research lost its web_search tool"

    calls.clear()
    fake.payload = json.dumps({"summary": "s", "script": "sc", "sources": [], "no_news": False})
    await write_block(None, findings=Findings(findings=[], sources=[], no_news=False),
                      raw_text="x", topic="t", depth="standard", style="news", language="en",
                      customer_id=__import__("uuid").uuid4(), request_id=__import__("uuid").uuid4())
    assert "tools" not in calls[0], "writing must not be given web access"


@pytest.mark.asyncio
async def test_writing_receives_the_findings_and_the_style(captured):
    calls, fake = captured
    fake.payload = json.dumps({"summary": "s", "script": "sc", "sources": [], "no_news": False})

    findings = Findings(
        findings=[Finding(headline="H1", detail="D1", source_urls=["https://a.com"])],
        sources=[{"url": "https://a.com", "title": "A", "publisher": "P"}],
        no_news=False,
    )
    await write_block(None, findings=findings, raw_text="raw", topic="t", depth="deep",
                      style="casual", language="es",
                      customer_id=__import__("uuid").uuid4(), request_id=__import__("uuid").uuid4())

    sent = json.dumps(calls[0], default=str)
    assert "H1" in sent and "D1" in sent, "findings never reached the writer"
    assert "Spanish" in sent, "language not applied"
    assert "conversational" in sent, "style not applied"
    assert "180-240 words" in sent, "depth not applied"


@pytest.mark.asyncio
async def test_writer_cannot_invent_a_source(captured):
    """
    A writer that cites a url research never found contributes no citation at
    all, rather than a fabricated one. "No source, no block", at citation level.
    """
    calls, fake = captured
    fake.payload = json.dumps({
        "summary": "s", "script": "sc",
        "sources": ["https://a.com", "https://invented.example"],
        "no_news": False,
    })
    findings = Findings(findings=[], sources=[{"url": "https://a.com", "title": "A", "publisher": "P", "license": "CC"}], no_news=False)

    result = await write_block(None, findings=findings, raw_text="x", topic="t", depth="standard",
                               style="news", language="en",
                               customer_id=__import__("uuid").uuid4(), request_id=__import__("uuid").uuid4())

    assert [s["url"] for s in result.sources] == ["https://a.com"]
    assert result.sources[0]["license"] == "CC", "license attached at research time was lost"


def test_resolve_sources_tolerates_shapes_and_dedupes():
    available = [{"url": "https://a.com", "title": "A"}, {"url": "https://b.com", "title": "B"}]
    assert [s["url"] for s in _resolve_sources(["https://b.com"], available)] == ["https://b.com"]
    assert [s["url"] for s in _resolve_sources([{"url": "https://a.com"}], available)] == ["https://a.com"]
    assert len(_resolve_sources(["https://a.com", "https://a.com"], available)) == 1
    assert _resolve_sources(["https://nope.com"], available) == []
    assert _resolve_sources([], available) == []


def test_unparseable_research_is_an_empty_day_not_a_crash():
    """Generator tenet: no source, no block. Garbage in must not become a
    published block written from nothing."""
    assert _parse_findings("I could not find anything useful.").no_news is True
    assert _parse_findings("").no_news is True
    embedded = _parse_findings(f"here you go: {_FINDINGS_PAYLOAD} hope that helps")
    assert embedded.no_news is False
    assert embedded.findings[0].headline.startswith("Anthropic")
