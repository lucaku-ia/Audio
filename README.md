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
- **No episode has had audio since 2026-09-18, because the ElevenLabs account is out of credits.** Research and writing work fine; the voicing step has been failing silently for days, and the app has been showing "making your episode" the whole time. **Fixing it is a billing change nobody has made.** See "Why there is no audio" below — that section also has the real per-customer cost model, which is the thing to read before pricing anything.
- **Requests hang ~14s and sometimes 500 under load**, because generation runs inline in the HTTP handler and holds a DB connection through the whole research call, exhausting a 5+10 pool. Real errors in the logs. Not Railway sleeping — an earlier draft of this README said that, and it was wrong.
- **Mobile**: a real native iOS app (SwiftUI, not a wrapper) exists. PR #27 (tab architecture fix + real Home/Search/Interests) is **merged** — #23–#26 are correctly closed without merging, superseded by it. Full detail in "Mobile app (iOS)" below.
- **Free-text AI-categorized interests: done, verified against production.** The previous session's isolated worktree (bad `ANTHROPIC_API_KEY`, never actually saw a categorization result) was abandoned rather than fixed — this was rebuilt directly against this repo's own working deployment instead, where the key already works. Backend: `RequestOut.structured` exposed, `GET /requests?kind=` filter added. iOS: a "Search for anything" field in Interests wired to `POST /requests`. Verified live: typing "Arsenal FC" categorizes to `{topic: "Arsenal FC", geography: null}`; "La Liga" to `{topic: "La Liga football", geography: "Spain"}` — exactly the two test cases the founder wanted to see. iOS changes are unverified by an actual Xcode build (no macOS access this session) — build-check before trusting in production.
- **Session-expiry gap: fixed.** An expired/invalid token used to leave every screen showing a silent "not signed in" error forever (`SessionStore.clear()` was only wired to the manual Log-out button). `APIClient` now posts a notification on any 401; `SessionStore` observes it and clears itself, so the app's existing auth-routing sends the customer back to Login automatically. Same Xcode-build caveat as above.
- **Design**: three screens (Home, Player, Search/Interests) are designed, approved, and share one consistent token system grounded in real Apple HIG/Spotify/Audible research rather than guesswork. Login has been through three rounds of direct founder feedback and the founder has said it's not the current priority — don't invest further there without checking first. Look-and-feel links are in "Design system" below.
- **What's blocking further progress that only the founder can unblock**: Google Cloud Console (OAuth client ID for Google Sign-In), and Apple Developer Program enrollment ($99/yr — needed for push notifications, real-device testing, and eventually App Store submission). Voyage AI is the decided embeddings provider (see "Suggested next steps") but the account/key still needs to be created.

## Current status (as of 2026-09-23)

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

## Session of 2026-09-23 — first-run walkthrough, branding, and a slow backend

The onboarding flow Andrés built on 2026-09-21 had never been run anywhere. It was
walked end to end in the Simulator against production for the first time, then on a
real iPhone. Several things turned up that only running it could reveal.

### The big one: there is no audio, and the reason is a billing limit

`POST /api/generation/run`, run against production on 2026-09-24, got as far as the
voicing stage and stopped there:

```
quota_exceeded — This request exceeds your quota of 10000.
You have 291 credits remaining, while 782 credits are required for this request.
```

**ElevenLabs' free tier is 10,000 credits a month and it is spent.** A 66-second
episode costs ~780 credits, so the free tier was never going to be more than about a
dozen episodes. It ran out shortly after 2026-09-18, which is why the single episode
in the database with real audio is dated 2026-09-18 and nothing since has any.

Everything before voicing works, and works well. The same run produced, in 39 seconds
for $0.35, a real Spanish news script with cited sources:

> En inteligencia artificial, el movimiento más relevante de las últimas horas fue una
> doble jugada entre los dos grandes laboratorios. Anthropic lanzó Claude Opus 5.5 y
> recortó su precio un veinte por ciento…

— sourced to SiliconANGLE and CNBC. So the research half of the product is real. There
are several days of scripts sitting in the database that nobody can listen to.

**This is unblocked by a billing change, not by code.** Upgrading the ElevenLabs plan
keeps the same account and the same API key; nothing needs redeploying.

### …and then the system lies about it, which is what made the app feel broken

Three compounding defects, all ours, all worth fixing regardless of the quota:

1. **The job is never marked failed.** On a TTS exception `run_generation` appends the
   error to `job.stages` and leaves `job.status` at `voicing`
   ([episode_generator.py:673](backend/app/services/episode_generator.py:673)). Home's
   banner therefore reads `making` forever, with an ETA an hour out that will never
   arrive. A test account sat in that state for five days.
2. **The episode is published anyway**, with `audio_url: null`, `published_at` set and
   `duration_s` claiming 66 seconds. The app is handed something that looks ready and
   has no audio. This is the most likely explanation for the "crash" reports, and it is
   a far better suspect than the mic code.
3. **The DB pool is exhausted under any real use.** From the deploy logs:
   `sqlalchemy.exc.TimeoutError: QueuePool limit of size 5 overflow 10 reached,
   connection timed out, timeout 30.00`. `POST /generation/run` runs the whole pipeline
   inline in the request handler ([generation.py:107](backend/app/api/routes/generation.py:107)
   is candid about it) and holds its connection for the full ~40s of research, so other
   requests queue behind it and then 500. `create_async_engine` sets no pool size, so
   it is the SQLAlchemy default of 5 + 10 overflow.

**Correction to an earlier draft of this section:** it attributed the 14-second first
request to Railway putting the container to sleep. That was wrong. The service has no
sleep setting enabled and the deploy logs show continuous traffic; the hangs are pool
starvation, item 3 above. The measurement (14.4s cold, 0.41s warm) was real; the
explanation was not.

### What an episode actually costs

Measured, not estimated, from the run above: **782 ElevenLabs credits for 66 seconds**
of speech (11.8 credits/second) and **$0.348 of Claude** for one researched block.
ElevenLabs bills ~$0.18 per 1,000 credits, near-flat across plans — $0.142/audio-minute
on Starter down to only $0.117 on the $299 Scale tier, so there is no volume discount
to grow into.

At the current shape (one block per minute of audio):

| Episode length | Voice | Research | Per daily listener/month |
|---|---|---|---|
| 1 min | $0.13 | $0.35 | $14 |
| 5 min | $0.64 | $1.75 | $72 |
| 10 min | $1.28 | $3.50 | **$144** |

Two things worth internalising before pricing anything:

- **Research, not voice, is the dominant cost** at real episode length — 73% of it. The
  expensive part is not the part that feels like magic.
- **$5/customer/month is reachable, but only at ~1 minute a day**, and only if research
  is close to free. Voice alone at 2 min/day already exceeds $5. That is arithmetic, not
  an engineering problem.

Note the cost figures logged in `AICall` are a slight undercount: Anthropic's
`web_search` tool bills per search on top of tokens, and
[ai_platform.py:68](backend/app/services/ai_platform.py:68) says so — roughly $0.03 per
block, immaterial to the table above.

### Research split from writing, so it can be cached (PR #36)

The founder's proposal, and the right one: store what research finds, and when two
customers ask about the same thing, reuse the findings instead of researching from cold.

**To be unambiguous, because it is easy to hear this the wrong way: the facts are
shared, the episode never is.** Two customers on one topic share a research pass and
still get their own script, in their own style and language, voiced into their own audio
file. Nobody hears anybody else's episode. Sharing the *findings* is what makes
per-customer episodes affordable; it is not a step toward one briefing for everyone.

`research_and_write_block` made that impossible — one model call did both jobs and took
`customer_id`, `style` and `language`, so there was nothing customer-neutral to store.
PR #36 splits it:

| | `research_topic` | `write_block` |
|---|---|---|
| Web search | yes | **no** |
| Input | topic, scope, geography | findings, style, language, depth |
| Knows the listener | **no** (ids are for cost attribution only) | yes |
| Cacheable | yes — a pure function of (topic, time) | no, and shouldn't be |

Two things fall out beyond cost. The **writing stage does real work now** — it was a
bare status flip with no model call behind it. And **a writer can no longer invent a
citation**: returned sources are resolved by url against what research actually found,
so a hallucinated url yields no citation rather than a fabricated one, and the license
labels attached at research time survive.

The prompts have not yet faced a real model — there is no Anthropic key in the local
environment and Railway deploys only `main` — so structure, wiring and the invariants
are tested but **prompt quality is not**. Watch the first generation after #36 merges.

### Why the cache is a product feature, not just a saving

The PRD already asked for this and it was deferred for want of a semantic index. From
[episode_generator.py:69](backend/app/services/episode_generator.py:69):

> Real novelty judgment ("new since we last told this customer"… last 14 days): the
> index doesn't exist yet… **A request can currently get a near-identical block two days
> running if the topic hasn't moved.**

So today the product repeats itself, which is a failure of its core promise rather than
a cost problem. One store answers three needs at once:

1. **Cost** — don't re-research what is already known
2. **Novelty** — don't tell someone what they have already heard *(currently broken)*
3. **Continuity** — thread the story: *"that price cut from Tuesday — OpenAI just
   answered it"*

Shape it as two things, not one. **Findings**: shared, keyed on topic plus a freshness
window that varies by topic velocity (news in hours, standings in days, background in
weeks). **Told**: per customer, tiny, just references to which findings that person has
already heard. The expensive half stays shared; per-customer continuity costs a join
table.

Two cautions. Continuity means feeding history into the writing prompt, which cuts
slightly against the saving — though compact summaries are nothing next to 50k tokens of
raw search results. And a memory too pleased with itself ("as we mentioned Tuesday, and
as we noted Monday…") is worse than no memory; knowing when the thread matters is
editorial judgment living in the writing prompt.

### Onboarding dead-ended on a permanent spinner (PR #32)

The confirm step's network call lived in a `.task` attached to a view inside the
*not-yet-confirming* branch of an `if/else`. `confirm()` sets `isConfirming = true`
synchronously, which swapped that branch out for the spinner — destroying the view
that owned the task and cancelling the request mid-flight. The `defer` cleared the
flag, the branch returned, the task fired again: an infinite loop. The error alert
never appeared either, because each attempt clears `errorMessage` before it can
render. A real account sat stuck at step `confirm` server-side for minutes.

Worth remembering as a pattern: **never attach a `.task` to a view that the task's own
state change will remove.**

### `confirm()` promised an episode that was never coming (PR #31)

Separately: `POST /api/onboarding/confirm` returns *"Your first episode will be ready
by 23:36"* but never actually called `run_generation` — the wiring was left as a TODO
from before the Generator existed, and the stale docstring still said so. Customers
would have waited for an episode nothing was producing. #31 wires it up as a
background task (not awaited inline, which would reproduce the blocking-spinner
problem for real), adds a bounded retry after an honest `empty` day, and fixes the
day-zero plumbing.

Note the diagnosis history here, because it is instructive: the original hypothesis
was "the confirm endpoint blocks on generation". That was wrong — the endpoint
returned in 0.28 s. Verifying before fixing is what surfaced both the real client bug
and the missing wiring.

### The app forced dark mode on everyone (merged in #30)

`LucakuAudioApp` pinned `.preferredColorScheme(.dark)`, plus a `.colorScheme(.dark)`
on the onboarding time wheel. A phone set to light mode still got a fully dark app.
This was a deliberate choice (a listening app used at night and in the car) that
collided with the founder's stated preference and the approved mockups, which were
signed off in light. Resolved as **an Appearance setting** — System / Light / Dark,
stored per device — rather than either preference being forced globally.

### A customer with no profile was trapped (merged in #30)

`SettingsView` only rendered Sign Out in its `.loaded` state, so an account without a
Profile had no way to sign out, switch accounts, or reach any setting. Deleting the
app did not help either: **the session survives uninstall via the Keychain**, so the
reinstalled app came straight back into the same stuck account. Sign Out and
Appearance are now offered in the non-loaded states too.

### The app offered a suggestion its own backend rejects (merged in #30)

`onboarding_seeds.json` suggested *"How did my favorite team do this week?"*, which
`structure_request`'s clarity screen always refuses: *"We couldn't tell which team you
mean. Please reply with the team name (and league)."* Replaced with seeds naming a
concrete team. The rejection also surfaced as *"Something went wrong — Server error
(400)"*, burying a genuinely useful sentence; a 4xx carrying a message now shows that
message under the title "One more thing".

Related, and worth knowing for the autocomplete work: the classifier *wants*
specificity. `"How did Arsenal do this week in the Premier League?"` is accepted and
comes back with `structured.topic = "Arsenal Football Club"` — the per-item
categorisation the founder asked for already works.

### Brand identity (PR #33, applied in PR #34)

Produced in a Claude Code **cloud session** rather than locally — worth noting as a
working pattern: backend/design work needs no Mac and can run on cloud credits, while
anything touching Xcode, the Simulator or a real device has to stay local.

`design/brand/` now holds a wordmark, a compact mark, an iOS app icon, `BRAND.md`,
and a showcase page including a redesigned Login. #34 brings these into the app: the
real app icon (it shipped with iOS's blank default, which is most of why it read as
unfinished on a home screen), and the Login rebuilt on that design — wordmark, promise
line, a preview card that speaks a sample morning with the words lighting up, and a
single sign-up link replacing the duplicate mode control. Login copy is Spanish;
**the rest of the app is still English**, which remains an open gap.

#34 also replaced the generated-cover palette. It held ten saturated hues
(red/orange/amber/green/teal/blue/indigo/**purple**/pink/slate) picked by hashing the
topic; the founder's reaction to landing on the purple was unambiguous. It also
contradicted the design spec on two counts — the accent is meant to be the only strong
colour, and generated art is meant to read "muted, desaturated… ambient, not
celebratory". Now eight muted tones around the brand accent. The mini player, which
had been laying the cover colour over its surface at 55%, went to a solid surface with
a hairline: the tint read as grey-green mud on a light background.

### Still open

- **The crashes are unexplained.** Hangs are explained by the cold start above, but a
  genuine crash was reported and never reproduced or diagnosed. The mic/speech code is
  the leading suspect: it is the one part of the app that has never executed anywhere
  but a real device, since the Simulator has no microphone. Nobody has confirmed
  dictation works.
- **Day-zero content still needs generating operationally.** #31 makes the plumbing
  correct; `POST /internal/generate-shared-inventory` has to actually be run against
  production, or a new customer still waits an hour for anything to listen to.
- **UI localization** — everything outside the Login screen is hardcoded English for a
  Spanish-speaking customer base.

## Suggested next steps

**Do these first.** Everything else in the list below is secondary to the fact that the
product currently produces no audio and does not admit it.

- **A. Upgrade the ElevenLabs plan.** *(founder only — billing.)* Nothing generates audio
  until this happens. Free tier is 10,000 credits/month against ~780 per episode.
  elevenlabs.io → the account whose key is in Railway → Subscription. Starter at $6/month
  is ~40 short episodes, enough to dogfood for a month; don't buy capacity that can't be
  filled yet. Same account, same key, no redeploy.
- **B. Stop the system lying when voicing fails.** A TTS failure must mark the job failed
  with a real reason, must not publish an episode with `audio_url: null` as though it were
  ready, and Home must say something honest instead of "making" with an ETA that never
  arrives. This is what a customer actually experiences today. Also clear the jobs
  currently stuck at `voicing`.
- **C. Get generation off the request path.** `POST /generation/run` holds a pool
  connection for ~40s and starves every other request (`QueuePool limit of size 5 overflow
  10 reached` in the logs). Background the work, and set an explicit pool size while
  you're there — `create_async_engine` is using the library default.
- **D. Build the findings store.** PR #36 split research from writing to make this
  possible; the store itself is the payoff — cost, novelty and continuity in one
  structure. See "Why the cache is a product feature" above for the shape.
- **E. Find the crash.** Still unreproduced, but note that suspicion has moved: an
  episode published with no audio (B above) is a much better candidate than the mic code.
  Fix B first and see whether "the crash" survives it. If it does: Xcode → Window →
  Devices and Simulators → View Device Logs gives the exact frame.

**Measure, don't estimate.** Every cost figure in the plan rests on a single measured
block ($0.348, one topic, two sources). Before designing around the model, run a handful
of real blocks and get a distribution — and settle whether a cheaper model can do the
research, since research is 73% of the cost and `MODEL` is currently `claude-opus-5`
([ai_platform.py:63](backend/app/services/ai_platform.py:63)) for "search the web and
write a one-minute news script". That is an hour of work and it needs nothing from anyone.

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
5. ~~Build-verify the iOS changes on a real Mac~~ — **done** (2026-09-23). The app
   builds clean, was run in the Simulator against production through signup →
   onboarding → Home → playback, and was installed and used on the founder's own
   iPhone. Doing this is what surfaced everything in "Session of 2026-09-23" above.
   One testing note worth keeping: **the Simulator Keychain survives app deletion**,
   so a reinstall silently signs you back into the old account and makes fixed bugs
   look unfixed. Reset it between auth tests:
   `xcrun simctl keychain <udid> reset`.
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
   **Still true after PR #31**: #31 fixes the day-zero *plumbing* (a new customer's
   first episode now actually gets generated, and an honest `empty` day retries once
   from shared inventory) — but it cannot invent content that isn't there. Somebody
   has to run the command above against production, or a brand-new customer still
   opens an app with nothing to listen to.
7b. ~~Guided, voice-led onboarding in the iOS app~~ — **built** (2026-09-21) and
   **now run end to end** (2026-09-23), in the Simulator and on a real iPhone; the
   permanent-spinner dead-end it shipped with is fixed in PR #32. Still untested
   anywhere: **the mic/dictation path**, since the Simulator has no microphone — see
   item B above.
7c. **UI localization.** Still the gap it was: the Login screen is Spanish as of
   PR #34, and everything behind it is hardcoded English while the founder and
   customers are Spanish-speaking (`Cliente.idioma` defaults to `es`). The backend
   already localizes catalogue labels and suggestions, so this is app-side only.
8. **Google/Apple OAuth for real** — the login screen's Google Sign-In button is
   still a stub, though as of PR #34 it says so out loud when tapped ("Continuar con
   Google estará disponible pronto") instead of failing silently. Needs the founder to create an OAuth client ID in
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

Done as of 2026-09-24: found why there is no audio — the ElevenLabs free-tier quota is
spent, and has been since shortly after 2026-09-18. Confirmed by triggering a real
generation against production, which also proved the research half works well ($0.35,
39 seconds, real Spanish script with cited sources). Found three of our own defects
alongside it: the job is never marked failed when voicing dies, the episode is published
anyway with no audio, and the DB pool is exhausted by generation running inline in the
request handler. Corrected this README's earlier claim that the 14-second hangs were
Railway sleeping — they are pool starvation. Measured the real per-episode cost and wrote
down the cost model ($144/month per daily 10-minute listener; research is 73% of it).
Split research from writing (#36) so findings can be cached and shared across customers
without sharing episodes. Full detail in "Session of 2026-09-23" above.

Done as of 2026-09-23: the onboarding flow was run end to end for the first time —
Simulator and a real iPhone — which is what turned up the permanent-spinner dead-end
(#32), the `confirm()` endpoint promising an episode nothing was generating (#31), the
~14s cold start, the sign-out trap, and a suggested interest the backend itself always
rejects. The forced-dark-mode conflict was resolved into a per-device Appearance
setting rather than either side winning. Brand identity landed (#33) and went into the
app (#34): real app icon, Spanish branded Login, and a muted cover palette replacing
the saturated one. Full write-up in "Session of 2026-09-23" above.

Open pull requests as of this writing: **#31** (backend first-run fixes), **#32**
(confirm dead-end), **#33** (brand files), **#34** (brand in app), **#35** (this
README), **#36** (research/writing split). **#12** is an older Login composition pass
and is superseded by #34 — close it rather than merging.

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
