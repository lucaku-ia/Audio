# Lucaku Audio — Claude Code task backlog (v1.0)

Put this file at the root of the repository as `docs/TASKS.md`. Start each Claude Code session with: "Read docs/TASKS.md and CLAUDE.md, and do task T-xxx".

## Sources of truth

Read these before coding. They are in Drive, in the folder "PRDs v1.0 (after design review)".

- **System Contracts v1.1:** the types and endpoints. If the code and Contracts disagree, Contracts wins; propose the change in the PR.
- **PRD v1.1 (umbrella)**, sections 6–8: architecture and front↔back interactions.
- **Architecture Review ADRs v1.1:** ADR-1 to ADR-9.
- **The epic PRDs:**
  - Login v3, Onboarding v5, Home v2, News Feed v1, Player v2, Topics v2;
  - Episode Generator v2, Sharing v1, Notifications & Settings v2, History v2;
  - AI Platform v2, Instrumentation v2.
- **The screen spec:** `lucaku-audio-screens.md`, plus the canvas prototype (screen ids 1.x–6.x).

## Global rules (copy into CLAUDE.md)

1. **One repo, TypeScript everywhere except iOS.** It is a monorepo with pnpm workspaces:

   ```
   apps/api        Fastify, /v1
   apps/worker     Graphile Worker + scheduler
   apps/web        Next.js: share page + ops console
   packages/contracts  zod schemas + types + OpenAPI generation
   packages/db     SQL migrations (Supabase), typed queries
   packages/modules/{identity,topics,content,sharing,notifications,episodes,news,sources,ai,events}
   prompts/{name}/v{n}.md + schema.ts + evals/
   ios/LucakuAudio (existing repo lucaku-ia/Audio)
   ```

2. **Module boundaries:**
   - modules call each other only through `packages/modules/<m>/index.ts`;
   - no module reads another module's tables;
   - only `modules/ai` imports the Anthropic, ElevenLabs or embedding SDKs. Add an ESLint `no-restricted-imports` rule for this.
3. **Contracts first.** Change `packages/contracts`, regenerate OpenAPI, then implement. The Swift client is generated from OpenAPI (swift-openapi-generator).
4. **Every worker stage is idempotent:**
   - store its output on the job;
   - unique job keys;
   - safe to retry.
5. **Every customer-visible feature emits the events listed in its PRD,** through `events.track`.
6. **Tests:**
   - vitest for modules;
   - API integration tests against a local Supabase (`supabase start`);
   - at least one happy path and one failure per endpoint.
7. **App language:**
   - the app is English only;
   - under a title, at most 2 lines of text;
   - light mode leans white;
   - in dark mode, no light blue on black.
8. **Secrets:**
   - only in environment variables;
   - `.env.example` lists them all;
   - never commit keys.
9. **Small PRs:** one task, one PR. The PR description lists the acceptance criteria and how they were checked.

## How to read a task

Each task has:

- ID and title;
- owner (Juan = J, Andrés = A);
- size: S ≤ 0.5 day, M 1–2 days, L 3–5 days;
- dependencies;
- context (the PRD section or screen);
- what to build;
- acceptance criteria (AC).

---

## M0 — Foundations (week 1)

### T-001 Monorepo scaffold · J · M · deps: none

**Context:** ADR-1, ADR-9.

**Build**

- pnpm workspaces with the layout above.
- Shared tooling:
  - TypeScript strict;
  - ESLint + Prettier;
  - vitest;
  - tsconfig paths.
- Two placeholder apps: `apps/api`, a Fastify app with `GET /v1/health`; and `apps/worker`, a Graphile Worker that runs a `hello` task.

**AC**

- `pnpm i && pnpm build && pnpm test` passes.
- `pnpm dev` runs the API and the worker together.
- The ESLint rule blocks importing `@anthropic-ai/sdk` outside `modules/ai` (a test file proves it).

### T-002 Supabase project + migrations pipeline · J · M · deps: T-001

**Context:** ADR-2.

**Build**

- Supabase CLI in `packages/db` with `supabase/migrations`.
- Two environments: local and staging.
- Enable pgvector.
- Create the `graphile_worker` schema on first worker run.
- A typed query helper (Kysely or postgres.js with zod).

**AC**

- `supabase start` + `pnpm db:migrate` work from scratch.
- Staging is migrated by CI.
- `pnpm db:types` generates the DB types.

### T-003 Contracts package v1.1 · J+A · L · deps: T-001

**Context:** System Contracts v1.1 (all objects and endpoints).

**Build**

- zod schemas for every object: Account/Profile, Device, Category, Topic, TopicVersion, Feedback, Signals, GenerationJob, Episode, Story, TranscriptLine, NewsJob, NewsItem, ReadState, PlaybackPosition, ShareLink, Referral, Notification, InventoryItem, Event, AICall.
- Request/response schemas per endpoint.
- OpenAPI 3.1 generation (`pnpm contracts:openapi` → `openapi.yaml`).

**AC**

- `openapi.yaml` validates.
- Every endpoint in Contracts §API is present.
- A snapshot test fails when the contract changes without a regenerated file.

### T-004 Database schema v1 · J · L · deps: T-002, T-003

**Build**

- Migrations for all the tables in Contracts.
- RLS on:
  - account-owned tables (account_id = auth.uid());
  - public share data read only through the API (service role).
- Indexes:
  - news (topic_key, published_at);
  - episodes (account_id, local_date) unique;
  - events (ts) partitioned by month;
  - a pgvector index on story/news embeddings.
- A seed with the 12 categories and their examples.

**AC**

- Migrations run up from empty.
- Seed loads.
- An RLS test: account B cannot read account A's topics through the anon key.

### T-005 CI/CD + environments · J · M · deps: T-001, T-002

**Build**

- **CI (GitHub Actions):** lint, typecheck, test with a Supabase service container, build.
- **Deploy:**
  - the API and the worker to the chosen platform (Render, Fly.io or Railway);
  - staging on merge to main;
  - production by tag.
- **Sentry** for the API and the worker.
- **Secrets** in the platform; `.env.example` complete.

**AC**

- A PR shows green checks.
- A merge deploys to staging.
- `GET staging/v1/health` returns the commit sha.

### T-006 ai module skeleton · J · M · deps: T-003, T-004

**Context:** AI Platform PRD v2.

**Build**

- `ai.run(promptName, input)`:
  - loads `prompts/{name}/v{active}.md` + `schema.ts`;
  - calls Claude;
  - validates the output with zod;
  - retries 429/5xx with backoff (max 3);
  - uses per-provider concurrency pools (p-limit, configurable);
  - writes an AICall row (tokens, cost_usd, latency, prompt_version, account_id/topic_key/job_id/stage).
- `ai.embed(texts)`.
- `ai.voice(script, voiceId)` returning audio + timestamps (ElevenLabs with timestamps).
- A budget check (default USD 0.60/day per account) and a global kill switch (env).
- Model ids live in config ("fast", "main").

**AC**

- Unit tests with mocked providers: retry, fallback, budget exceeded → `BudgetExceededError` + `budget_exceeded` event.
- Every call produces an AICall row.

### T-007 events module · A · S · deps: T-004

**Context:** Instrumentation PRD v2.

**Build**

- `events.track(name, props, {accountId|anonId})`.
- `POST /v1/events` (batch ≤ 50, authenticated or anonymous).
- A worker task `events.export` every minute → PostHog batch API; marks `exported_at`.
- An event name allowlist from the catalogue.

**AC**

- Unknown event names are rejected with 400.
- The export is idempotent (re-running does not duplicate in PostHog: it uses the event uuid).

---

## M1 — Walking skeleton (weeks 2–3)

**Goal:** Sign in with Apple → add one topic → on-demand episode → play it. Everything thin, but real end to end.

### T-101 Auth: Supabase Auth + /me · J · M · deps: T-004

**Context:** Login PRD v3.

**Build**

- A Fastify plugin that verifies the Supabase JWT and loads the account.
- `GET /v1/me`, `PATCH /v1/me`.
- `POST /v1/devices`.
- Account + Profile are created on first call (trigger or upsert).

**AC**

- 401 without a token.
- The first call creates the profile with defaults: timezone from the header; delivery 07:00; length standard.

### T-102 iOS: Sign in with Apple + API client · J · M · deps: T-101

**Context:** Login PRD v3, screens 1.x.

**Build**

- Supabase Swift SDK sign-in with Apple (+ email magic link as a fallback).
- An OpenAPI-generated Swift client with a bearer token.
- A 3-tab shell (Home, Interests, Profile) with empty states.

**AC**

- On a device: sign in → the app calls /me → the shell shows.
- Sign-out works.
- The token refreshes silently.

### T-103 Topics: minimal create/list · A · S · deps: T-101

**Build**

- `POST /v1/topics` (label, category, raw_text) without AI.
- `GET /v1/topics`.
- topic_key = lowercased label (temporary).

**AC**

- CRUD integration tests.
- RLS enforced.

### T-104 Episode pipeline thin version · J · L · deps: T-006, T-103

**Context:** Episode Generator PRD v2 §5.

**Build**

- `POST /v1/jobs/generate-now` enqueues `episode.run`.
- Graphile tasks per stage with stage_outputs on GenerationJob:
  - load;
  - research (one news API, top 3 articles per topic);
  - write_story (one story per topic);
  - assemble_script;
  - voice;
  - publish.
- Audio is uploaded to Supabase Storage.
- The Episode, Story and TranscriptLine rows are written.

**AC**

- One topic → an episode with ≥ 1 story and playable audio in under 10 min on staging.
- Killing the worker mid-run and restarting resumes from the last completed stage without a second voice call (verified via AICall rows).

### T-105 Job status + polling · J · S · deps: T-104

**Build**

- `GET /v1/jobs/today` → {state, steps, topics_count, eta, episode_id?}.

**AC**

- The state moves queued → researching → writing → voicing → ready.
- The response p99 is under 150 ms.

### T-106 iOS: Home card + basic player · J · M · deps: T-105, T-102

**Context:** Home 3.1, 3.10–3.13; Player 4.1–4.2.

**Build**

- **Home card:**
  - polls /jobs/today every 10 s while making;
  - a ready state with Play.
- **Player:**
  - AVPlayer with a signed URL;
  - mini player;
  - a full player with ±15 s and speed;
  - Now Playing info.

**AC**

- Demo video: sign in → add topic (temporary form) → Generate now → watch the steps → play → lock-screen controls work.

**M1 exit:** the demo above works on staging with a real topic. **Show the founders before starting M2.**

---

## M2 — Onboarding chat + topics intelligence (weeks 4–5)

### T-201 Intake prompts · A · M · deps: T-006

**Context:** Topics PRD v2 §5; Onboarding PRD v5.

**Build**

- Prompts with zod schemas and 10+ eval cases each: parse_topics, clarify_topic, suggest_related, validate_topic (returns topic_key).
- `pnpm evals` runs them against the real model (manual / nightly).

**AC**

- parse_topics splits "AI regulation in the EU and my team Real Madrid" into 2 topics with the right categories.
- A broad input ("tech") is marked broad.
- The evals pass at ≥ 90%.

### T-202 Intake endpoints · A · M · deps: T-201, T-004

**Build**

- POST /v1/intake/parse, /intake/clarify, /intake/suggest.
- GET /v1/intake/examples, GET /v1/categories.

**AC**

- p90 under 2.5 s on staging.
- Suggestions exclude followed topics.
- Curated examples are served first.

### T-203 topic_key normalisation · A · M · deps: T-201

**Build**

- Normalisation: lowercase, trim, alias table.
- An embedding collision check (cosine ≥ 0.92 → reuse the existing key).
- A backfill script for the T-103 topics.

**AC**

- "Real Madrid" and "real madrid fc" share a key (test).

### T-204 Topics full API · A · M · deps: T-202, T-203

**Build**

- Endpoints:
  - POST /topics (batch);
  - PATCH /topics/{id} (creates a TopicVersion);
  - DELETE /topics/{id} (soft) and POST /topics/{id}/restore;
  - pause and resume.
- A limit of 15 active topics.

**AC**

- The version history is stored.
- Restore works within 30 days.
- The 16th topic returns a 409 with copy.

### T-205 Onboarding endpoints + state · A · M · deps: T-204

**Context:** Onboarding PRD v5.

**Build**

- POST /onboarding/start.
- onboarding_state persisted per account; resumes where the customer left.
- POST /onboarding/complete:
  - saves the profile delivery prefs;
  - enqueues the news runs for new keys;
  - serves the sample.

**AC**

- Killing the app mid-onboarding and reopening resumes at the same step.
- complete is idempotent.

### T-206 iOS: Onboarding chat UI · J · L · deps: T-205

**Context:** screens 2.1–2.12, lucaku-audio-screens.md.

**Build**

- The chat state machine: start → confirm → suggest ⟲ → (cats → detail ⟲) → time → len → style → voice → summary → finishing.
- Tap options and a free-text field.
- A push pre-prompt.

**AC**

- Matches the canvas screens.
- VoiceOver works.
- The events from the Onboarding PRD fire (checked in PostHog staging).

---

## M3 — News feed + Home (weeks 5–6)

### T-301 sources module · J · M · deps: T-006

**Build**

- An adapter interface + 1–2 licensed news APIs (English).
- `sources.fetch(queryPlan, since)` → normalised articles.
- Dedupe by URL and by title similarity.

**AC**

- Rate limits respected.
- Responses are cached for 15 min per query.

### T-302 News pipeline · A · L · deps: T-301, T-203

**Context:** News Feed PRD v1 §5.

**Build**

- A NewsJob per (topic_key, date, slot) with these stages: fetch, cluster (embeddings ≥ 0.85), judge_novelty, write_news_item (max 3), check (grounding, length), publish.
- The scheduler enqueues the 05:00 and 13:00 slots per timezone band.

**AC**

- One run for a key with 50 followers costs the same as with 1 follower.
- No item is published without a source.
- Summary ≤ 70 chars (test).

### T-303 News API · J · M · deps: T-302

**Build**

- GET /news (by day, cursor, last 7 days, ranking by signals).
- GET /news/{id}.
- PUT/DELETE /news/{id}/read and POST /news/read-all.

**AC**

- p99 under 400 ms with 30 topics in the seed data.
- Read state is per account.

### T-304 GET /home aggregate · J · M · deps: T-303, T-105

**Build**

- One call returns:
  - the card state (ready, making, making_eta, late, empty_day, re_entry);
  - the next delivery;
  - followed topics;
  - news page 1.

**AC**

- No N+1 (query count asserted in the test).
- p99 under 800 ms.

### T-305 iOS: Home full · J · L · deps: T-304

**Context:** Home PRD v2, screens 3.1–3.16.

**Build**

- All the card states.
- The "Your Lucaku" card.
- The news feed: by day, unread dots, swipe read/unread, "Show N more", "Mark all read".
- The news detail with sources and the "In today's episode" link.
- The empty-day and no-topics states.

**AC**

- Every canvas state is reproducible with a debug menu.
- Cached first paint under 1 s.

### T-306 Episode ↔ news link · A · S · deps: T-302, T-104

**Build**

- Story.cluster_id.
- `news.link` in both directions (whether the episode or the news runs first).

**AC**

- An integration test links a story and an item on the same cluster.

---

## M4 — Player complete + feedback (week 7)

### T-401 Full generator · J · L · deps: T-104, T-302

**Context:** Episode Generator PRD v2.

**Build**

- Add these stages: research_plan, judge_novelty, trim, headline.
- 2-line summaries, the 6-colour palette and story ordering by signals.
- Reuse the same-day news clusters.
- Sentence-level transcript timings.
- The scheduler enqueues at T−60.
- The late state at T and the T+15 cutoff.

**AC**

- Length within ±15% of the target.
- An empty day when nothing is new.
- An OpenTelemetry trace per job.

### T-402 Feedback + signals · A · S · deps: T-204

**Build**

- POST /feedback (story/episode/news; more, less, useful, not_quite + reasons).
- Signals are updated in the same transaction.

**AC**

- More and Less are exclusive per target.
- Toggling twice removes the feedback.

### T-403 iOS: Player complete · J · L · deps: T-401, T-402

**Context:** Player PRD v2, screens 4.1–4.10.

**Build**

- In this episode: colours, summaries, seek.
- Transcript karaoke with tap-to-seek.
- More/Less per story and the Not quite sheet.
- Position sync every 10 s.
- Downloads.
- The new-episode toast.

**AC**

- Highlight drift under 300 ms.
- Offline playback works in airplane mode.
- Position is restored after an app kill.

---

## M5 — Interests, Profile, notifications (week 8)

### T-501 iOS: Interests tab · A+J · M · deps: T-204

**Context:** screens 6.1–6.4.

**Build**

- The list grouped by category.
- Add (reuses the intake chat).
- Edit, delete with undo, recently removed.
- Delivery settings.

**AC**

- Matches the canvas.
- "Applies tomorrow" is shown after an edit.

### T-502 Push sending + inbox · A · M · deps: T-401, T-101

**Context:** Notifications & Settings PRD v2.

**Build**

- APNs sender (token key) in the worker.
- Episode-ready push at publish.
- An optional reminder.
- A server cap of 2 per day.
- Endpoints: GET /notifications and POST /notifications/{id}/read.
- Pruning of 410 tokens.

**AC**

- A third push on the same day is blocked and the `push_capped` event is logged.
- Tapping a push deep-links to the player.

### T-503 iOS: Profile (option A) + settings · J · M · deps: T-502

**Build**

- All the sections from the PRD: History list (History PRD v2), Downloads setting, Notifications toggles, Privacy, Sign out.

**AC**

- Every setting persists through PATCH /me.

### T-504 Delete account + data request · J · M · deps: T-101

**Build**

- `DELETE /me`:
  - signs out immediately;
  - a worker task `account.purge` deletes the data within 30 days;
  - revokes share links;
  - anonymises events.
- `POST /me/data-request`.

**AC**

- An audit row is written.
- After the purge, no rows with that account_id remain except anonymised events (test).

### T-505 History · J · S · deps: T-401

**Build**

- `GET /episodes?before&q` with full-text search over headline and story titles.

**AC**

- Paginates 20 at a time.
- Search returns matching episodes.

---

## M6 — Sharing + day zero (week 9)

### T-601 Story clips · J · S · deps: T-401

**Build**

- In the publish stage, cut the first 30 s of each story with ffmpeg and store it as story_clip.

**AC**

- Each story has a clip of 30 ±1 s.

### T-602 Sharing API · J · M · deps: T-601

**Build**

- POST /share, DELETE /share/{slug} and GET /public/share/{slug} (CDN cache 5 min).
- Random 10-character slugs.
- A Referral token.

**AC**

- The public endpoint exposes no account data except the optional first name.

### T-603 Web: share landing · J · M · deps: T-602

**Context:** Sharing PRD v1.

**Build**

- Next.js page /s/[slug]:
  - clip player, summary, sources, CTA to the App Store with a referral token;
  - OG image;
  - noindex.
- Universal links (apple-app-site-association).

**AC**

- LCP under 1.5 s (Lighthouse mobile).
- The link preview renders in iMessage.

### T-604 Referral attribution · A · S · deps: T-602, T-101

**Build**

- Match on first open within 24 h.
- Create a Referral row.
- Emit the `referral_attributed` event.

**AC**

- An end-to-end test with a simulated token.

### T-605 Inventory + day-zero sample · A · M · deps: T-401

**Build**

- InventoryItem curation in the ops console (T-701).
- A weekly worker refresh that pre-voices the inventory.
- `onboarding.complete` assembles a sample from 2–3 items matching the categories in under 20 s.

**AC**

- A new account has a playable sample right after onboarding.

### T-606 iOS: share sheet · J · S · deps: T-602

**Context:** screens 4.8–4.9.

**AC**

- Sharing from the player and from news detail works.
- Copy link and the iOS share sheet work.

---

## M7 — Ops, observability, load (week 10)

### T-701 Ops console (web, internal) · A · M · deps: T-004

**Build**

- Supabase Auth limited to an allowlist of founder accounts.
- Pages:
  - category examples;
  - curated suggestions;
  - sources;
  - inventory;
  - jobs view (state, stage, cost, retry button).

**AC**

- Only allowlisted accounts can enter.
- Retrying a failed job works.

### T-702 Metabase pilot dashboard · A · M · deps: T-007, T-006

**Context:** Instrumentation PRD v2 §2.

**Build**

- SQL views in /analytics.
- Dashboard cards: activation, D1/D7, completion, news opens, shares/k-factor, on-time %, cost per active customer per day.
- The kill criteria cards.

**AC**

- The dashboard loads with the staging seed data.

### T-703 Load test 06:00 burst · J · M · deps: T-401, T-302

**Build**

- A script that creates 100 accounts with delivery 07:00 and runs the scheduler.
- Measures on-time %, provider 429s and cost.

**AC**

- ≥ 95% ready by T with 2 worker replicas.
- The report is in docs/load-test.md.

### T-704 Event coverage test · A · S · deps: all

**Build**

- A test that compares the event catalogue with the events seen in staging during an e2e run.

**AC**

- 100% coverage before the pilot.

### T-705 Pilot readiness checklist · A+J · S

**Checks**

- App Store review items:
  - Sign in with Apple;
  - delete account;
  - privacy labels.
- Backups on.
- Alerts:
  - job failure rate > 5%;
  - budget kill switch;
  - API 5xx.
- On-call between the founders.

**AC:** the checklist is in docs/pilot-readiness.md with every box ticked.

---

## Order and parallel work

The milestones run in this order:

```
M0 ─► M1 (walking skeleton, demo) ─► M2 ─┬─► M3 ─► M4 ─► M5 ─► M6 ─► M7 ─► Pilot
                                         └─ (A) prompts/evals in parallel
```

- **Juan:** API + iOS + generator.
- **Andrés:** topics, news, notifications, events, ops and dashboard.
- **Both:** Contracts (T-003). Every change to Contracts is reviewed by both.

## Open decisions that block tasks

| Decision | Blocks |
|---|---|
| Profile option A/B/C (A assumed) | T-503 |
| Generate-now limit after the first episode | T-304, T-305 |
| Day zero: first personal episode immediately or at the first delivery time | T-205, T-605 |
| Hosting platform (Render, Fly.io or Railway) | T-005 |
| News API provider(s) and licence | T-301 |
| Domain lucaku.app | T-603 |
