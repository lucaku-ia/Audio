"""Bilingual (es/en) behaviour. Fakes only: no Anthropic / ElevenLabs call is ever made."""
import uuid
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi import HTTPException
from pydantic import ValidationError
from sqlalchemy import select, text

from app.api.routes import home, news, onboarding, profile
from app.core import i18n, voices
from app.db.migraciones import ejecutar_migraciones
from app.db.session import DATABASE_URL, ENGINE_CONNECT_ARGS, Base
from app.main import app
from app.models.news import NewsItem, NewsRun
from app.models.profile import Language, Profile
from app.services import ai_platform
from app.services import news_pipeline as np_
from tests.news_helpers import NOW, draft, make_customer, patch_news_ai

# --- language_for / validation -------------------------------------------------


def test_language_for_defaults_and_allowlist():
    assert i18n.language_for(None) == "es"
    assert i18n.language_for("fr") == "es"
    assert i18n.language_for("EN-us") == "en"
    assert i18n.language_for(Language.en) == "en"

    class C:  # Cliente-like
        idioma = "en"

    class P:  # Profile-like
        language = Language.es

    assert i18n.language_for(C()) == "en" and i18n.language_for(P()) == "es"
    with pytest.raises(ValueError):
        i18n.validate_language("de")


def test_patch_body_rejects_unsupported_language():
    assert profile.SettingsBody(language="EN").language == "en"
    with pytest.raises(ValidationError):
        profile.SettingsBody(language="fr")


# --- voices ----------------------------------------------------------------------


def test_voice_allowlist_per_language_and_resolution(monkeypatch):
    assert voices.is_allowed_voice("es", "valentina") and not voices.is_allowed_voice("en", "valentina")
    assert voices.is_allowed_voice("en", "en_voice_female_1")
    assert not voices.is_allowed_voice("es", "some-random-id")
    # Key without a configured real id -> None (account default voice).
    monkeypatch.delenv("ELEVENLABS_VOICE_ID_VALENTINA", raising=False)
    assert voices.resolve_voice("es", "valentina") is None
    monkeypatch.setenv("ELEVENLABS_VOICE_ID_VALENTINA", "real-es-1")
    assert voices.resolve_voice("es", "valentina") == "real-es-1"
    assert voices.provider_voice_id("valentina") == "real-es-1"
    assert voices.is_allowed_voice("es", "real-es-1")  # the configured real id is accepted too
    # A voice of the other language falls back to the new language's default.
    monkeypatch.setenv("ELEVENLABS_VOICE_ID_EN_VOICE_FEMALE_1", "real-en-1")
    assert voices.resolve_voice("en", "valentina") == "real-en-1"
    assert voices.resolve_voice("en", None) == "real-en-1"
    # A legacy free-text id passes through untouched.
    assert voices.resolve_voice("es", "legacy-eleven-id") == "legacy-eleven-id"


@pytest.mark.asyncio
async def test_profile_patch_rejects_unknown_voice_and_follows_language(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="x")
    me.idioma = "es"
    db.add(Profile(customer_id=me.id, language=Language.es, voice_id="valentina"))
    await db.commit()

    with pytest.raises(HTTPException) as e:
        await profile.update_settings(profile.SettingsBody(voice_id="not-in-allowlist"), me, db)
    assert e.value.status_code == 422 and e.value.detail["code"] == "voice_not_allowed"
    with pytest.raises(HTTPException):  # an English voice is not allowed for an es customer
        await profile.update_settings(profile.SettingsBody(voice_id="en_voice_male_1"), me, db)

    out = await profile.update_settings(profile.SettingsBody(voice_id="andres"), me, db)
    assert out.voice_id == "andres" and "próximo episodio" in out.messages[0]

    # Switching language: Cliente and Profile move together, the es voice is reset, messages are English.
    out = await profile.update_settings(profile.SettingsBody(language="en"), me, db)
    assert out.language == "en" and me.idioma == "en" and out.voice_id is None
    assert any("voice was reset" in m for m in out.messages)
    assert {v["id"] for v in out.available_voices} == {"en_voice_female_1", "en_voice_male_1"}
    out = await profile.update_settings(profile.SettingsBody(voice_id="en_voice_male_1"), me, db)
    assert out.voice_id == "en_voice_male_1"

    # PUT is validated too.
    with pytest.raises(HTTPException):
        await profile.update_profile(profile.ProfileBody(voice_id="nope", delivery_time="07:00"), me, db)


# --- news per language -----------------------------------------------------------


@pytest.mark.asyncio
async def test_research_once_and_one_write_per_language(full_db_session, monkeypatch):
    db = full_db_session
    rec = patch_news_ai(monkeypatch)
    langs_seen = []
    inner = ai_platform.write_news_items

    async def _write(db_, narrowed, topic, **kw):
        langs_seen.append(kw["language"])
        return await inner(db_, narrowed, topic, **kw)

    monkeypatch.setattr(ai_platform, "write_news_items", _write)

    result = await np_.run_news_for_topic(db, "Premier League", slot="0500", now=NOW, languages=["es", "en", "es"])
    assert result.status == "done"
    assert len(rec.research_calls) == 1  # research is shared whatever the languages
    assert sorted(langs_seen) == ["en", "es"]
    rows = (await db.execute(select(NewsItem.language))).scalars().all()
    assert sorted(rows) == ["en", "es"]
    runs = (await db.execute(select(NewsRun.language, NewsRun.status))).all()
    assert sorted(runs) == [("en", "done"), ("es", "done")]

    # Idempotent per language: the same call again is a no-op; a new language only writes that one.
    again = await np_.run_news_for_topic(db, "Premier League", slot="0500", now=NOW, languages=["es", "en"])
    assert again.status == "skipped" and len(rec.research_calls) == 1


@pytest.mark.asyncio
async def test_scheduler_writes_only_languages_with_followers(full_db_session, monkeypatch):
    db = full_db_session
    rec = patch_news_ai(monkeypatch)
    a = await make_customer(db, topic="Premier League")
    b = await make_customer(db, topic="Premier League")
    b.idioma = "es"
    await db.commit()
    summary = await np_.run_scheduled_slot(db, now=NOW)
    assert summary["failed"] == 0
    assert len(rec.research_calls) == 1
    assert sorted((await db.execute(select(NewsItem.language))).scalars().all()) == ["en", "es"]
    assert a.id != b.id


@pytest.mark.asyncio
async def test_caller_gets_own_language_with_fallback_flag(full_db_session):
    db = full_db_session
    me = await make_customer(db, topic="Premier League")
    now = datetime.now(timezone.utc)

    def item(title, lang):
        return NewsItem(topic_key="premier league", category="sports", title=title, summary="s", short_version="s",
                        body="b", sources=[], published_at=now - timedelta(hours=1), slot="0500", language=lang)

    db.add(item("English story", "en"))
    await db.commit()

    me.idioma = "es"
    await db.commit()
    page = await news.fetch_news_page(db, me)
    assert [i.title for i in page.items] == ["English story"]
    assert page.language == "en" and page.language_fallback is True  # nothing in es yet -> flagged fallback

    db.add(item("Historia en español", "es"))
    await db.commit()
    page = await news.fetch_news_page(db, me)
    assert [i.title for i in page.items] == ["Historia en español"]
    assert page.language == "es" and page.language_fallback is False and page.items[0].language == "es"

    me.idioma = "en"
    await db.commit()
    page = await news.fetch_news_page(db, me)
    assert [i.title for i in page.items] == ["English story"] and page.language_fallback is False

    home_out = await home.home(cliente=me, db=db)
    assert home_out.news.language == "en"


# --- migration -------------------------------------------------------------------


@pytest.mark.asyncio
async def test_migration_adds_news_language_with_default_en(full_db_session):
    from sqlalchemy.ext.asyncio import create_async_engine

    engine = create_async_engine(DATABASE_URL, echo=False, connect_args=ENGINE_CONNECT_ARGS)
    try:
        async with engine.begin() as conn:
            await conn.execute(text("DROP TABLE IF EXISTS news_read_states, news_items, news_runs CASCADE"))
            await conn.execute(text(
                "CREATE TABLE news_items (id UUID PRIMARY KEY, topic_key VARCHAR(300) NOT NULL, "
                "category VARCHAR(40) NOT NULL, title VARCHAR(300) NOT NULL, summary VARCHAR(70) NOT NULL, "
                "short_version TEXT NOT NULL, body TEXT NOT NULL, sources JSON, image_hint VARCHAR(300), "
                "published_at TIMESTAMPTZ NOT NULL, slot VARCHAR(10) NOT NULL, cluster_id UUID, created_at TIMESTAMPTZ)"))
            await conn.execute(text(
                "CREATE TABLE news_runs (id UUID PRIMARY KEY, topic_key VARCHAR(300) NOT NULL, run_date DATE NOT NULL, "
                "slot VARCHAR(10) NOT NULL, status VARCHAR(20), items_count INTEGER, attempts INTEGER, cost FLOAT, "
                "error VARCHAR(300), created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ, "
                "CONSTRAINT uq_news_runs_topic_date_slot UNIQUE (topic_key, run_date, slot))"))
            await conn.execute(text(
                "INSERT INTO news_items (id, topic_key, category, title, summary, short_version, body, published_at, slot) "
                f"VALUES ('{uuid.uuid4()}', 't', 'sports', 'old', 's', 's', 'b', now(), '0500')"))
            await conn.execute(text(
                "INSERT INTO news_runs (id, topic_key, run_date, slot) "
                f"VALUES ('{uuid.uuid4()}', 't', current_date, '0500')"))

        await ejecutar_migraciones(engine)
        await ejecutar_migraciones(engine)  # idempotent

        async with engine.begin() as conn:
            assert (await conn.execute(text("SELECT language FROM news_items"))).scalar_one() == "en"
            assert (await conn.execute(text("SELECT language FROM news_runs"))).scalar_one() == "en"
            names = {r[0] for r in await conn.execute(text("SELECT indexname FROM pg_indexes WHERE tablename='news_runs'"))}
            assert "uq_news_runs_topic_date_slot_lang" in names and "uq_news_runs_topic_date_slot" not in names
            # Same key in another language is now allowed; the same key twice is not.
            await conn.execute(text(
                "INSERT INTO news_runs (id, topic_key, run_date, slot, language) "
                f"VALUES ('{uuid.uuid4()}', 't', current_date, '0500', 'es')"))
    finally:
        async with engine.begin() as conn:
            await conn.execute(text("DROP TABLE IF EXISTS news_read_states, news_items, news_runs CASCADE"))
            await conn.run_sync(Base.metadata.create_all)
        await engine.dispose()


# --- localized messages ------------------------------------------------------------


def test_message_catalog_is_complete_in_both_languages():
    for code, entry in i18n.MESSAGES.items():
        assert set(entry) == {"es", "en"} and all(entry.values()), code
    assert i18n.msg("budget_exceeded", "es") != i18n.msg("budget_exceeded", "en")
    assert i18n.msg("nope", "es") == "nope"
    assert i18n.failure_message("ai_paused", "es") == i18n.msg("ai_paused", "es")
    assert i18n.failure_message(None, "es") is None


@pytest.mark.asyncio
async def test_error_handlers_answer_in_the_callers_language():
    async def _boom_budget():
        raise ai_platform.BudgetExceededError(scope="customer", spent=2.0, limit=1.0)

    app.add_api_route("/__lang_budget", _boom_budget)
    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            en = await c.get("/__lang_budget", headers={"Accept-Language": "en-US,es;q=0.8"})
            es = await c.get("/__lang_budget", headers={"Accept-Language": "es-CO"})
    finally:
        app.router.routes.pop()
    assert en.status_code == es.status_code == 429
    assert en.json()["code"] == es.json()["code"] == "budget_exceeded"
    assert en.json()["message"] == en.json()["detail"] == i18n.msg("budget_exceeded", "en")
    assert es.json()["message"] == i18n.msg("budget_exceeded", "es")


@pytest.mark.asyncio
async def test_onboarding_confirm_message_follows_language(full_db_session, monkeypatch):
    from tests.test_onboarding_confirm import _make_customer

    def _no_task(coro):  # never run the background first-episode generation
        coro.close()

    monkeypatch.setattr(onboarding.asyncio, "create_task", _no_task)
    db = full_db_session
    cliente = await _make_customer(db, delivery_in_minutes=180)  # idioma="es"
    result = await onboarding.confirm(cliente, db)
    assert result.message.startswith("Tu primer episodio")
    cliente.idioma = "en"
    result = await onboarding.confirm(cliente, db)
    assert result.message.startswith("Your first episode")


def test_onboarding_labels_and_seeds_follow_language():
    interest = onboarding._SEEDS["interests"][0]
    assert onboarding._label(interest, "en") == interest["label_en"]
    assert onboarding._label(interest, "es") == interest["label_es"]
    assert onboarding._seeds(interest, "xx") == interest["seeds_es"]  # unsupported -> default
