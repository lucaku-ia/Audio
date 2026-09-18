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
    && rm -rf /var/lib/apt/lists/*

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/ .

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
