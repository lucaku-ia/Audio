"""
Language (es/en): the single source of truth and the server-side message catalog.

One language setting per customer drives the app UI, the audio voices, the
episode script, the news and every message the server originates. It lives in
`Cliente.idioma` (mirrored to `Profile.language`; PATCH /profile writes both).
Everything that needs "which language is this customer in" calls
`language_for(...)` so there is exactly one place that decides the default and
validates the value.

Research stays language-neutral and SHARED (findings are written in English
and cached per topic); language only affects the cheap write step.
"""
from __future__ import annotations

from typing import Any

SUPPORTED_LANGUAGES: tuple[str, ...] = ("es", "en")
DEFAULT_LANGUAGE = "es"  # Cliente.idioma's column default; the pilot market is Colombia
LANGUAGE_NAMES = {"es": "Spanish", "en": "English"}  # for model prompts


def normalize_language(value: Any) -> str | None:
    """'es' / 'en' for a supported value (case-insensitive, region suffix
    tolerated: 'en-US', 'es_CO'; an enum with a .value is accepted), else None."""
    value = getattr(value, "value", value)
    if not isinstance(value, str):
        return None
    code = value.strip().lower().replace("_", "-").split("-")[0]
    return code if code in SUPPORTED_LANGUAGES else None


def validate_language(value: Any) -> str:
    """Like normalize_language but raises ValueError on anything unsupported
    (for request validation)."""
    code = normalize_language(value)
    if code is None:
        raise ValueError(f"Unsupported language {value!r}; expected one of {', '.join(SUPPORTED_LANGUAGES)}")
    return code


def language_for(subject: Any = None) -> str:
    """The customer's language, always 'es' or 'en'.

    Accepts a Cliente (uses .idioma), a Profile (uses .language) or a plain
    string/enum. Anything missing or outside the allowlist falls back to
    DEFAULT_LANGUAGE, so no caller ever has to handle a bad value."""
    if subject is None:
        return DEFAULT_LANGUAGE
    for attr in ("idioma", "language"):
        if hasattr(subject, attr):
            return normalize_language(getattr(subject, attr)) or DEFAULT_LANGUAGE
    return normalize_language(subject) or DEFAULT_LANGUAGE


def other_language(language: str) -> str:
    return "en" if language_for(language) == "es" else "es"


def language_from_accept_header(header: str | None) -> str | None:
    """First supported language in an Accept-Language header (used only when
    there is no authenticated customer, e.g. a login error)."""
    if not header:
        return None
    for part in header.split(","):
        code = normalize_language(part.split(";")[0])
        if code:
            return code
    return None


# ── Message catalog ──────────────────────────────────────────────────────────
# Keyed by a stable code. Only messages the app DISPLAYS go here; the `code`
# fields on responses are unchanged and remain the machine-readable contract.
MESSAGES: dict[str, dict[str, str]] = {
    "budget_exceeded": {
        "en": "You've reached today's limit for AI requests. Please try again tomorrow.",
        "es": "Llegaste al límite de hoy para solicitudes de IA. Inténtalo de nuevo mañana.",
    },
    "ai_paused": {
        "en": "AI features are paused for a moment. Please try again later.",
        "es": "Las funciones de IA están en pausa por un momento. Inténtalo de nuevo más tarde.",
    },
    "model_unavailable": {
        "en": "I could not reach the model just now. Try that again in a moment.",
        "es": "No pude comunicarme con el modelo en este momento. Inténtalo de nuevo en un momento.",
    },
    "request_too_short": {
        "en": "This request is too short to research anything from.",
        "es": "Esta solicitud es demasiado corta para investigar algo.",
    },
    "request_not_researchable": {
        "en": "This request can't be researched as written.",
        "es": "Esta solicitud no se puede investigar tal como está escrita.",
    },
    "refine_applied": {
        "en": "Applied from tomorrow.",
        "es": "Se aplica desde mañana.",
    },
    "voice_not_allowed": {
        "en": "That voice is not available for your language.",
        "es": "Esa voz no está disponible para tu idioma.",
    },
    "language_not_supported": {
        "en": "Unsupported language. Use 'es' or 'en'.",
        "es": "Idioma no compatible. Usa 'es' o 'en'.",
    },
    "voice_reset_for_language": {
        "en": "Your voice was reset to the default for the new language.",
        "es": "Tu voz se restableció a la predeterminada del nuevo idioma.",
    },
    # Profile PATCH "when does it apply" messages
    "profile_voice_applies": {
        "en": "Voice change applies from your next episode.",
        "es": "El cambio de voz se aplica desde tu próximo episodio.",
    },
    "profile_style_applies": {
        "en": "Narration style change applies from your next episode.",
        "es": "El cambio de estilo de narración se aplica desde tu próximo episodio.",
    },
    "profile_length_applies": {
        "en": "Max length change applies from your next episode.",
        "es": "El cambio de duración máxima se aplica desde tu próximo episodio.",
    },
    "profile_language_applies": {
        "en": "Language updated for the app, the voice and the news immediately; episodes reflect it from the next one.",
        "es": "Idioma actualizado de inmediato para la app, la voz y las noticias; los episodios lo reflejan desde el próximo.",
    },
    "profile_delivery_updated": {
        "en": "Delivery time updated — your next episode arrives {when} ({tz}).",
        "es": "Hora de entrega actualizada: tu próximo episodio llega {when} ({tz}).",
    },
    "profile_timezone_updated": {
        "en": "Delivery timezone updated.",
        "es": "Zona horaria de entrega actualizada.",
    },
    # Onboarding confirmation
    "onboarding_first_episode_scheduled": {
        "en": "Your first episode arrives today at {time}, and every day after that.",
        "es": "Tu primer episodio llega hoy a las {time}, y todos los días después.",
    },
    "onboarding_first_episode_on_demand": {
        "en": "Your first episode will be ready by {eta} (about an hour from now). From tomorrow, every day at {time}.",
        "es": "Tu primer episodio estará listo a las {eta} (en cerca de una hora). Desde mañana, todos los días a las {time}.",
    },
    # Home suggestions
    "home_because_you_follow": {
        "en": "Because you follow {tag}",
        "es": "Porque sigues {tag}",
    },
    "home_explore": {
        "en": "Explore {tag}",
        "es": "Explora {tag}",
    },
}

# failure_code values on a failed generation job -> catalog message code
FAILURE_MESSAGE_CODES = {
    "budget_exceeded": "budget_exceeded",
    "ai_paused": "ai_paused",
}


def msg(code: str, language: Any = None, **fmt: Any) -> str:
    """Localized text for a catalog code. Unknown code -> the code itself (never raises)."""
    entry = MESSAGES.get(code)
    if entry is None:
        return code
    text = entry[language_for(language)]
    return text.format(**fmt) if fmt else text


def failure_message(code: str | None, language: Any = None) -> str | None:
    key = FAILURE_MESSAGE_CODES.get(code or "")
    return msg(key, language) if key else None
