FROM python:3.11-slim

# Every timestamp in this codebase is written with datetime.utcnow() (naive) into
# TIMESTAMPTZ columns — asyncpg/SQLAlchemy interprets a naive datetime using the
# PROCESS's OS timezone when writing it, not UTC. python:3.11-slim already defaults
# to UTC, so this is currently a no-op in production, but pinning it explicitly
# closes a real latent bug class (discovered while testing GenerationJob.eta against
# a non-UTC local dev machine: every naive timestamp silently shifts by the local
# UTC offset once written) rather than depending on the base image's default forever.
ENV TZ=UTC

WORKDIR /app

RUN apt-get update && apt-get install -y \
    build-essential \
    libpq-dev \
    tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
# Belt-and-suspenders alongside the apt tzdata package above: python:3.11-slim's
# Debian base may or may not ship /usr/share/zoneinfo depending on the exact image
# variant, and every ZoneInfo() call in this codebase (episode_generator._compute_eta,
# scheduler._due_candidates) silently falls back to a wrong default if it can't find
# tz data at all — including for the literal key "UTC" itself. The tzdata PyPI
# package makes zoneinfo work regardless of what the OS image provides.
RUN pip install --no-cache-dir tzdata

COPY backend/ .

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
