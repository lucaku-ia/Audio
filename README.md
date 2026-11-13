# Lucaku Audio

A personal research service delivered in audio: the customer says what they want to
know, Lucaku researches it, and delivers it spoken — the first time on demand, and
every day after that at the time the customer chose.

**This repo replaces Lucaku's previous focus** (a sales/purchasing/production platform
for manufacturing, now archived at `lucaku-ia/LUCAKU`, untouched). This is a new
product built from scratch.

This README is written as a handoff — read it top to bottom before making changes.

## Viewing the app on your iPhone without a Mac

No Mac and no Apple Developer Program membership needed. GitHub Actions builds an
unsigned `.ipa` on a free macOS runner; a free Windows tool called
[Sideloadly](https://sideloadly.io/) installs it on your iPhone via USB, signing it
with your own free Apple ID in the process.

1. Go to this repo on GitHub → **Actions** tab → **iOS sideload build (unsigned
   .ipa)** in the left sidebar → **Run workflow** (top right) → **Run workflow**
   again to confirm. It builds on a macOS runner — takes a few minutes.
   (`.github/workflows/ios-sideload-build.yml`, manual-only by design — macOS
   runner minutes are billed at 10x normal GitHub Actions minutes even on the
   free tier, so this doesn't run on every push.)
2. Once it finishes (green check), click into that run → under **Artifacts** at
   the bottom, download **LucakuAudio-unsigned-ipa** (a zip containing the
   `.ipa`).
3. Install [Sideloadly](https://sideloadly.io/) on Windows (also installs Apple's
   USB drivers if you don't already have iTunes/Apple Mobile Device Support).
4. Plug your iPhone into your PC via USB (trust the computer if prompted on the
   phone), open Sideloadly, drag the `.ipa` into it, enter your Apple ID (a free
   one is fine — Sideloadly doesn't need a paid Developer account) in the Apple
   ID field, and click **Start**.
5. On the iPhone: **Settings → General → VPN & Device Management** → tap your
   Apple ID under "Developer App" → **Trust**. Then open the Lucaku Audio app —
   it talks to the real production backend, so **Sign Up** creates a real
   account.

**Known limitation of the free-Apple-ID path**: apps installed this way expire
after **7 days** and need re-sideloading (re-run Sideloadly with the same `.ipa` —
no need to rebuild unless the code changed). This is an Apple platform limit, not
something fixable in this repo; it goes away once the founder enrolls in the paid
Apple Developer Program ($99/yr) and the app can be distributed via TestFlight
instead.

## TL;DR for anyone new to this repo

- **Backend**: fully built for every feature that doesn't need a new external credential. Live in production on Railway, real ElevenLabs TTS (word-level timestamps verified against a real live call, see "Episode Generator scope"), real web-grounded research (Claude's `web_search` tool). See the status table below.
- **Mobile**: a real native iOS app (SwiftUI, not a wrapper) exists. PR #27 (tab architecture fix + real Home/Search/Interests) is **merged** — #23–#26 are correctly closed without merging, superseded by it. Full detail in "Mobile app (iOS)" below.
- **Free-text AI-categorized interests: done, verified against production.** The previous session's isolated worktree (bad `ANTHROPIC_API_KEY`, never actually saw a categorization result) was abandoned rather than fixed — this was rebuilt directly against this repo's own working deployment instead, where the key already works. Backend: `RequestOut.structured` exposed, `GET /requests?kind=` filter added. iOS: a "Search for anything" field in Interests wired to `POST /requests`. Verified live: typing "Arsenal FC" categorizes to `{topic: "Arsenal FC", geography: null}`; "La Liga" to `{topic: "La Liga football", geography: "Spain"}` — exactly the two test cases the founder wanted to see. iOS changes are unverified by an actual Xcode build (no macOS access this session) — build-check before trusting in production.
- **Session-expiry gap: fixed.** An expired/invalid token used to leave every screen showing a silent "not signed in" error forever (`SessionStore.clear()` was only wired to the manual Log-out button). `APIClient` now posts a notification on any 401; `SessionStore` observes it and clears itself, so the app's existing auth-routing sends the customer back to Login automatically. Same Xcode-build caveat as above.
- **Design**: three screens (Home, Player, Search/Interests) are designed, approved, and share one consistent token system grounded in real Apple HIG/Spotify/Audible research rather than guesswork. Login has been through three rounds of direct founder feedback and the founder has said it's not the current priority — don't invest further there without checking first. Look-and-feel links are in "Design system" below.
- **What's blocking further progress that only the founder can unblock**: Google Cloud Console (OAuth client ID for Google Sign-In), and Apple Developer Program enrollment ($99/yr — needed for push notifications, real-device testing, and eventually App Store submission). Voyage AI is the decided embeddings provider (see "Suggested next steps") but the account/key still needs to be created.

## Current status (as of 2026-09-21)

Backend fully built (see table below); a real native iOS client now exists too — see
"Mobile app (iOS)" further down. Backend live in production on Railway:
`https://audio-production-2a77.up.railway.app` (`/health`, `/docs` for interactive API docs).

| Module | Status | Files | Source PRD |
|---|---|---|---|
| Login (signup/login/logout/me, JWT + revocation) | ✅ Built & deployed | `app/api/routes/auth.py`, `app/models/cliente.py` | Login PRD (Juan, Draft v2) |
| Request Management (CRUD + versioning) | ✅ Built & deployed | `app/api/routes/requests.py`, `app/models/request.py` | Request Management PRD (Andrés, Draft v1) |
| Profile (voice, narration style, delivery time, length) | ✅ Built & deployed | `app/api/routes/profile.py`, `app/models/profile.py` | Request Management / Onboarding |
| Onboarding — backend (resumable state, interests, seed-list suggestions, T-60 confirmation) | ✅ Built & deployed | `app/api/routes/onboarding.py`, `app/models/onboarding.py`, `app/data/onboarding_seeds.json` | Onboarding PRD (Andrés, Draft v4) |
| Onboarding — iOS (8-step guided flow, voice narration + dictation) | ✅ Built, compiles clean. **Not yet run on a device** | `Features/Onboarding/`, `Services/Voice/SpeechService.swift` | Onboarding PRD (Andrés, Draft v4) |
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
- ~~Real per-block timestamp alignment~~ — **done, verified 2026-09-19.** The
  `/with-timestamps` endpoint variant is wired (`ai_platform.synthesize`,
  `with_timestamps=True` by default) and a real production run returned real
  word-level spans (`{"word": "El", "start_s": 0.0, "end_s": 0.151}`, ...) on
  `GET /generation/episodes/latest`'s `blocks[].word_timestamps` — not just
  code that looked right, an actual ElevenLabs response round-tripped correctly.
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

### Onboarding (iOS)

Built 2026-09-21: the guided onboarding flow the app never had — signup used to
drop straight into the tab bar (no onboarding at all), which is what read as
"just a plain screen of text" to the founder. Now `ContentView` routes a
signed-in customer with `onboardingComplete == false` into `OnboardingView`
instead — matching the routing rule `TokenResponse`/`MeResponse` already carry.
A session restored from the Keychain (which only has the bearer token) confirms
the flag once via `GET /auth/me` (`SessionStore.refreshOnboardingStatus`) before
routing.

`OnboardingViewModel` is an 8-step state machine — consent (local-only, no
backend equivalent, gates `POST /onboarding/consent` per the PRD's Ley 1581 de
2012 requirement), interests, requests, delivery, sound, confirm, notifications,
tour — resumable against the real backend: `GET /onboarding/state` on launch
picks up wherever the customer left off, exactly like the PRD asks. One
asymmetry worth knowing: `delivery` and `sound` are two separate UI steps (per
the PRD's own two customer stories) but both write through the same
`PUT /api/profile` (`ProfileSetupBody` — a full write, not `SettingsBody`'s
partial PATCH), so each step's save resends every profile field the view model
is currently holding, not just its own — otherwise a later step's save would
silently blank out an earlier one's answer. Requests is the one non-skippable
step (≥1 standing request required, per the PRD's own tenet 3), backed by the
already-built `GET /onboarding/suggestions` per selected interest, plus a
free-text field for anything not on the list.

**Voice**, per the founder's explicit ask ("puedes poner voz... si uno no sabe
temas"): `Services/Voice/SpeechService.swift` wraps on-device
`AVSpeechSynthesizer` (every step's prompt has a speaker button that reads it
aloud) and `SFSpeechRecognizer` + `AVAudioEngine` (the free-text request field
has a mic button that dictates instead of typing). This is UI narration/
dictation only — not the Generator's ElevenLabs voice, which is what the
customer's actual daily episode sounds like. Requires
`NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription` in
Info.plist (added alongside).

One real build error, found and fixed via the GitHub Actions sideload workflow
(see "Verifying a change" below) rather than a local Xcode build: `ContentView`'s
routing was written as `switch session.onboardingComplete { case true: ... case
false: ... case nil: ... }` — Swift's exhaustiveness checker doesn't accept bare
`true`/`false`/`nil` patterns as provably covering `Bool?`, even though they do
in practice. Rewritten as `if`/`else if`/`else`.

`SpeechService`'s `recognitionTask` completion handler updates `@Published`
state from inside a `Task { @MainActor in ... }` — written correctly the first
time by applying the lesson from an earlier build error in
`AudioPlayerService.swift`'s KVO observers (Swift 6's "reference to captured
var 'self' in concurrently-executing code"): `[weak self]` is captured fresh on
the inner `Task` itself, not carried in from an outer closure.

**Not yet done**: UI localization (every string is hardcoded English for a
Spanish-speaking customer base — see item 7c in "Suggested next steps"), and
this has never been run on a real device — the mic/speech pieces specifically
can't be verified any other way (Simulator has no real microphone input).

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
on top of current `main` rather than force-merged). **Audio engine + real transcript
timestamps wired into the real Player screen, merged** (PR #22, consolidating #20 and
#21 — this also carried forward #15's backend work since #21 had branched off #15;
see "PR #15's real fate" below). **Tab architecture fixed + Home/Search/Interests
wired for real — built, live-verified, currently an open PR awaiting merge** (PR #27;
see "The overnight architecture fix" below). **Screens built, PR open, explicitly
deprioritized by the founder for now**: Login/Sign Up (PR #12, on its third pass —
see "Design system" below).

### The overnight architecture fix (PR #27)

A real, founder-caught bug: the app's tab bar had drifted from the approved design
(Home / Search / Interests / Settings, with the Player as a persistent overlay that
is never its own tab) into leftover scaffold structure (Home / Library / Player /
Settings) that nobody had gone back and corrected. This wasn't cosmetic — it caused
a real, user-visible bug where Home's mini-player showed a static "Playing" label
while the separate Player tab correctly showed "Paused," because the two screens
were reading from two disconnected pieces of state.

Four branches were opened to fix pieces of this (#23 tab architecture, #24 Interests
screen, #25 real Home blocks, #26 Search screen) and all four overlapped on the same
files (`ContentView.swift`, `HomeView.swift`, `project.pbxproj`). Rather than merge
them sequentially and fight conflicts each time, they were hand-consolidated into one
integration branch, **PR #27**, which:
- Rebuilds `ContentView.swift` to the real Home/Search/Interests/Settings tab bar.
- Makes `PlayerViewModel` a single `@StateObject` at the app root, injected via
  `.environmentObject()` — one source of truth for play/pause state instead of two.
  Deleted `Features/Home/MiniPlayerBar.swift` entirely (the old, second source).
- Wires real per-block Home data (from #14's API) into `HomeView` — live-verified: 3
  real generated topics rendered as 3 real rows, live highlight tracking through
  blocks 1→2→3 as playback advanced, tap-to-open working.
- Adds a real Search screen (episode history + keyword search via `/search`, "add as
  new interest" via `POST /requests`) and a real Interests screen (onboarding-catalogue
  add/remove; cadence/pause correctly left as disabled stubs since no backend field
  exists for them yet).
- Restores "generate episode now" — which lived on the old, now-removed Library tab —
  into Home's empty-day state instead of silently dropping it, reusing the same
  unchanged `POST /api/generation/run` call.

**Live-verified end-to-end tonight**: fresh login, added a real standing request,
tapped "Generate today's episode now," confirmed via a direct API call that the
backend genuinely ran generation (that particular topic honestly came back
`no_news` for the night — matches the PRD's "never fill" tenet, not a bug). Search
and Interests both loaded cleanly with real data, no crashes.

A separate, adversarial code review (not the live walkthrough above) then found and
fixed one real bug before this was called done: `LibraryViewModel.runGeneration()`
had no re-entrancy guard, so a fast double-tap on "generate now" could fire two
concurrent `POST /api/generation/run` calls. The backend's own idempotency prevented
actual data corruption, but the "losing" request returning early could flip the UI to
a misleading "finished" state while generation was still actually running. Fixed with
a synchronous guard-and-set check before the first `await`, verified with a clean
rebuild, pushed directly to #27.

That same review found, confirmed, and **deliberately did not fix** (correctly
scoped as a separate, pre-existing issue) a real gap worth prioritizing soon: a
stale/expired auth token doesn't route the user back to the Login screen — every
screen just shows a generic "not signed in" error forever. `SessionStore.clear()` is
only ever wired to the manual Settings "Log out" button, never to an actual 401
response anywhere else in the app. A real customer will eventually hit token expiry
and get stuck on this.

Two more things flagged but not fixed, both low-urgency: pausing playback mid-block
makes Home's "currently playing" row highlight disappear entirely (cosmetic, not a
data bug); and `Features/Home/PlayerListView.swift` (the old Player-tab-specific
screen) is now dead code since the Player tab no longer exists — safe to delete
later.

**Where this actually stands right now**: verified via the GitHub API directly
(`gh` isn't installed on this machine — used `Invoke-RestMethod` against
`api.github.com/repos/lucaku-ia/Audio/pulls` instead): **PR #27 is MERGED**
(2026-09-18T14:58:47Z), and **#23, #24, #25, and #26 are all correctly CLOSED
without merging**, superseded by it as intended. The "next session" action item
that used to be here is done — nothing left to merge/close from that batch.

### PR #15's real fate

#15 (real word-level transcript timestamps via ElevenLabs' `with-timestamps`
endpoint, `Block.word_timestamps`) was never merged on its own — **#21** (wiring
those timestamps into the Player) branched off #15 before it merged, and #21 was
itself folded into **#22** alongside the audio-engine wiring. So #22's merge to
`main` carried #15's backend changes along with it, and #15 was correctly closed
without a separate merge — it's superseded, not lost. **The one thing this does NOT
mean**: the actual ElevenLabs `with-timestamps` API call is still unverified against
a real, live ElevenLabs response. That verification gap is real and outstanding —
see "Suggested next steps" below.

**What's real vs. still mocked in the mobile app — read this before assuming
something works:**
- Real: signup/login/logout against the live backend; Home fetching and rendering
  real episode data (including real per-block rows, see above); Settings reading/
  writing real profile fields (delivery time, timezone, narration style, voice,
  language) plus real account export/delete; Search and Interests against the live
  backend (pending #27's merge).
- Real: the audio engine (`Services/Audio/AudioPlayerService.swift`) wired into the
  actual Player screen as of #22 — genuinely streams and plays a real
  ElevenLabs-voiced MP3, background playback, lock-screen controls.
- Real transcript timestamps are wired client-side as of #22, riding on #15's
  backend `Block.word_timestamps` field — but see "PR #15's real fate" above: the
  underlying ElevenLabs call itself is still not verified live.
- Refine/follow-up/rate-this-answer buttons in the Player are inert UI — the
  backend endpoints exist (`/refine`, rating), the mobile screens don't call them
  yet.
- **Known gaps as of tonight** (see "The overnight architecture fix" above for
  detail): expired-session tokens don't route back to Login (real bug, worth an
  early priority); pausing mid-block drops Home's highlight (cosmetic); dead
  `PlayerListView.swift` (safe to delete, not urgent).

**PR list, current reality** (verified via `api.github.com/repos/lucaku-ia/Audio/pulls`
on 2026-09-19 — `gh` isn't installed on this machine; re-check before relying on
this, PR state moves fast):
- **#27** — MERGED. The real, consolidated architecture fix described above.
- **#23, #24, #25, #26** — CLOSED without merging, each correctly superseded by
  #27's consolidation (not individually merged, which would have reintroduced the
  file conflicts #27 already resolved by hand).
- **#22** — MERGED. Real audio engine + real transcript timestamps wired into the
  actual Player screen (consolidates #20 and #21).
- **#21, #20** — CLOSED, superseded by #22.
- **#18** — MERGED. Real AVFoundation audio engine (superseded #17, which hit a real
  pbxproj conflict against #13).
- **#15** — CLOSED, superseded by #22 (see "PR #15's real fate" above) — not lost,
  but its live-ElevenLabs-call verification is still outstanding.
- **#14** — MERGED. Real per-block Home API.
- **#13** — MERGED. Home + Player + Settings screens (consolidating #9/#10/#11).
- **#12** — OPEN, not urgent. Login/Sign Up, third round of founder feedback
  addressed (see "Design system" below); founder said explicitly this isn't the
  current priority.

**Verification method used so far**: real `xcodebuild` builds (this machine has
Xcode with an accepted license and an installed iOS 27 Simulator runtime), real
installs/launches in the Simulator, and real signup/login/Home-fetch/audio-playback/
generation round-trips against the live production API — not just "it compiles." Do
the same for new mobile work rather than trusting a compile check alone. Also worth
knowing: PR #17→#18 is a real example of why — two branches independently
hand-editing the same `project.pbxproj` (this Xcode project predates synchronized-
folder groups) produced a genuine merge conflict days apart; don't assume a clean
individual PR merges cleanly against a moving `main` without checking. #27's own
four-way consolidation is the same lesson at a larger scale.

## Free-text AI-categorized interests (done, verified against production)

The founder wanted customers to be able to type free text into Interests (e.g.
"Arsenal FC") and have it auto-categorized instead of only picking from the fixed
8-category onboarding catalogue. The architecture question was settled in an
earlier session, against the actual `Lucaku_Onboarding_PRD.docx`: standing
`Request`s (already built, already carrying a `structured` JSON column populated
by `ai_platform.structure_request`) already ARE the real interest model — **no new
"Interest" table exists.** That matters: this repo already hit one
duplicate-source-of-truth bug once (the tab-bar/player-state issue, see "Mobile app
(iOS)"), and a second, parallel interest model would have been the same bug class
again.

An earlier session built this in an isolated local worktree
(`/private/tmp/audio_work_free_text_interests`, on someone else's Mac) but never
actually saw it work end to end — that worktree's `ANTHROPIC_API_KEY` was
empty/invalid, so every real classification call 500'd. Rather than chase a key
into a worktree this session has no access to, it was **rebuilt directly against
this repo's own `main`**, against this repo's own working deployment (where the
key already works):

- Backend: `RequestOut.structured` exposed (`app/api/routes/requests.py`), plus a
  `GET /requests?kind=` filter so a client can list only standing requests.
- iOS: a "Search for anything" field in `InterestsView`/`InterestsViewModel`,
  wired to the already-existing `APIClient.createRequest`. Kept deliberately
  separate from the catalogue-based "Standing interests" list above it — they're
  two different sources (`OnboardingState.selected_interests` vs. a `Request`
  row) for the same underlying concept, and merging them risked reintroducing the
  exact bug class above.

**Verified live against production**, the founder's own two test cases:
`"Arsenal FC"` → `{topic: "Arsenal FC", scope: "daily club news...", geography:
null}`; `"La Liga"` → `{topic: "La Liga football", geography: "Spain"}`. Both
correctly categorized, no 500s.

**Not verified**: an actual Xcode build of the iOS changes (no macOS/Xcode access
this session) — build-check on a Mac before shipping.

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

## Founder feedback from the first real-device install (2026-09-18)

The app was installed on a real iPhone for the first time (free/personal-team
signing via Xcode — expires after 7 days, needs the "Trust developer" step in
Settings → General → VPN & Device Management after each reinstall). This is the
founder's own feedback after using it, reproduced close to verbatim, plus what
investigation found for each point. **Read this before picking up work** — several
items that read like bugs turned out to be one shared root cause, and one item that
read like polish is actually the most important thing in the list.

### What he liked
- The colours, and the motion/transitions between screens ("the interaction in the
  screens or moving to another screen is so smooth"). **Do not change the palette**
  — `#1E647E` / `#74B9D1` accent and the existing surfaces are approved and liked.

### 1. "Login is terrible. we need a logo, and basically a brand style"
There is no logo, no brand mark, and **no app icon** (the app ships with the blank
default icon, which is a large part of why it reads as unfinished on a real home
screen). He wants a real brand identity built — logo, icon, style — while keeping
the current colours. Related: *"still feel a bit of [lacking] 'live' in the app...
maybe with the branding style you can do this."*

### 2. Onboarding / interest selection — "this window is critical, and needs a lot of work"
**This is the biggest gap in the product right now: there is no onboarding UI at
all.** A customer who signs up lands on an empty Home with no guidance, and the
Settings tab is hard-blocked ("Finish setup to see Settings — Your profile hasn't
been created yet — complete onboarding first") with no way to actually complete
that setup. The backend for onboarding is fully built and unused by any client.

His specific requirements:
- **Autocomplete**: *"when looking for Arsenal I should be able to see the arsenal
  team and select it. then it will appear as an 'active' interest in the screen."*
- **A running, visible list**: *"I can search for another thing but still can see the
  arsenal."* He hit a real bug where adding one interest made it disappear from view.
- **Per-item categorisation**: *"every single time I add another item, the system
  recognize the category (like sports, or political news or whatever)."*
- **Voice input** — he called this *"insane critical"*: *"what if a person truly dont
  want to type everything? just listening to the person interest should be good to
  capture their ideas."* The reasoning is the product's whole premise: *"the goal of
  this app is to make as personalize as possible, almost that no podcast will be the
  same."* Needs `SFSpeechRecognizer` + mic/speech Info.plist permissions.
- **Delivery setup is missing from the flow**: *"no section for voice selection,
  timing, speed, nothing."*

Note the Onboarding PRD's own constraint when designing autocomplete: *"The
customer's words become the request. We structure what they said; we do not replace
it with a category"* — it explicitly criticises category-list pickers as *"exactly
the shallow personalization every news app already offers."* There is no entity
database of football clubs etc., and building one would contradict that tenet.

### 3–6. "no player bar", "home is not giving me anything", "no audio at all, critical as hell"
**These three are not bugs.** Investigated live: the persistent mini-player, Home's
real per-block content, and real audio playback all work correctly. Verified on
2026-09-18 with a real account that had real content — audio played and advanced
(0:01 → 0:19 of 0:52), the mini-player bar appeared above the tab bar on every
screen, and Home rendered the real episode with its topic breakdown.

The actual cause was that **his account had zero content**, so there was nothing to
show or play. That is itself a serious problem, and it has two compounding causes:

1. **The "no news" dead end.** His standing request ("Premier League title race")
   honestly returned `no_news` — correct "never fill" behaviour. But the on-demand
   path is idempotent per `(customer, fecha, path)`, so every later attempt that day
   returns that same empty job **even after the customer adds a different standing
   request** (verified: a re-run after adding a new request returned the original
   job with a 16ms research stage — it never re-researched). The customer is stuck
   with an empty app until the next day, with no explanation and no recourse.
2. **No day-zero fallback content.** `shared_inventory` returns `[]`. The mechanism
   exists but matches on `OnboardingState.selected_interests`, so a customer who
   hasn't onboarded gets nothing. The Onboarding PRD is explicit that this must not
   happen: *"The first session has to end with audio playing, even if that audio is
   not yet fully theirs."*

### Confirmed bug found while investigating: a customer without a profile is trapped

`SettingsView.swift` renders `signOutSection` only inside `settingsList`, which only
renders in the `.loaded` case. An account in the `.noProfile` state (i.e. anyone who
signed up but hasn't completed onboarding — which today is *everyone*, since there is
no onboarding UI) sees the "Finish setup to see Settings" placeholder and **has no
sign-out button anywhere in the app**. They cannot sign out, cannot switch accounts,
and cannot reach any setting. The only escape is deleting and reinstalling the app.

Fix regardless of the onboarding work: sign-out must be reachable from every Settings
state, not just `.loaded`. It is the one control that must never be gated behind the
thing the customer is stuck on.

### 7. Settings — deliberately not being worked on
*"no settings, need to discuss this."* He wants to discuss the Settings surface
before anyone builds against it. Onboarding work will unblock the existing Settings
screen as a side effect (it's gated on Profile existing), but **don't redesign
Settings itself without talking to him first.**

### Also worth a product decision: content language
Generated content came back in **Spanish** (`"Hoy: Artificial intelligence industry
news"`, `"Resumen diario de IA..."`). That follows the backend's default language
setting and is not a bug, but nobody has explicitly decided whether Spanish-by-default
is the intended behaviour for all customers.

## AI budgets and kill switch

Every paid call (Anthropic and ElevenLabs) goes through one guard,
`ai_platform.guard_paid_call`, **before** money is spent. `AICall.cost` is the only
ledger: the guard sums today's (UTC day) `AICall` rows for the customer.

| Env var | Default | Meaning |
|---|---|---|
| `AI_GLOBAL_KILL_SWITCH` | off | `true`/`1`/`yes`/`on` refuses every paid call, news included |
| `AI_DAILY_BUDGET_PER_CUSTOMER_USD` | `1.50` | per account per UTC day; `0` disables |
| `AI_DAILY_BUDGET_GLOBAL_USD` | `0` (off) | total across all accounts per UTC day; refuses customer calls only |

All three are read from the environment on every call, so changing one needs no code
change. News calls (`customer_id` None or the zero-UUID sentinel) are governed by
`NEWS_DAILY_COST_CEILING_USD`, not the per-customer budget, but they do obey the kill
switch.

**Why 1.50.** A measured single-request episode is about $0.58 ($0.43 research, $0.15
voicing); a research+write block is roughly $0.11 and ElevenLabs about $0.18/1k chars,
so a customer with several requests lands around $0.6 to $1.0 a day. 1.50 leaves room for
one extra regeneration or a few one-off requests, and still caps a runaway loop at about
2.5 episodes. (The old per-job empty-day retry cap alone could reach about $1.74.)
The check is "spent so far >= budget", so a run that starts under the limit may finish
slightly over it; it is a brake, not an exact meter.

**What happens when a call is refused**
- `BudgetExceededError` (code `budget_exceeded`) or `AIKillSwitchError` (code
  `ai_paused`). A `budget_exceeded` event is emitted (scope, purpose, spent_usd,
  limit_usd; no free text).
- HTTP routes: budget returns `429` `{"detail": ..., "code": "budget_exceeded"}`; the
  kill switch returns `503` with `"code": "ai_paused"`.
- Episode generation: the job ends `failed` with `stages = [{"error": code, "code": code}]`
  (no exception text). `POST /generation/run` additionally returns an additive
  `failure_code`. Home still shows the existing `making` state (it never exposes
  `failed`). Nothing retries in a loop: the failed job is returned as is until the guard
  would allow it (switch flipped back, limit raised), then it re-runs in place, bounded
  by the per-day retry cap. A job that already has scripts and only failed in voicing is
  re-voiced instead of re-researched.

**Flipping the switch in Railway.** Service `Audio` -> Variables -> add
`AI_GLOBAL_KILL_SWITCH` = `true` -> Deploy (Railway restarts the service with the new
variable; no code change). Set it to `false` or delete it to resume. To change a limit,
edit `AI_DAILY_BUDGET_PER_CUSTOMER_USD` the same way. Look for `budget_exceeded` in the
`events` table (or the Instrumentation dashboard) to see who is hitting the limit.

## What an episode costs, and the model routing that changed it

Measured against production on 2026-09-24, then re-costed after routing.

**The two inputs, measured not estimated:** 782 ElevenLabs credits for 66
seconds of speech (11.8 credits/second), and $0.348 of Claude for one
researched block on `claude-opus-5`.

### The routing

Every call in `ai_platform.py` used to run on one Opus model regardless of the
job. The four jobs have very different shapes, and paying one rate for all of
them was the largest avoidable cost in the product:

| Purpose | Shape | Model now |
|---|---|---|
| `research_topic` | ~50K input tokens of search results, real judgment | Sonnet 5.5 |
| `write_block` | small input, no web access, facts into a paragraph | Haiku 5.5 |
| `structure_request` | one sentence in, a few fields out | Haiku 5.5 |
| `refine_request` | a block plus an intent | Haiku 5.5 |

| | Before (all Opus 5) | Routed | |
|---|---|---|---|
| One researched + written block | $0.3050 | **$0.1106** | −64% |
| 10-min daily listener, Claude only | $92/mo | **$33/mo** | |
| 5-min daily listener, Claude only | $46/mo | **$17/mo** | |
| One classify | $0.0125 | $0.00025 | |

The default model also moved `claude-opus-5` → `claude-opus-5-5` — same tier,
$4/$20 instead of $5/$25.

**Research is deliberately not on Haiku.** The `web_search_20260209` tool this
module declares is not available there, so routing research to Haiku would
silently fall back to a weaker search variant — a quality change disguised as
a cost change. There is a test asserting research never lands there.

### This flips the earlier finding

Before routing, research was ~73% of what an episode cost and voice was the
smaller half. **After routing, ElevenLabs is the larger half.** For a 10-minute
daily listener: ~$33/month of Claude against ~$38/month of voice.

That matters for what to work on next. The findings cache attacks what is left
of the Claude side and gets better as customers share topics. Voice does not
amortise the same way — every listener's audio is their own — and ElevenLabs
barely gets cheaper with scale ($0.142/audio-minute on Starter, $0.117 on the
$299 Scale tier). **Voice is now the thing to look at**, not research.

### Escalation, and what it deliberately does not do

A cheap model whose output cannot be parsed is retried once on a stronger one.
The trigger is narrow on purpose: **not** "the cheap answer looks weak" —
nobody can judge that in this code, and a model reporting an honestly quiet day
is giving the *correct* answer, which must not be second-guessed into a
fabricated one. Only `parse_failed`.

That needed a new flag. Until now an unparseable response and a genuinely quiet
day both produced `no_news=True` and were **indistinguishable**, so a malformed
response silently became an empty episode. Both attempts log their own `AICall`
row with their own model, so the dashboard shows what escalation costs instead
of hiding the retry inside one row.

### Why the research/writing split had to come first

`research_and_write_block` did both jobs in one call and took `customer_id`,
`style` and `language`. Fused, neither half could be cached *or* routed — you
cannot send "the expensive customer-neutral half" to one model and "the cheap
per-listener half" to another when they are the same request. The split
(`research_topic` / `write_block`) is the prerequisite for both.

**The facts are shared, the episode never is.** Two customers on one topic share
a research pass and still get their own script, in their own style and language,
voiced into their own audio file.

### What the $5/customer/month target needs

With routing, Claude for a 10-minute daily listener is ~$33/month. Voice is
~$38. $5 therefore still needs the episode to be short — roughly a minute of
*bespoke* audio a day — or shared audio for shared blocks, which is a product
decision about whether anyone hears the same recording as anyone else.

Both figures are cost of goods only: no Railway, storage or bandwidth, and they
assume every customer is daily.

### Still unverified

The prompts have never faced a real model on the cheaper tiers — there is no
Anthropic key in the local environment and Railway deploys only `main`.
Structure, wiring, parsing, routing and the invariants are covered by 24 tests;
**prompt quality on Haiku and Sonnet is not.** Compare a Haiku-written block
against an Opus one before trusting the saving.

## The findings store, and the two bugs found building it (2026-11-11)

### What it is

Research is now shared between customers. Episodes never are.

The founder's requirement, verbatim: *"if 2 people are researching for same
thing, then the info is there and no need to research again"* — alongside the
constraint stated just as plainly: *"I don't want the same podcast for
everyone. never."*

Both hold, because the two halves of block production were separated first
(PR #36): `research_topic` produces customer-neutral **facts**, `write_block`
turns those facts into **one listener's segment**. Only the first is cached.
A script is never shared. Audio is never shared.

Two customers following the same topic now pay for that research once between
them, and still receive two different episodes.

A cache hit costs **zero**, not less — `research_topic` consults the store
before the model call rather than routing to something cheaper.

| | |
|---|---|
| Key | `(topic, scope, geography)`, normalized |
| Normalization | casefold + accent-fold + whitespace-collapse |
| Fresh TTL | hours (findings with news) |
| Empty TTL | well under an hour (`no_news`) |
| Never cached | parse failures; anything customer-specific |

Normalization is deliberately conservative — no stemming, no synonyms, no
translation. A false miss costs one research call. A false hit serves a
customer findings about something they did not ask about.

Accent folding exists because customers write in Spanish: *Elecciones Bogotá*
and *elecciones bogota* must be one entry.

### Why the two TTLs differ so much

`no_news` is the most time-sensitive answer in the system. A quiet topic at
7am can be the day's story by 10am. Caching an empty result for hours would
reintroduce the empty-day lockout that PR #31 fixed — by the back door, and
for every customer at once rather than one at a time.

### The honest caveat about the cache key

`research_topic`'s prompt also includes the customer's own `raw_text`, because
the structured fields lose intent (*"how did Arsenal do"* wants results, not
transfers). So a cached entry was researched from **somebody's** phrasing.

This is accepted deliberately: `topic/scope/geography` **is** this system's own
normalization of `raw_text` — producing a canonical form is precisely what the
structure step exists for. Two requests that normalize alike were judged
equivalent by our own classifier; if that judgement is wrong, the bug is there,
not in the cache. `researched_from` stores the originating text so a bad hit
can be diagnosed rather than guessed at.

### Bug 1 — the cache would never have expired anything

`datetime.utcnow()` returns a **naive** datetime. asyncpg encodes a naive
datetime for a `timestamptz` parameter by assuming it is in the **process's
local timezone**. On a machine running UTC-8, a row stamped "now" was stored
eight hours **in the future**:

```
sent naive : 2026-11-11 17:20:48
echoed     : 2026-11-12 01:20:48+00:00    (TZ unset, machine on Pacific)
echoed     : 2026-11-11 17:20:48+00:00    (TZ=UTC)
```

Every age computed negative. Every entry looked fresh forever. The cache would
have served yesterday's news indefinitely **while appearing to work
perfectly** — no error, no warning, no failing test.

**What does not fix it:** pinning the DB session's timezone. That was the first
attempt and it looks obviously right; the conversion happens client-side inside
asyncpg, before Postgres is involved. It failed the round-trip test, which is
the only reason the real cause was found instead of a one-line non-fix shipping
on top of the bug. (The session setting is kept for a different, real reason —
server-side `func.date()` day-bucketing in instrumentation.)

**Why production never showed it:** Railway's containers already run UTC, so
naive-local happens to equal UTC there. The convention has been correct **by
luck, not by construction** — and wrong in local development the whole time,
meaning every time-dependent behaviour has been untestable locally.

Two comments already in this repo warned the hazard existed
(`check_late_jobs`, instrumentation's day-bucketing note). Both were right.

What depends on it: the late-job watchdog, token expiry, the login rate
limiter, cost day-bucketing, findings freshness.

The real fix is aware UTC at all 31 `utcnow()` call sites — a larger sweep,
listed in next steps. The process-level pin makes the existing convention
correct everywhere meanwhile.

### Bug 2 — how close it came to shipping

The first expiry test **passed in isolation and failed through the real
fixture**. The difference was whether the row was re-read from Postgres or
served from SQLAlchemy's **identity map**, which returned the value just
assigned in Python and hid the conversion completely.

Worth remembering generally: an ORM identity map can conceal a storage-layer
bug entirely until something forces a reload. Tests that assert on an object
they just wrote, in the same session, are not testing persistence.

### Why `main` went red on 2026-11-11, and what it says about merging

After nine PRs merged in one sitting, 12 of 38 tests failed on `main` with
no new code involved:

```
AttributeError: module 'app.services.ai_platform' has no attribute
'research_and_write_block'
```

PRs #31 and #36 were **each individually reported MERGEABLE**, git merged the
text with **zero conflicts**, and the breakage was purely semantic: #36 deleted
a function #31's tests patched by name. Neither PR's suite was ever run against
the other's merged result.

No tooling in this repo would have caught it. Only running the combined result
would — which nobody did, including the agent that flagged the collision in
advance and then failed to verify the outcome.

The runtime was never affected (only comments referenced the old name), but a
red suite that everyone knows is red stops being a signal at all.

Fixed in PR #42 by moving the pipeline fakes into one module,
`backend/tests/fakes.py`, so the next change to the pipeline's shape updates one
file instead of four.

## Recovery and continuity (2026-11-11)

### Re-voicing instead of re-researching

A job that dies in voicing keeps its episode and its finished block scripts,
unpublished (PR #43). When the customer generates again, the pipeline now
**re-voices those scripts** rather than running the whole day again.

Research and writing are the larger share of a run's cost and are already
spent. The usual cause of a voicing failure is a quota since topped up or a
provider 5xx — neither is worth paying for the day twice. This is the path
that matters the moment ElevenLabs is topped up: every job that failed for
lack of credits becomes recoverable for the price of the audio alone.

The synthesis stage is shared (`_synthesize_episode`), not duplicated — two
implementations of "turn scripts into the published episode" is how an
episode ends up published one way and re-published another.

It refuses in four cases, and the first is the one that matters:

| Refuses when | Because |
|---|---|
| the job failed **before** voicing | there are no scripts; it would publish an empty episode |
| the job is `ready` | re-billing the most expensive half for no benefit |
| TTS is still unconfigured | nothing to retry with |
| no unpublished episode with a script | nothing to recover |

A failed re-voice stays `failed` — dropping back to a non-terminal status
would recreate the "stuck on voicing forever" bug this chain began by fixing.

### Continuity: each episode as the next instalment

`write_block` now receives what this listener already heard on **this**
request (`app/services/told_log.py`), so a segment can move a story forward
instead of restarting it.

The asymmetry with the findings cache is deliberate and load-bearing:

| | Findings cache | Told-log |
|---|---|---|
| Scope | shared across customers | per customer |
| Key | topic | that customer's own request |
| Lives in | `research_topic` | `write_block` only |
| Buys | cost | continuity |

`research_topic` does not accept a listener history, and a test asserts it
never will. If one listener's history reached research, cached findings would
be coloured by a stranger's past episodes and the split would collapse.
**Findings are common; memory is personal.**

No new table — every `Block` already carries a `request_id` and a one-line
summary, so this is a read rather than a second source of truth that could
drift from what was actually said.

**Only published episodes count.** An episode that died in voicing has
finished scripts in the database and reached nobody; treating it as told
would open tomorrow with "yesterday we covered the rate decision" to someone
who heard silence. `published_at` is the only honest record of what was
delivered — which is why PR #43 stopping it being stamped before the audio
exists is what makes this correct.

History is capped at three segments, and the prompt forbids recap: no
re-explaining, no opening summary, and no padding to reach the word target —
if today adds little, today is short.

### Verified by actually booting it

The whole stack was booted against an empty database and exercised, not just
unit-tested:

- `create_all` builds `findings_cache` with its unique constraint and both
  indexes
- the process-level UTC pin applies at import without breaking startup
- `POST /api/auth/signup` → token → `GET /api/auth/me` → `GET /api/home`, all 200

`/api/home` on a fresh account returns `shared_inventory: []` and
`explore: []` — the empty-shelves problem is still exactly as described in
next steps, and still waiting on `INTERNAL_DASHBOARD_KEY` in Railway.

## Three bugs from one screenshot (2026-11-11)

The founder ran the app on a real iPhone, tapped through onboarding, and sent
back one screenshot of the Details step. It contained three separate defects,
plus a fourth hiding behind them in the backend.

### "More ideas" could not show a new idea

`OnboardingCategories.pageSize` is 6. Every single topic list — all five
countries' cities, politics, markets and sports, and all seven fixed category
lists — held **exactly 6** items. `page(offset:)` wrapped with
`% topics.count`, so `(6 + i) % 6 == i`: page two was page one, verbatim.

The button therefore could not work, in any category, in any country, ever.
Four taps produced four "Here are a few more." bubbles above an unchanged set
of chips. Nothing errored, nothing logged, and the only evidence it was broken
was a customer counting chips.

The wrap was the kind of mistake that looks careful. It is defensive — it can
never index out of bounds — and it reads as "cycle through the list". It only
fails when the list is exactly one page long, which is the case nobody writes a
test for and, as it happens, the case every list in the file was in.

Three changes, because one would not have been enough:

- `page(offset:)` clamps instead of wrapping, so exhaustion is *visible* to the
  caller rather than disguised as an endless supply of the same six.
- `hasMore(after:)` reports it, and `DetailCard` hides "More ideas" when it is
  false. The app no longer offers what it cannot deliver.
- Every list is now twelve long, so there is a real second page to show.

### Tapping a chip and then "More ideas" silently discarded the chip

`detailChoices` was replaced wholesale on each page, and `addSelectedDetails`
only ever submits chips still in `detailChoices`. "New York", then "More
ideas", and New York was gone — from the card and from the submission — with
nothing said.

The card is now appended to rather than swapped. That fixes the loss, and it
makes the sentence literally true: "Here are a few more" now describes
something the customer can see happen.

### "I'm done, skip the rest" announced success it had not had

```swift
for label in covered {
    _ = await vm.addRequest(...)   // result discarded
}
await flushError()
if !covered.isEmpty { await say("Okay, I'll cover the top stories for ...") }
```

Every add's result was thrown away, and the reassuring line was said whether or
not a single request had been saved. In the founder's screenshot all three
failed, so the chat read:

> Server error (500): Internal Server Error
> Okay, I'll cover the top stories for Local news, World and Personal finance.
> I need at least one topic to build your first episode. What do you want to follow?

A raw stack-trace string, then a promise, then the promise disowned — three
bubbles, in the assistant's own voice, one after another.

Each add is checked now. Only what saved is claimed, what failed is named, and
when nothing lands at all the flow stays on the card to be retried rather than
advancing into "I need at least one topic" — which was true, but only because
the step had just failed, and so read as the app contradicting itself.

### Underneath all of it: nothing caught anything

The 500 was real. `POST /requests` calls `ai_platform.structure_request`, and
there was no error handling anywhere around the model call. One rate limit, one
529, one dropped connection became an uncaught exception and FastAPI's generic
500 — which `APIError` then rendered verbatim into a speech bubble.

Two fixes, in `ai_platform._invoke`:

- **Transient failures retry** with backoff; anything that survives the retries
  is raised as `ModelUnavailable`, which `app/main.py` maps to a 503 carrying a
  sentence a person can act on. The provider's own error string stays in the
  logs. A permanent failure is deliberately not retried — it cannot succeed,
  and retrying only lengthens the wait before the same answer.
- **The call no longer blocks the event loop.** `_client` is
  `anthropic.Anthropic`, the *synchronous* client, called from `async def`
  handlers. For the length of every round trip this process served nobody: not
  another customer, not `/health`, not the scheduler. With generation still
  running inline on the request path that is tens of seconds of total freeze per
  episode, and it makes exactly the timeouts above far more likely under any
  concurrency. Every call now goes through `asyncio.to_thread`.

The sync client is kept on purpose. Every test fake patches `_client` with
plain synchronous callables, and `to_thread` runs those unchanged; switching to
`AsyncAnthropic` would mean rewriting every fake to be awaitable for no
behavioural gain.

### What the first version of that fix got wrong

`_invoke` originally caught `anthropic.APIError`. Running a local server with
no `ANTHROPIC_API_KEY` showed that an unconfigured key raises a plain
`TypeError` from inside the SDK's header builder — not an `APIError` at all —
so it went straight back to being the 500 the function exists to prevent. It
now catches `Exception`, logs the traceback, and reports `ModelUnavailable`.

That was found by running the thing, not by reading it. The same is true of the
event-loop fix: its test was checked against the bug it describes by removing
`to_thread`, where it reports 0 ticks instead of the 5+ it requires. A guard
that has never failed is not known to work.

### Verified by driving the app

`Config.apiBaseURL` now accepts a `LUCAKU_API_BASE_URL` override in DEBUG
builds (release ignores it), which is what made this checkable at all:

```
SIMCTL_CHILD_LUCAKU_API_BASE_URL=http://127.0.0.1:8077 \
  xcrun simctl launch --terminate-running-process booted com.lucaku.audio
```

The `SIMCTL_CHILD_` prefix is not optional — anything after the bundle id is
passed as a launch *argument*, not an environment variable, so
`simctl launch ... KEY=VALUE` silently leaves the app talking to production.

Pointed at a local backend with no Anthropic key, so every call genuinely
failed, the Simulator showed: the card growing by six new cities, the selected
chip surviving the page change, "More ideas" disappearing once all twelve were
shown, and the failure producing one honest error, a named list of what did not
save, and an offer to retry.

## News feed

Backs the iOS Home news section (replaces `SampleNewsRepository`). News is **topic-keyed, not customer-keyed**: items are written once per topic and shared by every follower, so cost does not grow with follower count. Only read state is per customer.

**Tables** (`app/models/news.py`, created by `create_all`): `news_items` (topic_key, category, title, `summary` <= 70 chars, short_version, body, `sources` JSON `[{name,url}]`, image_hint, published_at, slot, cluster_id; index `(topic_key, published_at)`), `news_read_states` (unique `(cliente_id, news_id)`), `news_runs` (unique `(topic_key, run_date, slot)`, the idempotency record).

**Pipeline** (`app/services/news_pipeline.py`): research through `ai_platform.research_topic` (web_search + shared `findings_store`) -> cluster near-duplicate headlines -> drop stories already published for the topic in the last 3 days -> `ai_platform.write_news_items` (prompt `news_write` in the prompt registry, max 3 items) -> grounding check: every cited URL must come from the research, and an item with no source URL is never stored. Summaries are clamped to 70 chars. Research uses Claude web search, not a licensed news API.

**Slots**: the scheduler (`NEWS_SCHEDULER_ENABLED`, default on; `NEWS_MAX_TOPICS_PER_SLOT`, default 60) checks every 10 min and runs the current UTC band for each topic with followers: `0500` (05:00-12:59) and `1300` (13:00-23:59); nothing runs 00:00-04:59. A `(topic, date, slot)` runs once, so repeated ticks and restarts are safe. The first claim is the unique insert into `news_runs`; re-claims (a `failed` run after a 45 min backoff, or a `running` run stale for 30 min) are one atomic conditional `UPDATE ... RETURNING`, capped at 3 attempts per key, so two replicas never both run a slot and failures cannot loop on paid searches. A research parse failure is reported as `failed` and is never cached. `NEWS_SCHEDULER_ENABLED` is read at every tick (runtime kill switch) and `NEWS_DAILY_COST_CEILING_USD` (default 15) stops a slot once the day's recorded run cost reaches it. On demand: `POST /api/internal/news/run?topic=...&slot=0500|1300|adhoc` (internal key, same as other internal routes).

**Endpoints** (auth required; `/api` prefix):

| Method | Path | Notes |
|---|---|---|
| GET | `/news?day=YYYY-MM-DD&tz_offset_minutes=&cursor=&limit=&scope=followed\|all` | Last 7 days, newest first. Each item has `day` (calendar day in the caller's tz via `tz_offset_minutes`, default 0 = UTC, e.g. -300 for Bogota; `day=` filters in that same tz), `read_minutes` (body words / 200 wpm, min 1) and `read`. Matches followed topics or their categories. If nothing matches: `items: []` and `no_follow_match: true`; the app then calls `scope=all`. |
| GET | `/news/{id}` | One item. |
| PUT / DELETE | `/news/{id}/read` | Mark read / unread (idempotent). |
| POST | `/news/read-all` | Marks the visible feed read (falls back to everything if nothing matches). |

## Suggested next steps

**Status as of 2026-11-11, after the autonomous backend session.** Everything
is merged and nothing is open: #42 (test suite repair), #43 (voicing failures +
pool), #44 (signup error messages), #45 (findings store), #46 (timestamp
correctness), #47 / #50 / #53 (these docs), #48 (re-voice), #49 (continuity),
#51 (cache-savings metric), #52 (consent prompt removed from onboarding), #54
(model-call resilience) and #55 (the three onboarding-chat bugs). #41 was
superseded by #43 and is closed. `main` is green — 94 tests.

Two things to know about that merge, because both cost time and will recur.
Deleting a base branch on GitHub **closes** the stacked PR above it rather than
re-pointing it, and a closed PR cannot be re-based or reopened while its base
branch is gone — #43 had to be recovered by pushing the deleted branch back.
Retarget every PR in a stack to `main` *first*, then merge bottom-up. And two
docs branches that each appended a section at the same point in this README
merged cleanly against `main` individually and conflicted the moment the first
one landed; the resolution keeps both, in the order the work happened.

Blocked on the founder, not on code:

- **ElevenLabs credits.** Nothing produces audio until the plan is topped up.
  Every code path around voicing is now correct and tested, and not one real
  episode has been verified end to end, because none can be.
- **An Anthropic key usable locally.** The 64% routing saving is measured on
  price, not on quality: no Haiku-written block has ever been compared against
  an Opus one. That number should not be trusted until someone checks the
  writing did not get worse.
- **`INTERNAL_DASHBOARD_KEY` in Railway Variables.** Until it is set, Home's
  "For you" and "Explore" shelves render nothing in production — the pipeline
  and the seeds exist, the content does not.
- **A Voyage AI key**, for the semantic index (item 6 below).

Code work, highest value first:

- **Aware UTC at all 31 `utcnow()` call sites.** PR #46 makes the naive
  convention correct from one place; this removes the hazard rather than
  containing it. See "The findings store, and the two bugs found building it".
- **Get generation off the request path.** `POST /generation/run` still awaits
  the whole pipeline inline, holding a DB connection for ~40s; the iOS client
  carries a 300s timeout and a spinner to match. PR #43's pool sizing is a
  stopgap for the symptom. The real fix is a job queue plus client polling, and
  it changes an API contract the shipped app depends on, so it needs the app
  rebuilt in the same change. Onboarding already does this correctly (PR #31's
  `_trigger_first_episode_in_background`) and is the pattern to copy.
- ~~**A re-voice path.**~~ **Done** (PR #48). A failed voicing retries from the
  stored scripts without paying for research again. See "Recovery and
  continuity" above.
- ~~**Continuity between episodes.**~~ **Done** (PR #49). The writer now
  receives what this listener was already told and writes today's block as the
  next instalment. See "Recovery and continuity" above.


1. ~~Finish the free-text-interests worktree~~ — **done**, rebuilt directly against
   `main` and verified against production. See "Free-text AI-categorized interests"
   above.
2. ~~Verify the ElevenLabs `with-timestamps` integration against a real live call~~ —
   **done**. See "Episode Generator scope" above.
3. ~~Fix the session-expiry gap~~ — **done**. `APIClient` posts `.sessionExpired` on
   any 401; `SessionStore` observes it and clears itself. Unverified by an actual
   Xcode build (no macOS access this session) — build-check before shipping.
4. ~~Merge PR #27, close #23–#26~~ — **already done** (verified via the GitHub API,
   see "Mobile app (iOS)" above) — nothing left to do here.
5. **Build-verify this session's iOS changes on a real Mac** — the free-text-interests
   UI and the session-expiry fix were both written without Xcode access; a clean
   `xcodebuild ... build` plus a Simulator smoke test (type "Arsenal FC" into
   Interests, confirm the real category comes back; force a 401 — e.g. log out
   server-side via another client — and confirm the app routes to Login) hasn't
   happened yet.
6. **The AI Platform's shared semantic index** — the prompt registry is now built (see
   "AI Platform scope" above); the semantic index is the one remaining AI Platform
   piece, and it's the real blocker for novelty judgment, Search & AI's Q&A, and
   Home's suggestions.
   **Embeddings provider decided: Voyage AI** (voyage-3.5 — chosen for meaningfully
   better retrieval quality than OpenAI's text-embedding-3-large on real benchmarks,
   less than half the price at $0.06/1M tokens, and a longer 32K-token context window
   that comfortably fits a full block transcript without chunking). **Not yet set
   up as of this writing** — the founder needs to create a Voyage AI account and
   API key (same pattern as the existing Anthropic/ElevenLabs keys) before this can
   be built; founder said tomorrow. Once that key exists, this becomes buildable:
   wire it into the AI Platform, build the embedding/indexing step for
   episodes+blocks, and the shared semantic index itself.
7. **Populate the shared inventory in production — currently EMPTY, so Home's
   "For you" and "Explore" shelves render nothing.** The pipeline, the seed list
   and Home's shelves are all built; production simply has zero shared episodes,
   and `INTERNAL_DASHBOARD_KEY` is unset on Railway (the route answers 503, and
   the gate fails closed by design). To fill it: set `INTERNAL_DASHBOARD_KEY` to
   a long random value in Railway Variables, then per tag (each is ~1 min and
   ~$0.5 of Claude + ElevenLabs; running all tags in one call can outlive an
   HTTP timeout, hence the `tag` param):
   `curl -X POST "$BASE/api/internal/generate-shared-inventory?tag=technology"
   -H "X-Internal-Dashboard-Key: <the key>"`. Tags are the `tag` values in
   `app/data/shared_inventory_seeds.json`. Note `app/api/deps.py` defines
   `require_internal_dashboard_key` twice (two merged branches); the second
   definition shadows the first, so the header is `X-Internal-Dashboard-Key` —
   worth deleting the dead first copy. The seed content itself is still a
   placeholder, not team-curated (see "Shared inventory" above).
7b. ~~Guided, voice-led onboarding in the iOS app~~ — **built** (2026-09-21), see
   "Onboarding (iOS)" below. **Not yet seen on a device** — the mic/speech pieces
   specifically need one (Simulator has no real microphone input).
7c. **UI localization.** Every string in the iOS app is hardcoded English while
   the founder and customers are Spanish-speaking (`Cliente.idioma` defaults to
   `es`); the backend already localizes catalogue labels and suggestions.
8. **Google/Apple OAuth for real** — the login screen's Google Sign-In button is
   currently a visual stub. Needs the founder to create an OAuth client ID in
   Google Cloud Console, and separately enroll in the Apple Developer Program
   ($99/yr — also required for push notifications and real-device testing, not
   just Sign in with Apple). Neither can be done by an agent; both need the
   founder's own accounts.
9. **Push notifications** — blocked on the Apple Developer Program enrollment above
   (APNs) plus, for Android later, Firebase Cloud Messaging.
10. **Wire refine/follow-up/rating actions** in the Player screen to the backend
    endpoints that already exist.
11. **Two low-urgency cleanups from an earlier review**: Home's "currently playing"
    highlight disappears when playback is paused mid-block (cosmetic only), and
    `Features/Home/PlayerListView.swift` is now dead code since the Player tab no
    longer exists (safe to delete).

Done as of 2026-09-21: guided, voice-led Onboarding built for iOS — the app had no
onboarding at all before this (signup dropped straight into the tab bar), which was
the real cause behind "it's just text" feedback. 8-step resumable flow, on-device
speech narration (prompts read aloud) and dictation (the free-text request field),
per-interest curated suggestions for anyone unsure what to ask. See "Onboarding
(iOS)" above for the full breakdown, including two Swift 6 build errors hit and
fixed via the CI sideload workflow. Not yet run on a real device — the mic/speech
pieces specifically need one.

Done as of 2026-09-19 (evening, after the first real-device build): Home redesigned
(dark-first, generated cover art, topic grid, hero card, shelves, tinted floating mini
player). The founder's two complaints had real causes beyond styling: (1) the floating
player only rendered once TODAY's episode existed, and a fresh account never got one —
the backend maps "no job yet today" to banner `making` with no ETA, so Home said
"being put together" while nothing was, and the only "Generate now" button lived in
another banner state; Home now offers it whenever `making` has no ETA, polls while a job
runs, and loads today's (else the latest past) episode into the shared player, paused,
so the mini player is present from the first moment there's anything to play.
(2) `URLSession`'s 60s default timeout made "generate now" report failure while the
server was fine — `runGeneration` now uses 300s. Backend: `GET
/generation/episodes/{id}` (own or shared episodes, else 404 — verified a second
customer gets 404 for someone else's episode), `HomeOut.explore`, `episode_id` on the
banner and Recent, `tag` on shared items, optional `tag` param on
`/internal/generate-shared-inventory`. Compile-verified by the GitHub Actions sideload
build (green); NOT yet seen on a device. See items 7/7b/7c above for what remains.

Done as of 2026-09-19: PR #27 merge + #23-26 cleanup confirmed complete; free-text
AI-categorized interests rebuilt against `main` and verified live (both founder test
cases); ElevenLabs word-level timestamps verified against a real live call; the
session-expiry-doesn't-route-to-Login gap fixed. All four unverified by an actual
Xcode build — see item 5 above.

Done as of 2026-09-18: ElevenLabs TTS verified working end-to-end in production; audio
storage moved to a durable Railway volume; Episode Generator scheduled path and
idempotency built (see "Episode Generator scope" above); real audio engine + real
transcript timestamps wired into the Player screen (#22); tab-bar architecture fixed
and real Home/Search/Interests wired end-to-end, live-verified, with a re-entrancy
bug caught and fixed (#27).

## iOS redesign — status after the first Simulator run (2026-11-11)

The app was rebuilt to the design on branch `feat/redesign` (PR #40), which
integrated #37–#39. **PR #40 states plainly: "Nothing has been run on a device
or simulator."** It has now been run, against production, and this section is
what that turned up plus the work done since.

**The source of truth is the clickable prototype** — `Main.dc.html` in the
Design canvas, 66 scenes behind `startScreen` / `homeState` / `profileStyle`
props. The deck slides and the per-screen review frames in the same canvas are
older and were not used. The frames are thin wrappers that import `Main` with a
`scene` name, so they render the prototype but their annotations can lag it.

Tabs are **Home, Interests, Profile**; Settings lives inside Profile. Profile
ships as **option A** (the canvas offers A/B/C; B and C were never built).

### What running it found, that reading it did not

**The tab bar was the system accent — blue.** Nothing ever set a tint, so the
one control always on screen was not the brand colour.

**Tab switching often needed two taps.** The mini player was a `ZStack` overlay
with `.padding(.bottom, 50)` commented "clears the system tab bar". It does
not: an overlay floats over the bar's *hit area*, so taps near its top edge were
swallowed. This was the "transitions don't feel native" complaint, and it was a
hit-testing bug rather than an animation one.

**Every screen guessed the bar's height separately** — ContentView 50, HomeView
96, PlayerListView 110, SettingsView and ProfileComponents 140, NewsDetailView
96. Six guesses at one layout, so content clipped behind the bar on every tab.

Both are the platform's job now. On iOS 26+ the mini player sits in
**`tabViewBottomAccessory`**, the API Music and Podcasts use: it supplies the
glass, places the player above the bar, morphs it with the bar, leaves the bar's
hit area alone, and removes its height from every tab's safe area so no screen
needs to know it exists. Before iOS 26 there is no accessory slot, so a bottom
`safeAreaInset` gives the same layout against the classic opaque bar
(`MiniPlayerHost` in `ContentView.swift`). Every magic number is gone, and
`MiniPlayerView` grew a `drawsOwnChrome` flag because the system draws the
surface in the accessory and our card on top of it was a panel inside a panel.

**This is a deliberate deviation from the prototype**, and the one place the two
disagree: the prototype draws a classic full-width 83pt bar, because it is a web
page. On iOS 26 the floating Liquid Glass bar *is* the native control, and the
brief was not to lose the native feel. The prototype's bar is an approximation
of a native tab bar; the native one is the better realisation of the same intent.

### Screens brought to the prototype

**Login.** The three-row promises card is gone. The prototype has one line — "A
short daily audio episode about only what you follow." — and an episode drawn in
the accent colour: a filled play circle, "Your episode" against "7:00 AM · 8
min", and a 32-bar waveform at the prototype's exact heights, the first 11 solid
and the rest at 35%. It is an episode part-way through, not a live meter, so it
does not animate, and it is hidden from VoiceOver because the line above says the
same thing. The card had pushed the sign-in form below the fold; it fits on one
screen now. "Continue with Apple" removed — the prototype offers Google only.

**Home** is the greeting, one state card, and the news by day. Two sections were
removed because the prototype does not have them: "Your Lucaku" (delivery time
and topics — Interests is a tab now, so this was a second, lesser copy of it on
the screen you see most) and "Previous episodes" (history is in Profile, as a
list rather than a shelf you scroll sideways past the news).

**Interests** was the furthest off. Its own file comment admitted "the overall
direction is still under review, spec alternatives A-D"; the prototype settled
it. It was a library browser — search field, "Your topics" gradient tiles,
"Suggested for you", "Browse all", "Recently removed". It is now an extension of
the onboarding chat:

1. **Your episode as four tiles** — ready at, length, style, voice. These four
   decide what arrives tomorrow, so they sit above what you follow. Time opens a
   wheel; the rest are inline menus, one tap each.
2. **You follow, grouped by category**, as chips in one card. Edit makes them
   removable; removing offers Undo. A category followed wholesale shows one muted
   "Top stories" chip rather than repeating its own name underneath itself, and
   only counts when it has no questions of its own.
3. **Lucaku docked above the tab bar** — the composer with mic, in the screen's
   own bottom safe area so it sits above the mini player without either knowing
   about the other.

Browsing a catalogue was the old model; telling Lucaku what you want in words
replaced it. `voiceId` is new on `InterestsViewModel` (the backend already had
the field) and reports the first catalogue voice when nothing is stored, which is
what the generator actually uses — "Default" named a voice nobody could identify.

**Profile** (option A) already matched: identity, history, Downloads, three drill
rows with the prototype's own subtitle formats, centred sign out.

**Notifications** was a settings page with a short list under it. The prototype
inverts that — the screen *is* the inbox, and what you get notified about sits
behind one row at the bottom (`ProfileNotificationSettingsPage`). Filter pills
All / Episodes / Your topics / Updates; "You're all caught up" when nothing is
unread; "Nothing here yet" when a *filter* hides everything, which is a different
sentence for a different situation and was previously collapsed into one empty
state; "Mark all as read" only when the current filter has unread in it.

**Now Playing** gained the prototype's "Episode options" panel: the speed row
with its "Tap to reset to 1×" hint, five speed pills, download, share, and the
line that sends rating back to Useful / Not quite so there is one place for
feedback instead of two.

**Article** gained the share button its top bar was missing and "More from
today" at the foot, so finishing a story offers the next instead of a dead end.
That needed the navigation fixed first: Home used
`.navigationDestination(item:)`, a single slot, so a story opened from inside
another would have replaced the one you were reading. It is value-based on a
`NavigationPath` now.

**Share sheet** gained Save to Files.

### Onboarding: the country is a variable now

The `local` category was named **"Colombia & your city"** — a label nobody
outside Colombia can use — and the lists under it carried Ecopetrol, CDTs,
Millonarios, Karol G and "Colombian president". The same label was in Interests'
fallback map and Home's category names.

The fix is **not** to make it generic. The backend's own clarity screen rejects
vague requests — "How did my favourite team do?" comes back asking which team —
so generic suggestions produce requests that fail a step later. Instead:

- Category names are place-neutral: **"Local news"**, **"World"**.
- Only the four categories that genuinely depend on where you are read from
  `OnboardingPlace`: local, politics, markets, sports. Technology, science,
  health, climate, culture and lifestyle are the same everywhere and were never
  the problem.
- Tables for Colombia, Mexico, Spain, the United States and Argentina. Anywhere
  else still works: `generic` templates the same shapes off the country's own
  name, so the app is not broken in a market nobody has thought about yet.
- **"World" leaves out the country you are in.** Where you live is Local news.
- The place comes from **the device region, not a new question.** Onboarding has
  enough steps, the region is right for almost everyone, and Interests changes any
  of it afterwards in a sentence.
- Free-text guessing matches the listener's own country and cities first, so
  "Medellín" lands in Local news for a Colombian and "Guadalajara" does for
  someone in Mexico.

Colombia stays the fallback when the region is unknown — first market, and a
better default than a template for an app shipping in Spanish.

### Still open on the front end

- **The onboarding chat script** still differs from the prototype's wording. The
  category and suggestion *data* is fixed; the dialogue is not.
- **Profile options B and C** (Netflix- and Spotify-style) were never built.
- **The flat Settings screen** in the prototype (`Plan`, `Downloads & playback`,
  `Audio quality`, `Data & Privacy`, `Help & about`, `Save Changes`) is not
  built, because option A reaches those through its three grouped pages instead.
  If Profile ever moves to option B, that screen becomes real work.
- **Episode options has no trigger in the prototype.** It defines `openTuning`
  and never references it in markup, so the panel is only reachable there via the
  `np-tuning` scene. The ellipsis in the player's top bar is this app's choice —
  the conventional iOS spot for per-item options. **Worth confirming the
  placement.**
- Nothing has been run on a **real device** this round; the Simulator has no
  microphone, so the mic paths in onboarding and Interests remain untested
  anywhere.

### Still true from before

- **Design tokens:** `DesignSystem/LucakuColor.swift`, `StatusBarFade.swift`
  (`StatusBarFadeAnchor` + `.statusBarFade()`), `FlowLayout.swift`. Shared
  feedback UI in `Features/Feedback/`.
- **Brand rule:** the accent is for the wordmark dot, the primary action and the
  spoken word. Everything else is neutral (`textPrimary` / `fill`).
- **TODO(backend):** Home news uses a sample repository (no news endpoint);
  share links, feedback, downloads and ratings are local stubs; Google/Apple
  sign-in are visual only; forgot password confirms locally; the chosen voice is
  not sent.
- **CI:** `.github/workflows/ios-sideload-build.yml` runs on `macos-15` and
  produces the unsigned `.ipa` for Sideloadly.
- **Onboarding** ends straight at Home and submits notifications as off; push
  permission is requested from the Profile toggle.

### How to work against the prototype cheaply

The prototype is one 304KB file and the app is ~8,000 lines of Swift, so reading
both into a model's context is the expensive way to do this. What worked:
extract the prototype's markup to disk, split it by its own section comments,
strip inline styles, and diff the *literal UI strings* against the Swift source
by script. That finds divergence in seconds and costs almost nothing. Screenshots
at 26–32% scale are enough to judge layout. Scripts are disposable; the method
is what to keep.

Two traps when reading a string diff: Material Symbols icon names
(`ios_share`, `fast_forward`, `content_copy`) never match because the app uses SF
Symbols, and Swift escapes (`\u{00D7}` for ×) hide literals that are really there.
