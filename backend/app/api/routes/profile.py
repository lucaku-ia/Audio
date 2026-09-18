"""
Profile — System Contracts v0.1 + umbrella doc cross-cutting rule
("Language and name | Captured once in Login profile. Inherited by every
epic. Never asked again.") + Notifications & Settings PRD (Andrés, Draft v1).

`language` is copied from Cliente.idioma the first time the Profile row is
created (either at signup, or here in PUT if the row doesn't exist yet), so
the original PUT (Onboarding's read/write path, per its own docstring) still
never accepts it in the body — Onboarding doesn't re-ask it.

Settings CAN change it later though (Notifications & Settings PRD: "Settings
-> language: applies to UI immediately, episodes from the next one"), via
PATCH below. Cliente.idioma is the source of truth read by everything that
needs an immediate UI-language decision (onboarding labels/seeds, `auth.me`,
etc.), so PATCH updates both Cliente.idioma (immediate) and Profile.language
(read by the Generator for the next episode) together.

`signals` (completion/skip/rating, refinements, adoptions, dismissals) is
derived — never asked and never shown as a label (Request Management PRD
tenet). It's also not editable through this endpoint; the future
Player/Home will write it.

## Settings CRUD (PATCH) — Notifications & Settings PRD scope

PATCH below is the Settings-facing endpoint: partial updates only (unlike
PUT, which onboarding uses for a full initial write), and every changed
field returns a message stating when it applies, per the PRD tenet ("Every
change says when it applies... never silence").

Voice/narration style/max length -> "applies from your next episode" (no
timing computation needed, just a fixed statement per the PRD wording).
Language -> UI immediately (Cliente.idioma, read synchronously elsewhere),
episodes from the next one (Profile.language, read by the Generator).
Delivery time/timezone -> the PRD says "reschedules generation to T-60" and
the message must state the next episode's actual time, so this endpoint
computes it the same way Onboarding's `POST /onboarding/confirm` does: next
occurrence of that local time, today if still >= 60 minutes out, otherwise
tomorrow.

There is deliberately no scheduler call here. `app/services/scheduler.py`
does not exist on this branch (this branch is off plain `origin/main`; a
scheduler is being built in a separate, not-yet-merged PR). Per that other
PR's own design, the scheduler reads `Profile.delivery_time` fresh on every
tick rather than holding a per-customer schedule to invalidate — so writing
the new `delivery_time` to the DB here is the entire integration; there is
no explicit "reschedule" call to make, and nothing to build against
infrastructure this branch can't see or test.

Deferred, and why (Notifications & Settings PRD):
- Membership row: PRD says "visible, disabled, labelled Coming soon" — a
  disabled stub with no pricing and no CTA is a pure client-side rendering
  concern. There is nothing for a backend endpoint to serve.
- Biometric toggle: PRD marks it P1 and per-device (Face ID/fingerprint) —
  that's OS/device keychain state, not a server-side preference. Skipped
  entirely; nothing here to build.
- Push notification delivery (APNs/FCM) and the "permission state" flag:
  needs a push provider credential (Apple/Google) that doesn't exist and
  isn't something this session can create. The PRD also explicitly says
  permission state should be "read from OS on open; never cached as
  truth" — i.e. it should NOT be persisted server-side even once a push
  provider exists. So there's no notification-permission column here by
  design, not by oversight.
"""
from datetime import datetime, time as time_type, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_cliente
from app.db.session import get_db
from app.models.cliente import Cliente
from app.models.profile import Language, NarrationStyle, Profile

router = APIRouter(prefix="/profile", tags=["Profile"])


class ProfileBody(BaseModel):
    voice_id: str | None = None
    narration_style: NarrationStyle = NarrationStyle.news
    delivery_time: str | None = Field(default=None, pattern=r"^\d{2}:\d{2}$")  # "HH:MM"
    delivery_timezone: str = "America/Bogota"
    max_length_minutes: int | None = None  # None = no limit — ceiling, never a target (umbrella §8)


class ProfileOut(BaseModel):
    customer_id: str
    voice_id: str | None
    narration_style: str
    language: str
    delivery_time: str | None
    delivery_timezone: str
    max_length_minutes: int | None
    signals: dict


def _out(perfil: Profile) -> ProfileOut:
    return ProfileOut(
        customer_id=str(perfil.customer_id),
        voice_id=perfil.voice_id,
        narration_style=perfil.narration_style.value,
        language=perfil.language.value,
        delivery_time=perfil.delivery_time.strftime("%H:%M") if perfil.delivery_time else None,
        delivery_timezone=perfil.delivery_timezone,
        max_length_minutes=perfil.max_length_minutes,
        signals=perfil.signals or {},
    )


@router.get("", response_model=ProfileOut)
async def get_profile(
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    perfil = await db.get(Profile, cliente.id)
    if not perfil:
        raise HTTPException(404, "Profile not set up yet (Onboarding incomplete)")
    return _out(perfil)


@router.put("", response_model=ProfileOut)
async def update_profile(
    body: ProfileBody,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    hora = None
    if body.delivery_time:
        h, m = body.delivery_time.split(":")
        hora = time_type(int(h), int(m))

    perfil = await db.get(Profile, cliente.id)
    if not perfil:
        perfil = Profile(
            customer_id=cliente.id,
            language=Language(cliente.idioma),  # inherited from Cliente, not from the body — never re-asked
        )
        db.add(perfil)

    perfil.voice_id = body.voice_id
    perfil.narration_style = body.narration_style
    perfil.delivery_time = hora
    perfil.delivery_timezone = body.delivery_timezone
    perfil.max_length_minutes = body.max_length_minutes

    await db.commit()
    await db.refresh(perfil)
    return _out(perfil)


class SettingsBody(BaseModel):
    """Every field is optional — only the ones present in the request are changed."""
    voice_id: str | None = None
    narration_style: NarrationStyle | None = None
    language: Language | None = None
    delivery_time: str | None = Field(default=None, pattern=r"^\d{2}:\d{2}$")  # "HH:MM"
    delivery_timezone: str | None = None
    max_length_minutes: int | None = None
    clear_max_length: bool = False  # explicit flag — max_length_minutes=None alone is ambiguous with "not sent"


class SettingsOut(ProfileOut):
    messages: list[str]


def _next_episode_local_time(delivery_time, delivery_timezone: str) -> datetime:
    """Same T-60 next-occurrence rule as Onboarding's POST /onboarding/confirm:
    today at that local time if that's still >= 60 minutes away, otherwise tomorrow."""
    tz = ZoneInfo(delivery_timezone)
    now_local = datetime.now(tz)
    today_target = now_local.replace(
        hour=delivery_time.hour, minute=delivery_time.minute, second=0, microsecond=0
    )
    if (today_target - now_local).total_seconds() / 60 >= 60:
        return today_target
    return today_target + timedelta(days=1)


@router.patch("", response_model=SettingsOut)
async def update_settings(
    body: SettingsBody,
    cliente: Cliente = Depends(get_current_cliente),
    db: AsyncSession = Depends(get_db),
):
    """Settings CRUD, Notifications & Settings PRD. Partial update; each changed
    field returns a message stating when it applies — see the module docstring."""
    campos = body.model_fields_set

    perfil = await db.get(Profile, cliente.id)
    if not perfil:
        raise HTTPException(404, "Profile not set up yet (Onboarding incomplete)")

    mensajes: list[str] = []

    if "voice_id" in campos:
        perfil.voice_id = body.voice_id
        mensajes.append("Voice change applies from your next episode.")

    if "narration_style" in campos and body.narration_style is not None:
        perfil.narration_style = body.narration_style
        mensajes.append("Narration style change applies from your next episode.")

    if "max_length_minutes" in campos or body.clear_max_length:
        perfil.max_length_minutes = None if body.clear_max_length else body.max_length_minutes
        mensajes.append("Max length change applies from your next episode.")

    if "language" in campos and body.language is not None:
        perfil.language = body.language
        cliente.idioma = body.language.value  # source of truth for immediate UI-language reads
        mensajes.append("Language updated for the app immediately; episodes reflect it from the next one.")

    if "delivery_time" in campos or "delivery_timezone" in campos:
        if body.delivery_timezone:
            try:
                ZoneInfo(body.delivery_timezone)  # validate before persisting — an invalid
            except ZoneInfoNotFoundError:          # IANA name would otherwise only fail later,
                raise HTTPException(400, f"Unknown timezone: {body.delivery_timezone!r}")  # as a 500 in the Generator/scheduler
            perfil.delivery_timezone = body.delivery_timezone
        if body.delivery_time:
            h, m = body.delivery_time.split(":")
            perfil.delivery_time = time_type(int(h), int(m))

        if perfil.delivery_time:
            next_at = _next_episode_local_time(perfil.delivery_time, perfil.delivery_timezone)
            mensajes.append(
                f"Delivery time updated — your next episode arrives "
                f"{next_at.strftime('%A %H:%M')} ({perfil.delivery_timezone})."
            )
        else:
            mensajes.append("Delivery timezone updated.")

    if not mensajes:
        raise HTTPException(400, "No settings fields were provided.")

    await db.commit()
    await db.refresh(perfil)
    out = _out(perfil).model_dump()
    out["messages"] = mensajes
    return SettingsOut(**out)
