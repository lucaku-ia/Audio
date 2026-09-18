# Lucaku Audio

A personal research service delivered in audio: the customer says what they want to
know, Lucaku researches it, and delivers it spoken — the first time on demand, and
every day after that at the time the customer chose.

**This repo replaces Lucaku's previous focus** (a sales/purchasing/production platform
for manufacturing, now archived at `lucaku-ia/LUCAKU`, untouched). This is a new
product built from scratch.

This README is written as a handoff — read it top to bottom before making changes.

## TL;DR for anyone new to this repo

- **Backend**: fully built for every feature that doesn't need a new external credential. Live in production on Railway, real ElevenLabs TTS, real web-grounded research (Claude's `web_search` tool). See the status table below.
- **Mobile**: a real native iOS app (SwiftUI, not a wrapper) now exists — Login, Home, Player, Settings screens, all hitting the live backend. A real AVFoundation audio engine is merged (PR #18) and **proven to actually stream and play real audio** in the Simulator (verified via real `AVPlayer`/Core Audio log output, not a compile check) — but as of this writing it's only wired into a standalone debug view, not the real Player screen yet. That integration, plus wiring the real per-block Home data (API already merged via #14) and real transcript timestamps, is in progress — see "Mobile app (iOS)" below for the exact real-vs-mocked breakdown.
- **Design**: three screens (Home, Player, Search/Interests) are designed, approved, and share one consistent token system grounded in real Apple HIG/Spotify/Audible research rather than guesswork. Login has been through two rounds of direct founder feedback and is on a third pass focused on layout/composition ("weird organize"), grounded in real research on Spotify/Apple/Duolingo login patterns rather than another guess. Look-and-feel links are in "Design system" below.
- **What's blocking further progress that only the founder can unblock**: Google Cloud Console (OAuth client ID for Google Sign-In) and Apple Developer Program enrollment ($99/yr — needed for push notifications, real-device testing, and eventually App Store submission). Also still undecided: embeddings provider (Voyage AI vs. OpenAI) for the AI Platform's semantic index.

## Current status (as of 2026-09-18)

Backend fully built (see table below); a real native iOS client now exists too — see
"Mobile app (iOS)" further down. Backend live in production on Railway:
`https://audio-production-2a77.up.railway.app` (`/health`, `/docs` for interactive API docs).

| Module | Status | Files | Source PRD |
|---|---|---|---|
| Login (signup/login/logout/me, JWT + revocation) | ✅ Built & deployed | `app/api/routes/auth.py`, `app/models/cliente.py` | Login PRD (Juan, Draft v2) |
| Request Management (CRUD + versioning) | ✅ Built & deployed | `app/api/routes/requests.py`, `app/models/request.py` | Request Management PRD (Andrés, Draft v1) |
| Profile (voice, narration style, delivery time, length) | ✅ Built & deployed | `app/api/routes/profile.py`, `app/models/profile.py` | Request Management / Onboarding |
| Onboarding (resumable state, interests, seed-list suggestions, T-60 confirmation) | ✅ Built & deployed | `app/api/routes/onboarding.py`, `app/models/onboarding.py`, `app/data/onboarding_seeds.json` | Onboarding PRD (Andrés, Draft v4) |
| AI Platform — `structure_request` + `research_and_write_block` (structuring, safety screen, research+writing) | ✅ Built & deployed | `app/services/ai_platform.py` | AI Platform PRD (Andrés + Juan, Draft v1) |
| AI Platform — prompt registry (DB-backed prompt versioning, fail-safe fallback, `GET /api/internal/prompts`) | ✅ Built & deployed | `app/models/prompt_registry.py`, `app/services/prompt_registry.py`, `app/api/routes/internal.py` | AI Platform PRD (Andrés + Juan, Draft v1) |
| Episode Generator — shared pipeline (load → research+write → assemble → trim → headline → voice → publish), on-demand and scheduled paths, idempotent per (customer, date, path) | ✅ Built & deployed, **with working TTS** | `app/services/episode_generator.py`, `app/api/routes/generation.py`, `app/services/scheduler.py` | Episode Generator PRD (Juan, Draft v1) |
| Event, AICall | Data model, actively written by the AI Platform and Generator; event names audited against the Instrumentation PRD's own catalogue | `app/models/instrumentation.py` | Instrumentation & Cost / AI Platform |
| Request refine() + Player rating | ✅ Built & deployed | `app/api/routes/requests.py` (`/refine`, `episodes_router`) | Request Management / Player PRD |
| Home — banner state machine (with real ETA + late-job detection) + recent episodes + shared-inventory empty-day matches | ✅ Built & deployed. Suggestions still deferred — needs the AI Platform's semantic index | `app/api/routes/home.py` | Home PRD (Andrés, Draft v1) |
| Instrumentation dashboard — cost/event/funnel endpoints, shared-secret gated | ✅ Built & deployed | `app/api/routes/instrumentation.py` | Instrumentation & Cost PRD (Andrés, Draft v1) |
| Notifications & Settings — Settings CRUD (voice/style/language/delivery time/max length, each with a "when it applies" message) + Account & data (export, cascading delete) | ✅ Built & deployed, push delivery and membership/biometrics deferred (see scope note) | `app/api/routes/profile.py` (PATCH), `app/api/routes/account.py` | Notifications & Settings PRD (Andrés, Draft v1) |
| Search & AI — history + PostgreSQL full-text keyword search (headlines/block summaries/request text) | ✅ Built & deployed. Natural-language Q&A deferred — needs the AI Platform's semantic index | `app/api/routes/search.py` | Search & AI PRD (Juan, Draft v1) |
| Player | Not started — no code anywhere yet, beyond the rating/refine backend above | — | — |

Everything above has been **tested end-to-end against the live production deployment**,
not just locally — see "Verifying a change" below for how to do the same. Most recently:
signup → create request → `POST /generation/run` against production on 2026-09-18,
confirming a real episode gets researched (live web search), written, trimmed, **voiced
via ElevenLabs**, and published — a real playable MP3, not just a script. See "Episode
Generator scope" below for exactly what's built vs. deferred.

**Durable audio storage**: `MEDIA_DIR` points at `/data/media`, a Railway persistent
volume attached to the Audio service — survives redeploys, unlike the plain container
disk it used before.

**Scheduled generation + idempotency** (merged via PR #1): a real T−60
per-customer-timezone scheduler (`app/services/scheduler.py`, in-process asyncio, no
new infra), plus a DB-level uniqueness fix so `/generation/run` can't produce two
episodes for the same customer/day. Included a critical migration-safety fix (verified
against a real local Postgres): backfilling a `UNIQUE` constraint onto a table with
pre-existing rows can crash startup if not handled carefully — it dedups first and
isolates the attempt in its own savepoint.

**Request refine() + Home + Instrumentation dashboard** (merged via PR #2),
**pending-version promotion + Search & AI + Notifications/Settings** (merged via
PR #3), the **AI Platform prompt registry** (merged via PR #4), and the
**Instrumentation event catalogue audit** (this branch, PR #5 — fixed event-naming
gaps against the Instrumentation PRD's own catalogue) are all reflected directly in
the status table above. As of this branch merging, every PR from this session's
batch of parallel work is in `main`.

PRs #1 through #4 were reviewed by a separate adversarial pass focused on security
and cross-customer data isolation before merging — findings from those reviews were
fixed in the branches themselves, not left as follow-up items, except where
explicitly noted as a documented, lower-priority gap. This branch's own contents
(the event catalogue audit) have not had that extra pass — worth one if anything
here is relied on for real cost/funnel decisions before it gets one.

**Still genuinely not started, PRD-read but no code**: the AI Platform's shared
semantic index (a design decision, not a quick patch — needs an embeddings-provider
choice), the actual mobile client, Google/Apple OAuth for Login, push notification
delivery (needs an APNs/FCM credential), and the mobile-platform decision itself
(§12 of the Umbrella PRD, still open).

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
  services/     Cross-cutting logic (ai_platform.py, episode_generator.py, scheduler.py, events.py)
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

**Update:** the prompt registry is now built too — `app/models/prompt_registry.py`
(the `PromptVersion` table) and `app/services/prompt_registry.py`
(`get_active_prompt` / `seed_prompt_registry`). `structure_request` and
`research_and_write_block` now fetch their system prompt text and version from the
DB (the active `PromptVersion` row for their name) instead of the hardcoded
`*_SYSTEM`/`*_VERSION` module constants directly — those constants still exist and
are now the seed data (loaded into the table on first boot, in `app/main.py`'s
lifespan) and the safety fallback if a lookup ever comes up empty (missing/deactivated
row), which logs a warning and returns the hardcoded prompt rather than raising and
breaking request creation. `GET /api/internal/prompts` lists every prompt's active
version and full text, gated by `require_internal_dashboard_key`
(`app/api/deps.py`) — a shared-secret header pattern, fail-closed if
`INTERNAL_DASHBOARD_KEY` is unset, named to match the equivalent gate the
(separate, not yet merged) Instrumentation dashboard PR introduces. Still explicitly
NOT built: the shared semantic index (needs an embeddings provider decision — a new
external API credential or a local model — not made here) and evals (running a
prompt candidate against history before activating it); the registry's shape is
meant to make evals buildable later without a data-model change, but no eval-running
logic exists yet.

**Requires `ANTHROPIC_API_KEY`** to be set (Railway Variables in production, `.env`
locally) or every `POST`/`PATCH /requests` call will fail with a 500
(`anthropic.AuthenticationError`) — this bit us once already, see git history.

### Episode Generator scope

Built: **both PRD paths, sharing one pipeline** — load → research+write (per active
request, via `ai_platform.research_and_write_block`, which uses Claude's server-side
`web_search` tool) → assemble → trim to the customer's `max_length_minutes` ceiling →
headline → voice → publish.

- **On-demand**: `POST /api/generation/run` runs the pipeline synchronously, in one
  request, for the calling customer. Verified against production: an empty-news topic
  correctly returns `status: "empty"` with no episode (the PRD's "never fill" tenet); a
  genuinely current topic produces a real Episode with sourced, cited blocks.
- **Scheduled**: `app/services/scheduler.py` runs an in-process asyncio ticker (started
  from `app.main`'s lifespan, no new infra/dependency), waking up once a minute to find
  every onboarded customer with an active `Request` whose `Profile.delivery_time` is
  ~60 minutes away in their own `Profile.delivery_timezone`, and calling the same
  `run_generation(..., path=EpisodePath.scheduled)` the on-demand route uses — the PRD's
  "they share the pipeline and differ only in trigger and latency budget," confirmed by
  the fact that adding this path took zero pipeline-logic changes. See that module's
  docstring for what's simplified (closest-minute granularity; no distributed lock, so
  this would double-fire customers if this service is ever scaled past its current
  single Railway replica).
- **ETA + late-job watchdog**: every job gets a real `job.eta` on creation
  (`episode_generator._compute_eta` — on-demand: +60 min from creation; scheduled: the
  customer's actual `Profile.delivery_time`, not a relative offset). The same
  scheduler tick also runs `check_late_jobs`, which relabels (never cancels — there's
  no clean way to kill an in-flight synchronous `run_generation`) any non-terminal job
  past `eta` + the PRD's +30 min hard limit to `JobStatus.late`, with a fresh ETA and a
  `job_late` event — closing the PRD's "+30 min hard limit, stated plainly if missed"
  now that Home exists to show it.
- **Idempotent** per (customer, date, path): a second call for the same customer/day/path
  returns the existing job unchanged rather than creating a duplicate episode. Enforced
  both in-app (a SELECT before the INSERT, with the resulting race on concurrent calls
  caught and recovered rather than surfaced as a 500) and at the DB level (a
  `UniqueConstraint` on `generation_jobs`, backfilled onto the existing production table
  via `app/db/migraciones.py`'s `INDICES_ESPERADOS` list — see "The recurring migration
  gotcha" below, the same pattern applies to indexes as to columns). Since this table had
  zero duplicate protection before this shipped, the backfill migration also dedups any
  pre-existing (customer_id, fecha, path) collisions before adding the index, and the
  index attempt is isolated in its own savepoint so a problem there logs an error and
  boots without the index rather than crashing the app.

Voicing (TTS) is wired via ElevenLabs (`ai_platform.synthesize`) — **requires
`ELEVENLABS_API_KEY`** (Railway Variables / `.env`, see `.env.example`; the key needs
**Text to Speech** and **Voices: Read** access — the latter is used by
`_default_voice_id()` to pick a voice the account can actually use via the API, since
a hardcoded well-known voice ID can 402 on accounts without a paid plan or that voice
in their library). Without a key, `ai_platform.elevenlabs_configured()` is false and
the job degrades gracefully: the episode still publishes with its full script,
`audio_url` stays null, and the job parks at `status: "voicing"` instead of `"ready"`.
A TTS call that fails once the key *is* set is also non-fatal — the text episode still
publishes; check `job.stages` for a `{"stage": "voicing", "error": ...}` entry.
**Verified working end-to-end against production on 2026-09-18**: real ElevenLabs
audio, valid MP3, playable.

Audio is written to `settings.MEDIA_DIR` and served at `/media/{episode_id}.mp3`. In
production this is `/data/media`, a **Railway persistent volume** attached to the
Audio service (added 2026-09-18) — survives redeploys and restarts, unlike the plain
container disk it used before. Still single-instance storage, not object storage;
revisit with S3/R2/etc. only if this service ever needs more than one replica.

**Cost per stage**: `job.stages` entries (research/assemble/voicing) and their matching
`stage_completed` events now carry real `cost`, not just latency — summed from the
actual `AICall` rows each stage incurred (`ai_platform._log_call` returns the cost it
just logged; `research_and_write_block`/`synthesize` pass it back up, accumulated
across every call in a stage's loop). Surfaced in the Instrumentation dashboard's
`/generation-funnel` as `cost_by_stage`. No `ai_platform` function's public *business*
parameters changed — only what they return — so this didn't need the signature
changes an earlier pass judged out of scope.

**Shared inventory**: samples for common interest clusters now exist, generated by the
same pipeline with one persistent synthetic `Cliente` per tag
(`shared-inventory+{tag}@system.lucaku.internal`) — see
`app/data/shared_inventory_seeds.json` for the seed content, which is a **real,
usable placeholder**, not the team-curated set the PRD describes (no team was
available to curate real content in this session — that's still an open task).
Triggered manually via `POST /internal/generate-shared-inventory` (same gate as the
other internal-only endpoints). Home's empty-day state now returns up to 3 matching
shared episodes with an honest `reason` ("Because you follow {tag}"); customers with
no matching interest correctly get nothing, never a guess. Synthetic customers are
excluded from the Instrumentation dashboard's `by_customer` cost breakdown (their
spend still counts in `total_cost`) and from every other customer-facing list, by
construction. Onboarding's own day-zero sample wiring is a smaller follow-up, not
done in this pass — the same query Home uses is ready to be reused there.

Deferred, and why (see the relevant module's own docstring for detail):
- **Real per-block timestamp alignment** — ElevenLabs' character-level timing needs a
  separate `/with-timestamps` endpoint, not used here; block offsets still come from
  the word-count estimate, so expect some drift against the real audio.
- **Real novelty judgment** ("new since we last told this customer") — needs the AI
  Platform's shared semantic index, which doesn't exist; today it only judges "new
  today" in isolation, so a slow-moving topic can repeat itself day to day.
- **Distributed locking for the scheduler** — fine at 1 replica (current), would
  double-fire customers at 2+; see `app/services/scheduler.py`'s docstring.
- **Real, team-curated shared-inventory content** — the pipeline and seed-list
  infrastructure exist; the actual content is still a placeholder (see above).

### Notifications & Settings scope

Built: `PATCH /api/profile` (Settings CRUD — partial updates to voice_id,
narration_style, language, delivery_time/delivery_timezone,
max_length_minutes, each returning a message stating when the change
applies, per the PRD tenet "every change says when it applies... never
silence"); `GET /api/account/export` (JSON of the customer's Requests with
version history and Episodes with Blocks); `DELETE /api/account`
(cascading deletion across Profile/OnboardingState/Request/RequestVersion/
Episode/Block/GenerationJob, with Events anonymized rather than deleted).
See the module docstrings in `app/api/routes/profile.py` and
`app/api/routes/account.py` for the exact deletion order and reasoning.

Deferred, and why:
- **Push notification delivery** (APNs/FCM) — needs an Apple/Google push
  provider credential that doesn't exist in this repo and isn't something
  that can be set up without those consoles, same pattern as Google/Apple
  OAuth below. The PRD's notification-permission-state flag is also
  deliberately NOT persisted server-side — the PRD itself says permission
  state should be read from the OS on open and never cached as truth.
- **Biometric toggle** — per-device Face ID/fingerprint state; this is a
  client/OS keychain concern, not a server-side preference. Nothing to
  build on the backend.
- **Membership row** — PRD says "visible, disabled, labelled Coming soon,"
  a pure client-side stub with no pricing/CTA. Nothing to build.
- **Confirmation email** on account deletion — needs an email-sending
  provider/credential that isn't configured (no SMTP/SES/Postmark
  settings exist anywhere in this repo). The deletion and cascade
  themselves are fully built; only the email notice is deferred.
- **Scheduler integration for delivery-time changes** — the PRD calls for
  "reschedules generation to T-60," but there's no scheduler in this repo
  yet (`app/services/scheduler.py` doesn't exist here; it's being built in
  a separate, not-yet-merged branch). That other design reads
  `Profile.delivery_time` fresh every tick rather than holding a schedule
  to invalidate, so writing the new time to the DB (already done) is the
  entire integration — there's nothing else to build against
  infrastructure this branch can't see.
- Verified locally against a real Postgres instance: seeded a full
  customer (Cliente, Profile, OnboardingState, Request, RequestVersion,
  Episode, Block, GenerationJob, Event) and ran the deletion logic for
  real — every table was cleaned up in the right order with no foreign-key
  violation, and the Event row ended up anonymized (`customer_id = NULL`)
  rather than removed.

### The recurring migration gotcha

SQLAlchemy's `create_all()` (run on every startup, see `app/main.py` lifespan) only
creates **missing tables** — it never alters columns (or adds constraints/indexes) on
tables that already exist. This has caused a production crash twice already (once in
the manufacturing project, once here with `Cliente.intentos_fallidos`). The fix in
place: `app/db/migraciones.py` has a declarative `COLUMNAS_ESPERADAS` list of
`(table, column, sql_type)` applied as idempotent `ALTER TABLE` statements, and an
`INDICES_ESPERADAS` list of `(table, index_name, CREATE INDEX statement)` applied the
same idempotent, check-then-create way, both run after `create_all()`.

**Any time you add a column to an existing model, add a row to `COLUMNAS_ESPERADAS`;
any time you add a constraint or index to an existing table, add a row to
`INDICES_ESPERADAS`,** in the same commit — or the next deploy will crash (missing
column) or silently not enforce what you added (missing index/constraint) the moment
it's relied on. Brand-new tables don't need an entry in either list — `create_all()`
already creates them complete.

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
  scope" above); it needs **Text to Speech** and **Voices: Read** access when
  restricted. `MEDIA_DIR=/data/media` is set to match the `audio-media` persistent
  volume attached to this service — don't remove either without the other, or audio
  writes fall back to ephemeral disk again.

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
  freshness, never-fill, trim-to-ceiling, shared inventory, cost per stage. Both paths
  built, idempotent, voiced; see "Episode Generator scope" above for exactly what's
  still deferred (shared inventory, real novelty judgment, the +30 min late-job surface).

- **Notifications & Settings PRD** (Andrés, Draft v1) — one push a day tied to
  the episode, and a single settings screen for every "changeable later"
  decision from other PRDs, plus account export/delete. Settings CRUD and
  Account & data are built; push delivery, biometrics, and the membership
  stub are deferred — see "Notifications & Settings scope" above.

Not yet read in this pass: Search & AI, Instrumentation dashboard PRDs — find
and read them before starting that module.

## Mobile app (iOS)

**Platform decision made**: native iOS first (SwiftUI, not a hybrid/wrapper —
Android is planned later, not started). Lives at `ios/LucakuAudio/` in this repo, a
real Xcode project (not a stub) that builds clean (`xcodebuild ... build` →
`BUILD SUCCEEDED`) and has been run live in the iOS Simulator against the real
production backend (real signup, real login, Home rendering real API data).

**Screens built and merged to `main`** (PR #13, consolidating what were separately
PR #9/#10/#11): Home, Player, Settings. **Audio engine merged** (PR #18, superseding
an earlier #17 that hit a real pbxproj merge conflict against #13 — rebuilt cleanly
on top of current `main` rather than force-merged). **Screens built, PR open, not
yet merged**: Login/Sign Up (PR #12, on its third pass — see "Design system" below).

**What's real vs. still mocked in the mobile app — read this before assuming
something works:**
- Real: signup/login/logout against the live backend; Home fetching and rendering
  real episode data; Settings reading/writing real profile fields (delivery time,
  timezone, narration style, voice, language) plus real account export/delete.
- Real: the audio engine itself (`Services/Audio/AudioPlayerService.swift`,
  merged) — genuinely streams and plays a real ElevenLabs-voiced MP3 from the live
  backend, background playback, lock-screen controls, all verified via real
  `AVPlayer`/Core Audio log output in the Simulator, not just a compile check.
- **Not real yet — the actual gap now**: the engine above is only reachable from
  a standalone debug view (`Features/AudioDemo/AudioEngineDemoView.swift`), not
  from the real Player screen. `PlayerViewModel`'s transport is still driven by a
  local fake timer as of `main`. Wiring this is in progress (see open PRs below).
- Transcript word-highlighting in the Player is a mocked proportional approximation,
  not real word-level sync. Real ElevenLabs word timestamps exist server-side in an
  open, unmerged PR (#15, still needs a live ElevenLabs call to verify); client-side
  wiring for it is also in progress, built against #15's documented shape.
- Refine/follow-up/rate-this-answer buttons in the Player are inert UI — the
  backend endpoints exist (`/refine`, rating), the mobile screens don't call them
  yet.
- Home's block list currently renders one aggregate "whole episode" row on `main`.
  The backend fix is merged (`GET /api/home` now returns real per-block data, #14)
  but wiring it into `HomeView`/`HomeViewModel` is in progress (see open PRs below).

**Open PRs, in build order** (read each PR's own description for exact
scope/verification before merging):
- **#12** — Login/Sign Up, now on a third pass specifically targeting layout/
  composition after founder feedback that it still "feels weird organized" —
  grounded in real research on Spotify/Apple/Duolingo login patterns, not another
  guess. Google Sign-In button's action is still a stub (no real OAuth wired,
  see blockers below).
- **#15** — Real word-level transcript timestamps via ElevenLabs' `with-timestamps`
  endpoint, stored on `Block.word_timestamps`. Still not verified against a live
  ElevenLabs call as of this writing — verify before merging.
- A PR wiring the real audio engine (#18) into the actual Player screen — check
  `gh pr list` for its current number, may still be in progress as of this writing.
- A PR wiring the real per-block Home API (#14) into `HomeView` — same, check
  `gh pr list` for current number/status.
- A PR wiring #15's real transcript timestamps into the Player's transcript view
  (built against #15's documented shape; its own real-timestamp path can't be
  fully verified until #15 itself is verified and merged) — same, check `gh pr
  list`.

**Verification method used so far**: real `xcodebuild` builds (this machine has
Xcode with an accepted license and an installed iOS 27 Simulator runtime), real
installs/launches in the Simulator, and real signup/login/Home-fetch/audio-playback
round-trips against the live production API — not just "it compiles." Do the same
for new mobile work rather than trusting a compile check alone. Also worth knowing:
PR #17→#18 is a real example of why — two branches independently hand-editing the
same `project.pbxproj` (this Xcode project predates synchronized-folder groups)
produced a genuine merge conflict days apart; don't assume a clean individual PR
merges cleanly against a moving `main` without checking.

## Design system

Three screens are designed and mutually consistent (same color/type/spacing/radius
tokens, reconciled after an initial mismatch was caught): Home, Player, and
Search/Interests. All three are grounded in real, cited research (not guessed
numbers) — see `RESEARCH_APPLE_MUSIC.md`, `RESEARCH_SPOTIFY.md`, and
`RESEARCH_AUDIBLE_PODCASTS.md` for the sourced findings (exact Apple HIG type
scale, the Apple Podcasts chapter-list pattern used as the model for Lucaku's
"list of answers, not a timeline" block navigation, etc.) and `DESIGN_SPEC_V3.md`
for the synthesized spec these screens were built from. These files aren't
committed to this repo (they were produced as local design artifacts this
session) — ask if you need them moved in.

**player_v3.html's `:root` token block is the canonical source of truth** for
every color and radius value used anywhere in the app — the Swift translation
(`ios/LucakuAudio/LucakuAudio/DesignSystem/`) was derived directly from it.
Do not introduce a new accent color or background value without updating that
file first.

Look and feel, live (click through, toggle light/dark and content states in the
top-right control on each):
- Home: https://claude.ai/artifact/X6Hp5ns1kpVpi3ktj81zoZ
- Player: https://claude.ai/artifact/JvLPUDmZNZ6kZdh3zbbecn
- Search & Interests: https://claude.ai/artifact/RtEp2cpi65gtpurbXDKLi4

**Login/Sign Up has been through three rounds of direct, sharp founder feedback**:
round one criticized the bare, unstyled scaffold entirely (no logo, no hierarchy);
round two criticized the first redesign for a duplicate mode-switch control (a
segmented toggle at top AND a same-labeled button at bottom) and the lack of a
real Google Sign-In option — both fixed, including a follow-up fix for the
Google "G" mark itself rendering blurry (it was hand-drawn with overlapping
SwiftUI `Canvas` strokes; replaced with Google's actual vector mark asset).
Round three feedback was more specific: it still "feels weird organized" despite
the components themselves being right — this is a composition/hierarchy problem,
not a missing-component problem, and the current pass is grounded in real research
on how Spotify/Apple/Duolingo structure login-screen layout rather than guessing
again. There is **no real Lucaku logo/brand mark yet** — the login screen uses a
typography-led wordmark treatment deliberately, since an earlier low-fidelity
brand system found in a sibling repo was explicitly rejected as not-good-enough
to reuse. If a real logo file exists or gets made, it should replace the wordmark.
The founder has said this screen is not the current top priority — don't over-invest
further polish here without checking first.

## Suggested next steps

1. **Merge the in-progress integration PRs** wiring the (already-merged) real audio
   engine into the Player screen, the (already-merged) real Home per-block API into
   `HomeView`, and #15's transcript timestamps into the Player's transcript view —
   check `gh pr list` for their current numbers/status as of when you're reading
   this. This is the single biggest gap between "compiles and looks right" and "is
   actually a working podcast app." See "Mobile app (iOS)" above.
2. **Verify #15 against a real live ElevenLabs call** before merging it — every
   other check has passed, but nobody has yet confirmed the actual timestamped API
   response round-trips correctly end to end.
3. **The AI Platform's shared semantic index** — the prompt registry is now built (see
   "AI Platform scope" above); the semantic index is the one remaining AI Platform
   piece, and it's the real blocker for novelty judgment, Search & AI's Q&A, and
   Home's suggestions. Needs an embeddings-provider decision (a new external API
   credential — e.g. Voyage AI or OpenAI embeddings — or a local model) first.
   **Still not decided as of this writing.**
4. **Shared inventory** — curated seed requests per interest cluster, to fill
   Onboarding's day-zero sample and Home's empty-day state.
5. **Google/Apple OAuth for real** — the login screen's Google Sign-In button is
   currently a visual stub. Needs the founder to create an OAuth client ID in
   Google Cloud Console, and separately enroll in the Apple Developer Program
   ($99/yr — also required for push notifications and real-device testing, not
   just Sign in with Apple). Neither can be done by an agent; both need the
   founder's own accounts.
6. **Push notifications** — blocked on the Apple Developer Program enrollment above
   (APNs) plus, for Android later, Firebase Cloud Messaging.
7. **Wire refine/follow-up/rating actions** in the Player screen to the backend
   endpoints that already exist.

Done as of 2026-09-18: ElevenLabs TTS verified working end-to-end in production; audio
storage moved to a durable Railway volume; Episode Generator scheduled path and
idempotency built (see "Episode Generator scope" above).
