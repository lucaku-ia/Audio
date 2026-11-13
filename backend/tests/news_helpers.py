"""Shared fakes/builders for the news tests. Never touches Anthropic: both model
stages (research_topic, write_news_items) are replaced with recording fakes."""
import uuid
from datetime import datetime, timezone

from app.models.cliente import AuthProvider, Cliente
from app.models.request import CreatedFrom, Request, RequestKind, RequestStatus
from app.services import ai_platform

NOW = datetime(2026, 11, 12, 6, 0, tzinfo=timezone.utc)  # inside the 05:00 slot band


def findings(headlines=("Arsenal beat Spurs 2-1",), *, no_news=False):
    items = [
        ai_platform.Finding(headline=h, detail=f"Detail for {h}.", source_urls=[f"https://example.com/{i}"])
        for i, h in enumerate(headlines)
    ]
    sources = [{"url": f"https://example.com/{i}", "title": f"Source {i}"} for i in range(len(items))]
    return ai_platform.Findings(findings=[] if no_news else items, sources=[] if no_news else sources,
                                no_news=no_news, parse_failed=False, cost=0.30)


def draft(title="Arsenal beat Spurs", *, summary="Arsenal win the derby 2-1.", urls=("https://example.com/0",),
          category="sports", body="Full write-up."):
    return ai_platform.NewsDraft(category=category, title=title, summary=summary, short_version="Short.",
                                 body=body, source_urls=list(urls), image_hint=None)


class Recorder:
    def __init__(self):
        self.research_calls: list = []
        self.write_calls: list = []


def patch_news_ai(monkeypatch, *, found=None, drafts=None) -> Recorder:
    rec = Recorder()
    found = found if found is not None else findings()
    drafts = drafts if drafts is not None else [draft()]

    async def _research(db, raw_text, topic, scope, geography, customer_id, request_id):
        rec.research_calls.append(topic)
        return found.model_copy(deep=True)

    async def _write(db, narrowed, topic, *, max_items, already_published, language="en"):
        rec.write_calls.append({"findings": narrowed.findings, "already": already_published, "max": max_items})
        return ai_platform.NewsDrafts(items=[d.model_copy(deep=True) for d in drafts], cost=0.02)

    monkeypatch.setattr(ai_platform, "research_topic", _research)
    monkeypatch.setattr(ai_platform, "write_news_items", _write)
    return rec


async def make_customer(db, topic: str | None = None, raw_text: str = "my topic") -> Cliente:
    cliente = Cliente(email=f"{uuid.uuid4()}@example.com", auth_provider=AuthProvider.email,
                      hashed_password=None, nombre="Test", idioma="en", onboarding_complete=True)
    db.add(cliente)
    await db.flush()
    db.add(Request(customer_id=cliente.id, kind=RequestKind.standing, raw_text=raw_text,
                   structured={"topic": topic} if topic else {}, status=RequestStatus.active,
                   created_from=CreatedFrom.onboarding))
    await db.commit()
    await db.refresh(cliente)
    return cliente
