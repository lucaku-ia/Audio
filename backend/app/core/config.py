import os
from pathlib import Path
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    SECRET_KEY: str = os.getenv("SECRET_KEY", "change_this_in_production")
    # "Session persists across app restarts until the customer explicitly logs out" — Login PRD §4
    ACCESS_TOKEN_EXPIRE_DAYS: int = 30

    # Where the Episode Generator writes synthesized audio and where FastAPI serves
    # it from (app.main mounts this at /media). In production this is set to
    # /data/media, a Railway persistent volume attached to the Audio service —
    # survives redeploys and restarts (fixed 2026-09-18; previously plain
    # container disk, wiped on every deploy). Locally it falls back to /tmp, which
    # is fine for dev since nobody expects local audio to persist across restarts.
    # Still single-instance, local-disk storage, not object storage — revisit with
    # S3/R2/etc. if this service ever needs to scale beyond one replica, since a
    # Railway volume is bound to a single instance.
    MEDIA_DIR: Path = Path(os.getenv("MEDIA_DIR", "/tmp/lucaku_media"))
    # Used to build the public audio_url. Falls back to the known Railway URL so
    # audio still resolves without extra config; override via env if that changes.
    PUBLIC_BASE_URL: str = os.getenv("PUBLIC_BASE_URL", "https://audio-production-2a77.up.railway.app")

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
