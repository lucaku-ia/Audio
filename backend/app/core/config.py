import os
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    SECRET_KEY: str = os.getenv("SECRET_KEY", "change_this_in_production")
    # "Session persists across app restarts until the customer explicitly logs out" — Login PRD §4
    ACCESS_TOKEN_EXPIRE_DAYS: int = 30

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
