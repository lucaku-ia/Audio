# Lucaku Audio

A personal research service delivered in audio: the customer says what they want to
know, Lucaku researches it, and delivers it spoken — the first time on demand, and
every day after that at the time the customer chose.

**This repo replaces Lucaku's previous focus** (a sales/purchasing/production platform
for manufacturing, now archived at `lucaku-ia/LUCAKU`). This is a new product built
from scratch.

## Current status

Backend only, no UI yet. Implements the data objects defined in
`Lucaku_System_Contracts.docx` (v0.1), plus the business logic for the modules below.

| Module | Status | Files | Source PRD |
|---|---|---|---|
| Login (signup/login/logout/me, JWT + revocation) | ✅ Built & deployed | `app/api/routes/auth.py`, `app/models/cliente.py` | Login PRD (Juan, Draft v2) |
| Request Management (CRUD + versioning) | ✅ Built & deployed | `app/api/routes/requests.py`, `app/models/request.py` | Request Management PRD (Andrés, Draft v1) |
| Profile (voice, narration style, delivery time, length) | ✅ Built & deployed | `app/api/routes/profile.py`, `app/models/profile.py` | Request Management / Onboarding |
| Episode, Block | Data model only | `app/models/episode.py` | Episode Generator |
| GenerationJob, InventoryItem | Data model only | `app/models/generation_job.py` | Episode Generator |
| Event, AICall | Data model only | `app/models/instrumentation.py` | Instrumentation & Cost / AI Platform |
| Onboarding, Episode Generator, AI Platform, Search & AI, Home, Player, Notifications+Settings, Instrumentation dashboard | Not started | — | — |

## PRD status

All PRDs have been read and incorporated as reference:

- **Login PRD** (Juan, Draft v2, proposed by Andrés) — mandatory login, 3 methods
  (Google/Apple/email), per-device biometrics, routing via `onboarding_complete`.
- **Request Management PRD** (Andrés, Draft v1) — standing/one-off requests, raw_text
  versioning (old versions marked `superseded`, never overwritten), pause/resume/archive.
- **Home PRD** (Andrés, Draft v1) — status banner, last 3 episodes, explainable
  suggestions, empty-day state, re-entry.
- **Player PRD** (Juan, Draft v1) — persistent bar + full player, block/request
  navigation, refinement, offline mode, OS media session.

Still to be built in this repo: Onboarding, Episode Generator, AI Platform, Search & AI,
Notifications+Settings, Instrumentation dashboard. All depend on the data foundation
that's already here.

## Stack

FastAPI + SQLAlchemy 2.0 async + PostgreSQL — same stack as the manufacturing project,
reused for team familiarity. No client platform (mobile/web) has been decided yet;
several PRDs (Notifications, Login) assume a mobile app (iOS with APNs, biometrics,
`lucaku://play/{episode_id}` deep links) — that client-platform decision is still open.

## Running locally

```bash
cd backend
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt

# copy .env.example to .env and fill in DATABASE_URL

uvicorn app.main:app --reload --port 8000
```

## Deployment

Deployed on Railway (backend + Postgres). The root-level `Dockerfile` is required —
Railway looks for it at the repo root regardless of `railway.json`'s dockerfile path.
`DATABASE_URL` gets normalized from Railway's plain `postgresql://` to
`postgresql+asyncpg://` at startup (see `app/db/session.py`).

Schema changes to existing tables are NOT picked up by SQLAlchemy's `create_all()`
(it only creates missing tables). Any new column added to an existing model must be
added to `COLUMNAS_ESPERADAS` in `app/db/migraciones.py`, or it will crash in
production the way it did once already.
