"""
Voice allowlist per language.

Profile.voice_id holds a LOGICAL voice key (e.g. "valentina"), not an
ElevenLabs id. The key is what the app shows and sends; this module maps it to
the real ElevenLabs voice id at synthesis time.

The catalogue below is a PLACEHOLDER: the real ElevenLabs voice ids are TBD.
A real id is supplied per key through the environment, read on every call:

    ELEVENLABS_VOICE_ID_VALENTINA=<elevenlabs id>   (key upper-cased)

While a key has no real id configured it resolves to None, which makes
ai_platform.synthesize fall back to the account's first usable voice (the
behaviour before this module existed), so nothing breaks before the ids are
decided. `ELEVENLABS_MODEL` stays eleven_multilingual_v2, which speaks both.

Allowed values for a customer in language L: the keys listed for L, plus any
real id configured for one of them. Anything else is rejected by PATCH/PUT
/profile.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

from app.core.i18n import DEFAULT_LANGUAGE, SUPPORTED_LANGUAGES, language_for, normalize_language


@dataclass(frozen=True)
class VoiceOption:
    key: str
    label: str
    detail: str
    language: str


# First entry of each language is that language's default voice.
VOICE_CATALOGUE: dict[str, tuple[VoiceOption, ...]] = {
    "es": (
        VoiceOption("valentina", "Valentina", "Warm, calm female voice", "es"),
        VoiceOption("andres", "Andrés", "Clear, steady male voice", "es"),
    ),
    # PLACEHOLDER keys: names and ElevenLabs ids for English are TBD.
    "en": (
        VoiceOption("en_voice_female_1", "English voice 1 (placeholder)", "Warm, calm female voice", "en"),
        VoiceOption("en_voice_male_1", "English voice 2 (placeholder)", "Clear, steady male voice", "en"),
    ),
}


def _env_id(key: str) -> str | None:
    value = os.getenv(f"ELEVENLABS_VOICE_ID_{key.upper()}", "").strip()
    return value or None


def voices_for(language: str | None) -> tuple[VoiceOption, ...]:
    return VOICE_CATALOGUE[language_for(language)]


def _find(key: str | None, language: str | None = None) -> VoiceOption | None:
    """The catalogue entry a stored value refers to (by key, or by the real id
    configured for it). Restricted to `language` when given."""
    if not key:
        return None
    langs = [language_for(language)] if language is not None else list(SUPPORTED_LANGUAGES)
    for lang in langs:
        for option in VOICE_CATALOGUE[lang]:
            if key == option.key or key == _env_id(option.key):
                return option
    return None


def is_allowed_voice(language: str | None, voice: str | None) -> bool:
    return _find(voice, language_for(language)) is not None


def default_voice_key(language: str | None) -> str:
    return voices_for(language)[0].key


def resolve_voice(language: str | None, voice: str | None) -> str | None:
    """The ElevenLabs voice id to synthesize with, or None for "the account's
    default voice" (which synthesize resolves itself).

    A stored voice that belongs to the OTHER language (the customer switched
    language and has not picked a voice yet) falls back to the new language's
    default. A key without a real id configured yet resolves to None."""
    lang = language_for(language) if language is not None else None
    option = _find(voice, lang)
    if option is None:
        if not voice and lang is not None:
            return _env_id(voices_for(lang)[0].key)  # nothing chosen: the language's default voice
        if not voice or _find(voice) is None:
            # Not a catalogue key at all (an id stored before the catalogue
            # existed): passes through unchanged.
            return voice or None
        # A key of the OTHER language.
        option = voices_for(lang)[0]
    return _env_id(option.key)


def provider_voice_id(voice: str | None) -> str | None:
    """Language-agnostic form for ai_platform.synthesize: a catalogue key maps
    to its configured id (or None while TBD); any other value passes through."""
    option = _find(voice)
    if option is None:
        return voice or None
    return _env_id(option.key)


def catalogue_out(language: str | None) -> list[dict]:
    return [
        {"id": o.key, "label": o.label, "detail": o.detail, "language": o.language}
        for o in voices_for(language)
    ]


__all__ = [
    "VoiceOption", "VOICE_CATALOGUE", "voices_for", "is_allowed_voice", "default_voice_key",
    "resolve_voice", "provider_voice_id", "catalogue_out", "DEFAULT_LANGUAGE", "normalize_language",
]
