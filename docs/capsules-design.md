# Capsules: design document (rev 2)

Status: proposal for founder review, revised after senior review. Author: software architect. Design only, no production code.
Baseline read: `origin/main` (da0c772), `origin/fix/combined-review` (PR #65 state: feedback, account, search, conftest, news_pipeline) and `origin/feat/ai-budget`. Anything marked **(unverified)** was not confirmed from the repository.

## 1. Problem, goals, current state

Today one request produces one monolithic episode per listener. Research is shared (findings store); writing and voicing are per listener; voiced blocks are byte-concatenated into one mp3.

Goals (founder decisions, not re-opened): capsules of one topic each, 2-3 min ceiling, content-driven length; listener can prioritise, pick, or "play all"; one capsule is generated once and served to many users; everything shareable when the topic key matches (text normalisation only until embeddings); 2 voices synthesised lazily; one writing style in the pilot; only greeting and name in a short personal intro; pre-voiced transitions.

Current state, with the facts the design depends on:
- `episode_generator.run_generation`: sequential research (`research_topic`, cached by `findings_store`, TTL 6 h fresh / 45 min empty) then `write_block` (per listener; takes `style`, `language`, `depth`, `previously_told`) then `_synthesize_episode` (voices every block, `b"".join` into one file, sets `Episode.audio_url` and `published_at`). A single TTS failure fails the whole job. It runs inline on one `AsyncSession`; there is no job queue, the scheduler calls it inline. `run_generation` calls `guard_paid_call("generation_precheck")` up front (feat/ai-budget).
- `Block` has `start_s/end_s` estimated at 150 wpm, `script`, `sources`, `word_timestamps` (block-relative). `told_log` treats any non-`no_news` Block of a *published* episode as told. `search.py` reports `state = "ready" if ep.audio_url else "voicing"`. The PR #43 bug class (publishing before audio exists) is the reason `published_at` is stamped only after audio.
- `trim_factor` truncates scripts by word count (cuts mid-thought) to honour `max_length_minutes`.
- `research_topic` puts `raw_text` (the user's own words) into the research prompt; `scope` and `geography` come from a per-user Haiku structuring step. `researched_from` stores the first requester's text in the shared findings row.
- Feedback (`feedback.py::_resolve_subjects`): `story` targets resolve by `Block.id` (404 otherwise), request taken from `Block.request_id`; signals stay per user, per request.
- `account.py` deletes customer data explicitly (no `ON DELETE CASCADE` there); `tests/conftest._FULL_SESSION_TABLES` lists tables truncated between tests.
- News: `news_pipeline` has `MAX_ATTEMPTS=3`, `STALE_RUNNING` 30 min, claim-by-unique-key (`NewsRun`), cost recorded on the run row even on failure, `title_similarity` for dedupe, and a daily cost ceiling. 12 categories (`CATEGORIES`).
- ai-budget: `guard_paid_call` treats `customer_id` None or `UUID(0)` as a news caller (only the kill switch applies; news has its own ceiling). `AICall` rows roll back with the transaction on failure.
- iOS: `PlayerViewModel` plays one file and seeks to `block.startS`. `AudioPlayerService.play(queue:)` exists but swaps `AVPlayerItem`s on `DidPlayToEndTime` (single `AVPlayer`, no preload, not gapless). No server-side playback position exists.
- Voice: `Profile.voice_id` is client-settable free text; null resolves to `_default_voice_id()` at synthesis.

## 2. The Capsule model

### 2.1 Identity: claim key vs content identity

Two separate things, because the findings fingerprint cannot be known before research:

- **Claim key** (known before any work): `(topic_key, geography_key, language, style_id, prompt_version)`, all via `findings_store.normalize`. This is what the single-flight claim and the "is there a live capsule" lookup use. **`scope` is dropped from the key in the pilot**: scope comes from a per-user Haiku structuring step and would fragment otherwise identical topics. The shared research input is topic + geography only (below, 2.5).
- **Content identity** (known after research): `findings_fingerprint` = hash of the normalised headlines+urls of the findings used. It is used only for exact dedupe, not as a novelty signal (LLM research reshuffles headlines every window, so a changed fingerprint does not mean news).

Voice is not part of the content key: it is a child (`capsule_audio`). `depth` is dropped from the key (it fragments sharing and fights content-driven length); the time budget replaces it (founder question 5).

### 2.2 Flow (miss path, in order)

1. Normalise the request to a claim key. Look up a live capsule (`valid_until > now`, `status=ready`). Hit: attach, zero model calls.
2. Miss: try to claim the key (unique partial index on the claim key where status in `queued|researching|writing`). Winner proceeds; losers see 2.4.
3. `findings_store.lookup` (research cache, topic + geography only); on miss, `research_topic`.
4. Compute fingerprint. If a previous capsule for this claim key exists, run the **novelty check**: compare the new findings' headlines with the previous capsule's stored headlines using `title_similarity` (as `news_pipeline` does). If every new finding matches the previous set above the threshold, nothing new: extend the previous capsule's `valid_until` and reuse it (no write, no voice). Only if something genuinely differs create a new capsule and set `prev_capsule_id` (so "update" labelling means a real update).
5. Write once (listener-independent prompt), persist text as `ready`. Voice is a separate step per voice (section 5).

### 2.3 What is stored

`capsules`: id, claim-key columns, `status` (`queued|researching|writing|ready|failed|empty|blocked|retired`), `attempts`, `next_attempt_at`, `claimed_at`/`updated_at` (heartbeat), `script`, `summary`, `headlines` (for the novelty check), `sources` (same shape as `Block.sources`), `fingerprint`, `findings_cache_id`, `as_of`, `valid_until`, `category`, `duration_est_s`, `owner_customer_id` (null = shared), `cost` (committed ledger, see 6), `error_code`.
`capsule_audio` (capsule x `voice_key`): `audio_url` (random uuid filename), real `duration_s`, `word_timestamps` (capsule-relative), `chars`, `cost`, `status`, `attempts`.
`researched_from` is **not** copied to capsules and never exposed via the API.

### 2.4 Single-flight: what losers do

Losers poll the winner's claim row (short interval, timeout ~90 s). Outcomes: winner `ready`: attach. Winner `failed`/`blocked`/timeout: the loser does **not** inherit that outcome as its own failure. Shared capsules are paid by the platform sentinel (section 6), so one customer's budget can never block a shared capsule for everyone; what *is* shared and legitimately inherited is a global block (kill switch, capsule ceiling). On timeout the item is left `pending` in the playlist and retried on the next scheduler tick or playlist poll, never blocking the episode. **Stale claim reclaim**: a claim whose `updated_at` is older than 30 min (Railway redeploy killed the task) is re-claimable, consuming one attempt, as in `NewsRun._claim_run`.

### 2.5 Privacy and wrong-listener safeguards

- `raw_text` is removed from the shared research and writing path (today it leaks the first requester's phrasing into shared findings). Cost: loses the "how did Arsenal do" intent hint. The claim key is the normalised structured topic, so free-form questions that normalise to the same topic share; the rest stay bespoke (founder question 6).
- A **bespoke** capsule (`owner_customer_id` set, e.g. a private or niche question) is readable only by its owner; a shared capsule is readable only if it is in the caller's own playlist (`episode_items` join). No capsule is readable by id alone.
- Test: shared scripts must contain no listener name, no `raw_text` substring, no "you/your" (fixture-based).

### 2.6 Lifecycle, invalidation, retries

- `valid_until = as_of + FRESH_TTL` (6 h) for news, `+ EMPTY_TTL` (45 min) for no-news (empty capsule row stops thundering herds, never playable; preserves the PR #31 empty-day property).
- **Retry cap**: per claim key `attempts <= 3` with 45 min backoff (`next_attempt_at`), exactly like `NewsRun.MAX_ATTEMPTS`; beyond it the key stays `failed` until the window rolls. A failed capsule is **not** silently retried by every next requester.
- **Retire action** (ops/internal route, Phase 2a): marks a capsule `retired`; next lookup regenerates (bounded by attempts). Needed because a shared bad capsule reaches many users.
- **`prompt_version` bump** invalidates every key and would thundering-herd the research budget: roll out per topic (percentage/allowlist) and run under the capsule ceiling (section 6).
- Optional later: mark a topic stale when a new `NewsItem` cluster lands in a `NewsRun` slot.

### 2.7 Per-user novelty by selection

Scripts never see `previously_told`. Per-user continuity is selection: skip capsules already heard (same capsule or same lineage), serve the newer capsule on a topic with `is_update=true`, omit when nothing is new. Trade-off stated: the "yesterday we covered X" thread is lost (decision 3); `prev_capsule_id` gives the writer topic-level background only. "Heard" defined in 3.3.

## 3. Episode as a playlist

### 3.1 Structure

`Episode` stays (history, Home, feedback, search). It gets `episode_items`: `episode_id`, `position`, `kind` (`intro|capsule|transition`), `capsule_id`, `voice_key`, `audio_url`, `duration_s`, `voiced` (bool), `reason`, `in_budget`, `is_update`. **`Block` rows keep being written, one per capsule item that is voiced and attached**, with `request_id` = the caller's own request and a new `blocks.capsule_id`. This keeps feedback (`_resolve_subjects` by `Block.id`, signals per user request, `stop_topic` context), `told_log`, history and Home working unchanged. Feedback target stays `story` + Block id; a capsule id is never a target (it would 404 and lose request context). Blocks are not written for unvoiced items, which also fixes the told_log hole (3.4).

### 3.2 Ordering and budget (Phase 3)

Order: user priority (new `requests.priority`), then `FeedbackSignal.score` (useful minus not_quite; `stop_topic>0` excludes), updates first, never-heard first. Greedy fill until `max_length_minutes` (5/10/15/20): `intro + capsules + transitions <= budget`. Capsules that do not fit are not truncated; they appear as "More for later" (`in_budget=false`), voiced on tap. Honest regression to flag: with 5 min only 1-2 capsules fit, where today every topic is trimmed into the episode; "More for later" must be prominent in the UI.

### 3.3 "Heard"

Until iOS reports playback, "heard" = voiced and delivered in a published playlist (today's told_log semantics). Phase 3 adds `POST /capsules/{id}/heard` (completion >= 80%) and `capsule_heard` rows only for items with `voiced=true`.

### 3.4 Publishing and old-client contract (partial episodes)

Hard rules, because `search.py` says ready iff `audio_url` and `told_log` trusts published Blocks:
- The **job stays `voicing`** until the concatenated file exists. `Episode.published_at` and `audio_url` are set once, together, when the file is built; `audio_url` is never rewritten after publish.
- Partial state is exposed only through the **playlist endpoint** (new clients), including for a job that is not yet published (owner-checked). Old clients keep seeing `making` until the file exists.
- The concatenated file contains the voiced items present at build time; `Block.start_s/end_s` are computed from **real audio durations** (from ElevenLabs alignment end or an mp3 duration probe), not the 150 wpm estimate. Concatenating mp3 frames with encoder padding drifts slightly; verified only by a manual smoke test (section 10).
- Items that fail terminally are omitted from the file; they are retried by the re-voice path (3.5) and appear in the playlist later, but never mutate the published file. A late-arriving item is visible only to new clients.
- One-off requests are marked `fulfilled` only when their item is voiced and attached (today it happens at assemble, before voicing).

### 3.5 Who re-voices failed items (bounded)

The generalised `_revoice_failed_job`: on the next `POST /run`, scheduler tick or playlist poll, an item with `attempts < 3` and past its backoff is retried; cost is counted. After the cap it stays `failed` and is shown as unavailable.

### 3.6 Shared shelves

`generate_shared_episode`, `Episode.shared`, `InventoryItem`, `_latest_shared_by_tag` stay on the **v1 path** through Phase 2. Mapping them to capsules (a shared episode = a curated playlist of shared capsules) is a later optimisation, not a dependency.

## 4. Intro and transitions (Phase 2b)

**Intro**: "Good morning, {name}." (20-60 chars, ~$0.004-0.011). Cached by (normalised name, language, voice_key, daypart). The file is `intro_clips` customer data: random uuid filename (never derived from the name; `/media` is a static, unauthenticated mount), deleted on account deletion and included in export. Failure: skip the intro.

**Transitions**: `transition_clips` keyed `(language, voice_key, from_category|*, to_category|*)`, 2-3 text variants rotated. Resolution: exact pair, then wildcard, then neutral, then none. Bounded: 12 categories, so 144 pairs x 2 voices x 1-2 languages x ~60 chars at $0.18/1k is about $3-6 if everything were generated once; in practice eager neutral + `(to,*)` clips (~40, under $1), pairs lazily on first use, hard row cap, content-addressed by text hash. Wording is category-level only ("Switching to sports").

**Prosody rules in the writing prompt** (capsule bodies neutral at both ends): start with the fact, no greeting/"welcome", no "as we said"; no "now/next/moving on/finally/that's all", no questions to the listener, no teasers; end on a complete declarative sentence, no sign-off; plain punctuation, no ellipses or parentheticals; numbers/names written as spoken. A post-write validator (deny-list, ends with `.`) allows one rewrite; failing capsules are not shared. ElevenLabs request stitching is **unverified**; neutral bodies plus transitions do not rely on it.

## 5. Voice variants

- **Allowlisted `voice_key`** (config: `valentina`, `andres` mapping to ElevenLabs ids, ids TBD), stored in a new validated `profiles.voice_key`. `Profile.voice_id` stays untouched (client-settable free text, not trusted for the shared path). Null/unknown maps to a defined default `voice_key` (today null resolves to `_default_voice_id()` at synthesis; the migration/resolver must pin that default explicitly). Per-language voice allowlist is a founder question.
- Voicing is lazy per (capsule, voice_key) with the same claim/attempts/stale logic as capsules (a `capsule_audio` claim), so two simultaneous listeners pay once.
- `POST /capsules/{id}/voice` is a platform-paid action: it requires the capsule to be in the caller's own playlist, the voice in the allowlist, a per-user daily rate limit (suggest 20), the kill switch and the capsule ceiling; otherwise any user could trigger platform spend.
- Cost: a capsule's total is research + write + voicing x voices actually used.

## 6. Cost model and budget attribution

Inputs (README routing section, `ai_platform.py`): one researched+written block measured at **$0.1106**; research (Sonnet, ~50K input tokens, plus the $0.01/search surcharge, up to ~$0.03 with 3 searches) is ~99% of it; writing (Haiku, ~2K in / <500 out) is **~$0.001, not $0.02** (rev 1 was ~20x off). Voice: README measured **$0.142/audio-minute** (Starter tier, $0.117 on Scale); the code constant is **$0.18 per 1k chars (~$0.16/min)**. A 2-3 min capsule costs **$0.28-0.49 to voice** per first listener per voice. The $0.58 episode in a generator comment predates routing. Consequence: **writing once saves almost nothing; all the saving is voice, which is ~99% of per-listener marginal cost. Capsules win only if script AND voice audio are reused.**

Per listener, per topic, per day (2-min capsule: voice $0.32 at the code rate, text $0.111):

| Followers | Today (research shared in the 6 h window, write + voice per listener) | Capsule, one voice | Capsule, both voices used |
|---|---|---|---|
| 1 | $0.43 | $0.43 | $0.43 (second voice only on demand) |
| 10 | $0.33 ($0.011 + $0.001 + $0.32) | $0.043 | $0.075 |
| 100 | $0.32 | $0.0043 | $0.0075 |
| Bespoke long tail | $0.43 | $0.43 (no gain, no regression) | $0.43 |

Caveats: "today" is a best case (needs all followers inside one research window); capsules are longer than today's ~45 s blocks, so absolute spend per capsule rises (content-driven length and the hard cap are the control); out-of-budget capsules are voiced lazily so unplayed capsules cost text only.

### Attribution and ceilings (fixes the sentinel hole)

Reusing the news sentinel (`None`/`UUID(0)`) would exempt capsules from the per-customer budget, the global budget and the news ceiling, leaving only the kill switch: unbounded spend. Instead:
- A **distinct capsule sentinel** (`CAPSULE_SENTINEL = UUID(int=1)`) and a **dedicated global UTC-day `CAPSULE_DAILY_COST_CEILING_USD`**, enforced **inside `guard_paid_call`** with its own branch (kill switch + capsule ceiling). Capsule spend still counts toward the global daily budget.
- The ceiling is computed from a **committed ledger**: `capsules.cost + capsule_audio.cost` summed over the UTC day, not from `AICall` (AICall rows roll back on failure, hiding spend). Mirror the news fixes: cost accumulated additively per attempt, recorded on the failure path, hard per-day cap, row committed in its own short transaction.
- `AICall.context` for capsule calls carries `source=capsule`, `capsule_id`, and `audio_id`.
- **Bespoke** capsules (owner set) are charged to the owner through the normal `guard_paid_call` with the real `customer_id`, and also recorded in the capsule ledger.
- **Per paid step, not up front**: today `run_generation` calls `guard_paid_call("generation_precheck")`, so a budget-blocked customer cannot even assemble from cached capsules. In Phase 2 the capsule path checks per paid step; assembling from ready cached capsules makes no paid call and must succeed for a blocked customer (acceptance test). A blocked paid step marks that item `blocked` (codes `budget_exceeded`/`ai_paused`), not the whole job failed.
- Founder questions: ceiling value and who bears hot-topic spikes (section 11).

## 7. API and iOS impact

All additive; the shipped iOS build keeps working.
- `GET /generation/episodes/{id}`: unchanged shape. `audio_url` and `blocks[]` keep their meaning (concatenated file, Block offsets). New optional `playlist_version` (1/2) and `items`. `Episode.style` stays meaningful (set to the capsule `style_id`); note `Profile.narration_style` is **ignored for capsules** in the pilot (one style).
- `GET /generation/jobs/{id}/playlist` (and by episode id): owner-checked items `{position, kind, capsule_id, title, category, audio_url|null, duration_s, state (ready|voicing|pending|blocked|failed), voiced, in_budget, is_update, sources}`; works before publish.
- `GET /capsules/{id}`: script, sources, capsule-relative `word_timestamps`; authorised as in 2.5; no `researched_from`.
- `POST /capsules/{id}/voice`: rules in section 5.
- `GET /home`: banner states unchanged (`making` until the file exists); optional `items_ready/items_total` for new clients. `JobOut` gets no new enum value.
- Feedback: unchanged, by Block id.

iOS (Juanfe):
- The current `AudioPlayerService` queue is not enough: one `AVPlayer`, item swap on `DidPlayToEndTime`, no preload, not gapless. Needs `AVQueuePlayer` with prefetched next items. MP3 encoder padding prevents truly gapless joins, so transitions do real masking work.
- Per-capsule resume position (local first), lock-screen Now Playing per item, capsule-relative transcript timestamps (no `start_s` offset math), per-item states ("tap to hear"), "Play all" vs "pick one". Feature-flag on `playlist_version`.
- **A device test of queue joins is a GATE** for 1b; fallback is the concatenated file for "play all".
- Needs UI decisions: priority controls, voice picker, prominent "More for later".

## 8. Failure isolation and execution model

Capsule/item is the unit of failure; the episode is a best-effort assembly. One failed item never fails the job; the job fails only if zero items succeed (`empty` if all empty, keeping the existing retry rule). Budget/kill-switch blocks are item-level `blocked`.

**Execution model (honest)**: there is no queue, and the scheduler runs generation inline on a shared `AsyncSession` that is not concurrency-safe.
- **Phase 1 is sequential and synchronous**, in the same session, exactly like today but with per-item try/except and per-item commit.
- Parallel research or background voicing (Phase 2) requires: separate sessions per task (session factory), a named task owner (an in-process worker started in the lifespan, or a Railway worker later), claim rows with heartbeat, and stale-claim reclaim, because a Railway redeploy kills in-flight tasks. Until that exists, Phase 2 sharing is still correct (claims are DB-based) but latency is sequential.
- Time-to-first-audio: highest-priority item first; new clients start on the first voiced item via the playlist; old clients wait for the file.

## 9. Data model and migration plan

New tables (`create_all`): `capsules`, `capsule_audio`, `episode_items`, `transition_clips`, `intro_clips`, `capsule_heard` (Phase 3). Each is added to `conftest._FULL_SESSION_TABLES` and, where it holds customer data (`episode_items` via the episode, `intro_clips`, `capsule_heard`), to `account.py`'s explicit deletion and export (there is no `ON DELETE CASCADE` reliance there). Capsule audio and shared capsules contain no customer data.

Columns on existing tables for `COLUMNAS_ESPERADAS`, each added **in the phase that uses it**:
- `("blocks", "capsule_id", "UUID")` and `("episodes", "playlist_version", "INTEGER DEFAULT 1")`: Phase 1a.
- `("profiles", "voice_key", "VARCHAR(30)")`: with the voice picker (Phase 2b/3).
- `("requests", "priority", "INTEGER")`: Phase 3.
New tables need no `COLUMNAS_ESPERADAS`; `INDICES_ESPERADOS` only for an index on an existing table (none planned). Old episodes keep `playlist_version=1`; no backfill.

**Storage**: capsule mp3 ~1 MB/min at 128 kbps **(unverified)**, so ~2 MB per voiced capsule per voice. Phase 1 stores per-item audio **and** the concatenated file (double): retention = per-item files for an episode are kept for 14 days then deleted if the concatenated file exists and no new client references them; capsule audio referenced by any history episode is kept, unreferenced stale capsule audio deleted after 14 days (text kept). Size the Railway `/data/media` volume before Phase 1 ships.

## 10. Phased rollout and tests

Tests run only in GitHub Actions (`backend-tests.yml`). Every phase also needs the cross-cutting tests in the list below.

**1a: backend per-item voicing, failure isolation, concatenated-file compatibility, told_log fix (no iOS change).** Sequential, per-item voicing/commit, Blocks only for voiced items, real durations for offsets, job stays `voicing` until file exists. Value is *not* cost (Phase 1 does not reduce it): it is failure isolation (a single TTS failure fails the whole job today), time-to-first-audio, and listener control. Acceptance: failing item 2 of 3 yields an episode with items 1 and 3; `EpisodeOut` existing fields unchanged (golden JSON); told_log ignores unvoiced items; `search.py` and Home banner state correct while an episode is partial.
**1b: iOS queue behind `playlist_version`.** `AVQueuePlayer`, prefetch, resume, Now Playing. Gate: device gapless test.
**2a: shared capsules (sharing core).** Claim key flow, single-flight with polling and stale reclaim, novelty check, listener-independent writing prompt without `raw_text`/`scope`, lazy per-voice audio with default voice, platform sentinel, **capsule ceiling inside `guard_paid_call`**, **attempts cap + backoff**, **retire action**, per-step guard, authorised reads. Per-customer feature flag with shadow mode. Acceptance: two users on one topic cause exactly one research+write and one voicing; 10 concurrent first requests produce one capsule; a budget-blocked customer plays ready capsules; ceiling hit stops new capsule spend; a failed key stops after 3 attempts.
**2b: intro and transition library, prosody validator, voice picker + `profiles.voice_key`.** Acceptance: neutral start/end validator passes >= 95% on 50 real capsules; missing transition falls back to none; manual listening review of 20 joins.
**3: selection.** `requests.priority`, `FeedbackSignal` ordering, time-budget fill, "More for later", `capsule_heard` and `POST /capsules/{id}/heard`, "only what's new".
**Later**: embeddings (Voyage) with high threshold and exact-key authority; multiple styles; news-slot invalidation; map shared shelves to capsules; retire the concatenated file.

Test list (all phases as they apply): migration test against a DB created **without** the new columns (conftest uses only `create_all`); told_log with partially voiced episodes; cost ceiling and attribution through the **real** `guard_paid_call` (sentinel cannot bypass); crash plus stale-claim reclaim; fingerprint stability and novelty (same news does not create a new capsule); privacy (no name/`raw_text` in shared scripts, `researched_from` never serialised); capsule read authorisation; feedback through Block id of a capsule item; account deletion and export of every new table; voice endpoint ownership/allowlist/rate limit; length (words per capsule metric, thin-topic acceptance test on real topics); **manual smoke test** (not automatable): real mp3 concatenation, `word_timestamps` offsets and real ElevenLabs durations (the README says live timestamp verification is still outstanding).

## 11. Risks and open questions (recommendation each)

Founder questions:
1. **Who bears hot-topic cost spikes, and what is the capsule ceiling?** Recommendation: platform pays shared capsules under a dedicated daily ceiling; start at a number equal to ~(expected shared capsules/day x $0.45) with a 2x headroom, reviewed weekly. The founders set the value.
2. **"Update" labelling and "heard" definition before iOS reports playback.** Recommendation: "heard" = delivered in a published playlist until Phase 3; label "update" only when the novelty check says the capsule truly differs.
3. **Per-language voices in the 2-voice allowlist.** Recommendation: one allowlist entry per (language, voice_key); es first, en later; do not share audio across languages.
4. **Dropping `depth`/`scope`/`raw_text` from the shared path** reduces personalisation of shared content. Recommendation: accept in the pilot; bespoke capsules remain for private niche questions.
5. **Time-budget regression** (5 min = 1-2 capsules). Recommendation: prominent "More for later", measure completion.

Engineering risks:
6. Length: today's blocks are ~100-140 words; research has `max_uses 3`, `max_tokens 4096` incl. thinking and JSON, findings are "a few plain sentences", so 300-450 words often exceeds what findings support. Recommendation: keep the hard cap, let thin topics be short, add a words-per-capsule metric and an acceptance test on real topics.
7. Free-form questions rarely share until embeddings. Recommendation: ship, measure hit rate per topic (`capsule_cache_hit`).
8. Embedding false hits later. Recommendation: conservative threshold, shadow-log near misses, exact key stays authoritative.
9. Gapless playback (7). Recommendation: device gate, concatenated fallback.
10. Prompt version bumps cause thundering herd (2.6). Recommendation: per-topic rollout under the ceiling.
11. Prosody joins are subjective. Recommendation: listening review, transitions as safety net.
12. Multiple styles multiply capsules. Recommendation: at most 2 styles initially, voice only what is selected.
13. Execution model (section 8) is the biggest unbuilt dependency for parallelism. Recommendation: ship Phase 1 and 2a sequentially; decide a worker (in-process vs Railway worker) before optimising latency.
14. Shared wrong content reaches many users. Recommendation: retire action in 2a, `sources` and licences stored as today.

Not verified in this pass: iOS behaviour beyond reading code; production data volumes; mp3 bitrate; ElevenLabs request stitching; real audio durations vs estimates; the exact per-search surcharge in production. All cost figures are estimates from README and code constants, not measurements.
