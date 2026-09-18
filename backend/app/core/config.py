import os
from pathlib import Path
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    SECRET_KEY: str = os.getenv("SECRET_KEY", "change_this_in_production")
    # "Session persists across app restarts until the customer explicitly logs out" — Login PRD §4
    ACCESS_TOKEN_EXPIRE_DAYS: int = 30

    # Where the Episode Generator writes synthesized audio and where FastAPI serves
    # it from (app.main mounts this at /media). NOTE: this is local container disk,
    # not object storage — it does not survive a redeploy or restart. Fine for the
    # pilot's on-demand testing; replace with S3/R2/etc. before this is relied on for
    # a customer's actual daily episode.
    MEDIA_DIR: Path = Path(os.getenv("MEDIA_DIR", "/tmp/lucaku_media"))
    # Used to build the public audio_url. Falls back to the known Railway URL so
    # audio still resolves without extra config; override via env if that changes.
    PUBLIC_BASE_URL: str = os.getenv("PUBLIC_BASE_URL", "https://audio-production-2a77.up.railway.app")

    # Shared-secret gate for internal-only endpoints (e.g. GET /api/internal/prompts).
    # No real admin auth/roles exist yet, so this is a stand-in: a single header value
    # checked against this env var, fail CLOSED (endpoint 404s) if it's unset, so an
    # internal route can never accidentally ship open. Named to match the equivalent
    # gate the Instrumentation dashboard PRD introduces, so the two are compatible
    # once both land on the same branch.
    INTERNAL_DASHBOARD_KEY: str | None = os.getenv("INTERNAL_DASHBOARD_KEY")

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
