# Lucaku Audio

A personal research service delivered in audio: the customer says what they want to
know, Lucaku researches it, and delivers it spoken — the first time on demand, and
every day after that at the time the customer chose.

**This repo replaces Lucaku's previous focus** (a sales/purchasing/production platform
for manufacturing, now archived at `lucaku-ia/LUCAKU`, untouched). This is a new
product built from scratch.

This README is written as a handoff — read it top to bottom before making changes.

## Current status (as of 2026-09-18)

Backend only, no UI yet. Live in production on Railway:
`https://audio-production-2a77.up.railway.app` (`/health`, `/docs` for interactive API docs).

| Module | Status | Files | Source PRD |
|---|---|---|---|
| Login (signup/login/logout/me, JWT + revocation) | ✅ Built & deployed | `app/api/routes/auth.py`, `app/models/cliente.py` | Login PRD (Juan, Draft v2) |
| Request Management (CRUD + versioning) | ✅ Built & deployed | `app/api/routes/requests.py`, `app/models/request.py` | Request Management PRD (Andrés, Draft v1) |
| Profile (voice, narration style, delivery time, length) | ✅ Built & deployed | `app/api/routes/profile.py`, `app/models/profile.py` | Request Management / Onboarding |
| Onboarding (resumable state, interests, seed-list suggestions, T-60 confirmation) | ✅ Built & deployed | `app/api/routes/onboarding.py`, `app/models/onboarding.py`, `app/data/onboarding_seeds.json` | Onboarding PRD (Andrés, Draft v4) |
| AI Platform — `structure_request` + `research_and_write_block` (structuring, safety screen, research+writing) | ✅ Built & deployed | `app/services/ai_platform.py` | AI Platform PRD (Andrés + Juan, Draft v1) |
| Episode Generator — on-demand path: load → research+write → assemble → trim → headline → voice → publish | ✅ Built & deployed, **with working TTS** | `app/services/episode_generator.py`, `app/api/routes/generation.py` | Episode Generator PRD (Juan, Draft v1) |
| Event, AICall | Data model, actively written by the AI Platform and Generator | `app/models/instrumentation.py` | Instrumentation & Cost / AI Platform |
| Home, Player, Search & AI, Notifications+Settings, Instrumentation dashboard | Not started on `main` — all built and in open PRs, see below | — | — |

Everything above has been **tested end-to-end against the live production deployment**,
not just locally — see "Verifying a change" below for how to do the same. Most recently:
signup → create request → `POST /generation/run` against production on 2026-09-18,
confirming a real episode gets researched (live web search), written, trimmed, **voiced
via ElevenLabs**, and published — a real playable MP3, not just a script. See "Episode
Generator scope" below for exactly what's built vs. deferred.

**Durable audio storage**: `MEDIA_DIR` points at `/data/media`, a Railway persistent
volume attached to the Audio service — survives redeploys, unlike the plain container
disk it used before.

### Open PRs — built, tested, reviewed, not yet merged

A large batch of work landed in one session (2026-09-18) as parallel, independently
built and reviewed branches, to keep `main` (which auto-deploys) stable while still
moving fast. **Merging is a human action someone needs to take** — read each PR's own
description for what it does and what an independent review pass found before merging.
They don't conflict with each other in code (noted per-PR where two touch the same
file, e.g. `app/core/config.py`), so merge order shouldn't matter much, but re-test
after each merge per "Verifying a change" below regardless.

- **[PR #1](../../pull/1) — Scheduled generation + idempotency.** A real T−60
  per-customer-timezone scheduler (`app/services/scheduler.py`, in-process asyncio,
  no new infra), plus a DB-level uniqueness fix so `/generation/run` can't produce two
  episodes for the same customer/day. Includes a critical migration-safety fix
  (verified against a real local Postgres): backfilling a `UNIQUE` constraint onto a
  table with pre-existing rows can crash startup if not handled carefully — it now
  dedups first and isolates the attempt in its own savepoint.
- **[PR #2](../../pull/2) — Request refine() + Player rating + Home backend +
  Instrumentation dashboard.** `POST /requests/{id}/refine` (the Player PRD's "less of
  this"/"go deeper"), `POST /episodes/{id}/rating`, `GET /api/home` (banner state
  machine + recent episodes), and four founder/ops-only cost/funnel endpoints under
  `/internal/instrumentation/*` (shared-secret gated, fails closed if unconfigured).
- **[PR #3](../../pull/3) — Pending-version promotion + Search keyword search +
  Notifications/Settings.** Closes PR #2's own documented gap: a refined request's
  pending version is now actually promoted to current at the next generation.
  `GET /api/search/history` + `GET /api/search/query` (PostgreSQL full-text search,
  real GIN indexes). `PATCH /api/profile`, `GET /api/account/export`,
  `DELETE /api/account` with a full deletion cascade (Events *and* AICall rows
  anonymized, not just deleted customer data).

Every PR above was built by a dedicated agent, independently verified
(`py_compile` + full app import at minimum; real local-Postgres testing for anything
migration- or SQL-risky), then reviewed by a separate adversarial pass focused on
security and cross-customer data isolation — findings from those reviews are fixed
in the PRs themselves, not left as follow-up items, except where explicitly noted in
the PR description as a documented, lower-priority gap.

**Still genuinely not started, PRD-read but no code**: the AI Platform's prompt
registry and shared semantic index (a design decision, not a quick patch — needs an
embeddings-provider choice), the actual mobile client, Google/Apple OAuth for Login,
push notification delivery (needs an APNs/FCM credential), and the mobile-platform
decision itself (§12 of the Umbrella PRD, still open).

## Read this before touching anything

1. **Find and read the PRD first.** Every module here was built from a PRD doc in the
   team's shared Drive folder (`Lucaku_<Module>_PRD.docx`), not improvised. Before
   extending a module or adding a new one, find its PRD and read it in full — PRDs are
   long (engineering notes at the bottom often matter more than the requirements table).
2. **Each module only implements what's buildable without epics that don't exist yet.**
   Every route/service file has a "scope note" docstring at the top explaining exactly
   what was deferred and why (usually: needs the AI Platform's shared index, or the
   Episode Generator, neither of which exists). Read that docstring before assuming
   something is missing by oversight rather than by design.
3. **All code, comments, and commits are in English.** Chat with the user can be in
   Spanish, but nothing written to this repo should be.
4. **Never run destructive git operations or push without being asked.**

## Architecture

FastAPI + SQLAlchemy 2.0 (async) + PostgreSQL — same stack as the archived
manufacturing project, reused for team familiarity. No client platform (mobile/web)
has been decided yet; several PRDs (Notifications, Login) assume a mobile app (iOS
with APNs, biometrics, `lucaku://play/{episode_id}` deep links) — that decision is
still open.

```
backend/app/
  models/       SQLAlchemy models — one file per System Contracts object
  api/routes/   FastAPI routers — one file per epic/module
  services/     Cross-cutting logic (ai_platform.py, events.py)
  db/           session.py (engine + URL normalization), migraciones.py (schema migrations)
  core/         config.py (Settings), security.py (JWT/password hashing)
  data/         static config, e.g. onboarding_seeds.json
```

### Auth model

JWT with a `token_version` claim on `Cliente`. Logout increments `token_version` in the
DB, which instantly invalidates every previously issued token — no session/blocklist
table needed. `get_current_cliente` (`app/api/deps.py`) checks the claim against the DB
on every request.

### Request versioning

`raw_text` on a `Request` is sacred — the system never overwrites it silently. Every
edit creates a new `RequestVersion` row; the previous one is marked `superseded`, never
deleted (System Contracts §3).

### AI Platform scope

The AI Platform PRD describes a much bigger system (prompt registry, shared semantic
index for Home/Search, evals, multi-provider fallback, budgets). Only its **first
delivery-order item** is built: a call wrapper with cost telemetry
(`app/services/ai_platform.structure_request`), because the PRD itself says this is
what unblocks Onboarding and Request Management. It calls Claude
(`claude-opus-5` via the official `anthropic` Python SDK, `messages.parse` with a
Pydantic output schema) to both structure a raw request into
`{topic, scope, geography, depth}` and screen it for safety, and logs every call —
including rejected ones — as an `AICall` row. Building the next PRD-priority item
(the prompt registry, to unblock the Generator) is the natural next AI Platform step
when picked back up.

**Requires `ANTHROPIC_API_KEY`** to be set (Railway Variables in production, `.env`
locally) or every `POST`/`PATCH /requests` call will fail with a 500
(`anthropic.AuthenticationError`) — this bit us once already, see git history.

### Episode Generator scope

Built: the **on-demand path only** — `POST /api/generation/run` runs
load → research+write (per active request, via `ai_platform.research_and_write_block`,
which uses Claude's server-side `web_search` tool) → assemble → trim to the
customer's `max_length_minutes` ceiling → headline → voice → publish, synchronously,
in one request. Verified against production: an empty-news topic correctly returns
`status: "empty"` with no episode (the PRD's "never fill" tenet); a genuinely current
topic produces a real Episode with sourced, cited blocks.

Voicing (TTS) is wired via ElevenLabs (`ai_platform.synthesize`) — **requires
`ELEVENLABS_API_KEY`** (Railway Variables / `.env`, see `.env.example`). Without it,
`ai_platform.elevenlabs_configured()` is false and the job degrades gracefully: the
episode still publishes with its full script, `audio_url` stays null, and the job
parks at `status: "voicing"` instead of `"ready"`. A TTS call that fails once the key
*is* set is also non-fatal — the text episode still publishes; check
`job.stages` for a `{"stage": "voicing", "error": ...}` entry. Audio is written to
`settings.MEDIA_DIR` (local container disk — **not** durable storage, doesn't survive
a redeploy; see the config's own note) and served at `/media/{episode_id}.mp3`.

Deferred, and why (see the module's own docstring for detail):
- **Real per-block timestamp alignment** — ElevenLabs' character-level timing needs a
  separate `/with-timestamps` endpoint, not used here; block offsets still come from
  the word-count estimate, so expect some drift against the real audio.
- **Durable audio storage** — needs real object storage (S3/R2/etc.) before this can
  be relied on beyond manual testing.
- **Real novelty judgment** ("new since we last told this customer") — needs the AI
  Platform's shared semantic index, which doesn't exist; today it only judges "new
  today" in isolation, so a slow-moving topic can repeat itself day to day.
- **Scheduled path** (T−60 cron per customer timezone) — infrastructure only, the
  pipeline itself is trigger-agnostic per the PRD.
- **Shared inventory** (day-zero/empty-day samples) — needs curated seed requests per
  interest cluster, none exist yet.
- **Idempotency** — calling `/generation/run` twice for the same customer/day currently
  produces two episodes; add a uniqueness check before wiring a real scheduler.

### The recurring migration gotcha

SQLAlchemy's `create_all()` (run on every startup, see `app/main.py` lifespan) only
creates **missing tables** — it never alters columns on tables that already exist. This
has caused a production crash twice already (once in the manufacturing project, once
here with `Cliente.intentos_fallidos`). The fix in place: `app/db/migraciones.py` has a
declarative `COLUMNAS_ESPERADAS` list of `(table, column, sql_type)` that's applied as
idempotent `ALTER TABLE` statements after `create_all()`.

**Any time you add a column to an existing model, add a row to
`COLUMNAS_ESPERADAS` in the same commit**, or the next deploy will crash with
`UndefinedColumnError` the moment that column is queried. Brand-new tables don't need
an entry — `create_all()` already creates them with every column.

## Running locally

```bash
cd backend
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt

copy .env.example .env
# fill in DATABASE_URL (a local Postgres), SECRET_KEY, and ANTHROPIC_API_KEY

uvicorn app.main:app --reload --port 8000
```

Interactive API docs at `http://localhost:8000/docs` once running.

## Deployment

Railway (backend service + a Postgres service), auto-deploys on push to `main`.

- The root-level `Dockerfile` is required — Railway looks for it at the repo root
  regardless of what `railway.json`'s `dockerfile` path says. Build context is the repo
  root, so `Dockerfile` does `COPY backend/ .`.
- `DATABASE_URL` gets normalized from Railway's plain `postgresql://` to
  `postgresql+asyncpg://` at startup (`_normalizar_database_url` in `app/db/session.py`)
  — without this, SQLAlchemy defaults to the sync `psycopg2` driver, which isn't
  installed, and startup crashes with `ModuleNotFoundError`.
- Railway service Variables needed in production: `DATABASE_URL` (usually
  `${{Postgres.DATABASE_URL}}`), `SECRET_KEY` (long random string — never reuse the
  placeholder in `.env.example`), `ANTHROPIC_API_KEY`. `ELEVENLABS_API_KEY` is optional
  — without it the Generator still runs, just without audio (see "Episode Generator
  scope" above).

### Verifying a change

There's no test suite yet — every module so far has been verified by deploying and
exercising the real endpoints with `curl` against the live Railway URL (signup a fresh
test user, drive it through the flow, check the responses match the PRD's acceptance
criteria). Do the same for new work: deploy, then curl it for real rather than trusting
that it compiles. Watch Railway's deploy logs (Deployments tab → the active deployment →
View Logs, or export as JSON) for the actual traceback if something 500s — that's been
the fastest way to find the real cause every time so far (an invalid API key, a missing
migration column, a wrong Docker path) rather than guessing.

## PRD status

All PRDs live as `Lucaku_<Module>_PRD.docx` in the team's shared Drive folder. Read in
full so far:

- **Login PRD** (Juan, Draft v2, proposed by Andrés) — mandatory login, 3 methods
  (Google/Apple/email — only email+password is built; Google/Apple need OAuth
  credentials from their consoles, same pattern as Gmail in the manufacturing project),
  per-device biometrics, routing via `onboarding_complete`.
- **Request Management PRD** (Andrés, Draft v1) — standing/one-off requests, raw_text
  versioning, pause/resume/archive. `refine()` and `adopt()` are explicitly NOT built —
  they depend on the Player, which doesn't exist.
- **Onboarding PRD** (Andrés, Draft v4) — interest picker → shape into requests →
  delivery time/length → voice/style → confirm → notifications → tour. The AI-dependent
  parts (`structure_request`'s one-line preview, day-zero sample matching to shared
  inventory) are deferred; see the scope note at the top of `onboarding.py`.
- **AI Platform PRD** (Andrés + Juan, Draft v1) — see "AI Platform scope" above.
- **Home PRD** (Andrés, Draft v1) — status banner, last 3 episodes, explainable
  suggestions, empty-day state, re-entry. Not started.
- **Player PRD** (Juan, Draft v1) — persistent bar + full player, block/request
  navigation, refinement, offline mode, OS media session. Not started.
- **Episode Generator PRD** (Juan, Draft v1) — two paths sharing one pipeline, T−60
  freshness, never-fill, trim-to-ceiling, shared inventory, cost per stage. On-demand
  path built; see "Episode Generator scope" above for exactly what's deferred.

Not yet read in this pass: Search & AI, Notifications+Settings, Instrumentation
dashboard PRDs — find and read them before starting that module.

## Suggested next steps

1. **Set `ELEVENLABS_API_KEY` in Railway** — voicing is wired (`ai_platform.synthesize`)
   but needs the key to actually run; until then episodes stay text-only. Once set,
   also move audio off local container disk onto real object storage (S3/R2/etc.) —
   see "Episode Generator scope" above.
2. **AI Platform, next delivery-order item** — the prompt registry (per the PRD's own
   §9 delivery order) and the shared semantic index, to unblock real novelty judgment
   and Search & AI.
3. **Home** and **Player** — both read already; Player is a hard dependency of Request
   Management's `refine()`, which is still unbuilt.
4. **Scheduled path + idempotency** for the Generator — cron at T−60 per customer
   timezone, plus a uniqueness check per (customer, date, path).
5. **Google/Apple OAuth** for Login — needs the user to create OAuth credentials in
   Google Cloud Console and the Apple Developer portal first.
6. **Mobile client platform decision** — still open, and several PRDs assume it's
   settled (push notifications, deep links, biometrics). Worth resolving before Home/
   Player go too far, since it affects their contracts.
