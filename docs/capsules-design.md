# Capsules: design document

Status: proposal for founder review. Author: software architect. Scope: design only, no production code.
Everything marked **(unverified)** could not be confirmed from the repository and needs a check before build.

## 1. Problem, goals, current state

Today one request produces one monolithic episode per listener. Research is shared (findings store), but writing and voicing are per listener, and the voiced blocks are byte-concatenated into one mp3 per episode.

Goals (founder decisions, not re-opened here):
- **Capsules**: one topic each, 2-3 min ceiling, content-driven length, so the listener can reorder, pick, or "play all".
- **One capsule serves many users**: write once, voice once per voice, serve everywhere.
- Everything is shareable when topic keys match; text normalisation only until embeddings exist.
- Two voices, lazily synthesised; one writing style in the pilot; personal bits live only in a short intro clip; pre-voiced transitions between capsules.

Current state (file references on `origin/main`, `da0c772`):
- `services/episode_generator.py::run_generation` loops requests: `ai_platform.research_topic` (cached via `findings_store`), then `write_block` (per listener, takes `style`, `language`, `depth`, `previously_told`), then `_synthesize_episode` voices each block and writes `b"".join(parts)` to `MEDIA_DIR/{episode.id}.mp3`. Only one `Episode.audio_url`.
- `models/episode.py`: `Block` has `start_s/end_s` (estimated from word count at 150 wpm, `_WORDS_PER_MINUTE`), `script`, `sources`, `word_timestamps` (relative to the block's own audio). `Block.request_id` ties a block to one listener's request.
- `findings_store`: key `(normalize(topic), normalize(scope), normalize(geography))`; TTL fresh 6 h, empty 45 min. `normalize` is casefold plus accent-fold only, deliberately conservative (a false hit is worse than a miss).
- `told_log.recent_for_request`: per-listener, per-request summaries from *published* episodes, fed into `write_block`. This is the main thing that makes scripts non-shareable.
- `max_length_minutes` trimming (`trim_factor`) truncates scripts by word count (cuts mid-thought). Capsule selection replaces it.
- Jobs: one `GenerationJob` per (customer, fecha, path); `empty`, retry, revoice (`_revoice_failed_job`) logic exists; a voicing failure fails the whole job.
- Home (`api/routes/home.py`) derives banner state from the job and returns `blocks` (`BlockSummaryOut`). `api/routes/generation.py` exposes `JobOut`, `EpisodeOut` (single `audio_url`, `blocks[]` with `word_timestamps`).
- News (`models/news.py`, `news_pipeline.py`): `NewsItem` per `topic_key` with `category` (12 values: local, politics, world, markets, personalFinance, technology, science, health, climate, sports, entertainment, lifestyle) and `cluster_id`. Already topic-keyed, never customer-keyed.
- Feedback (`origin/feat/feedback-signals`, not on main): `FeedbackSignal` per (customer, request|topic) with `useful`, `not_quite`, reason counters, `score`.
- iOS: `PlayerViewModel` plays one file and `seek`s to `block.startS`. `AudioPlayerService` already has `play(queue:[AudioQueueItem], startIndex:)` with manual `AVPlayerItem` swapping, so a queue primitive exists. There is no server-side playback position anywhere (stated in `home.py`).

## 2. The Capsule model

### 2.1 Identity and cache key

A capsule is an immutable, listener-independent piece of content:

```
capsule_key = (topic_key, scope_key, geography_key, language, style_id, prompt_version, findings_fingerprint)
```
- `topic/scope/geography_key` reuse `findings_store.normalize`, same conservative rule. Free-form questions share only if they normalise (or, later, embed) to the same key.
- `findings_fingerprint` = hash of the findings payload ids/urls/headlines used. It is the **freshness window**: same fingerprint means same content, so a capsule is reused for as long as the findings entry is live (6 h fresh, 45 min empty). A new research run with materially different findings creates a *new* capsule row; old ones stay (history needs them).
- `voice` is **not** part of the content key: it is a child (`capsule_audio`). `style_id` is constant in the pilot (one style), but is in the key so later styles do not require a migration.
- `depth` (brief/standard/deep) is **dropped from the key**: depth fragments sharing and conflicts with "content-driven length". Length preference becomes selection (section 4). Open question 5.

### 2.2 What is stored

`capsules`: id, key columns, `status` (`queued|researching|writing|ready|failed|empty`), `script`, `summary` (one line), `sources` (same JSON shape as `Block.sources`), `findings_cache_id`, `as_of` (research time), `valid_until`, `category`, `duration_est_s`, `had_more`, `cost` JSON {research, writing}, `prev_capsule_id` (topic-level lineage), error code.

`capsule_audio` (one row per capsule per voice): `capsule_id`, `voice_key` (`valentina|andres`), `eleven_voice_id`, `audio_url`, `duration_s` (real, from audio), `word_timestamps` (relative to capsule start), `chars`, `cost`, `status`.

Duration is real after voicing; the 150 wpm estimate is only used for selection before audio exists.

### 2.3 Lifecycle and invalidation

1. `get_or_create(key)`: lookup live capsule by (topic keys, language, style, prompt_version) whose `valid_until > now`; hit means no model calls.
2. Miss: research via `research_topic` (findings store still the research cache), write once (listener-independent prompt), persist `ready` (text) immediately. Voice is a separate step per voice.
3. `valid_until = as_of + FRESH_TTL` (6 h) for news, `+ EMPTY_TTL` (45 min) for no-news. A `no_news` result creates an `empty` capsule row (so concurrent requests do not each re-research) but is never playable, and expires fast, preserving the PR #31 empty-day correctness property.
4. **News changes during the day**: the next lookup after expiry re-researches; if the new findings fingerprint differs, a new capsule is created with `prev_capsule_id` set. Optional improvement (later): the news pipeline's 0500/1300 slots (`NewsRun`) mark a topic's capsule stale when a new `NewsItem` cluster lands, instead of waiting for TTL. Not needed in the pilot.
5. Concurrency: claim-by-unique-key (a `capsules_inflight` row or a unique partial index on key where status in queued/researching/writing), same approach as `NewsRun`'s claim. Without it, ten simultaneous listeners of a new topic pay ten times. This is the one place sharing can silently fail, so it is Phase 2 acceptance.
6. Never cache a parse failure (existing rule); a `failed` capsule is retried by the next requester, not served.

### 2.4 Listener-independent scripts, per-user novelty by selection

The writing prompt receives only the findings, language, the single style, and optionally the **topic-level** previous capsule summary (`prev_capsule_id`), never a listener's history. It must not contain greetings, sign-offs, "you", or the listener's phrasing (`raw_text` is no longer a writer input; it stays a research hint only in the key's first-creator `researched_from`). Scripts are self-contained: each capsule states enough context to stand alone, and leads with what is new.

Per-user continuity moves from rewriting to selection, using a new `capsule_heard` log (customer, capsule_id, topic_key, heard_at, completed):
- skip a capsule whose `findings_fingerprint` or topic lineage the user already heard (replaces `told_log` for capsules);
- if the user heard an older capsule on the topic and a newer one exists, serve the newer one and label it "update" in the playlist (`is_update=true`);
- if nothing new, omit it ("nothing new on X today" is a playlist-level note, not audio).

Trade-off, stated plainly: this loses the old "yesterday we covered the rate decision" narrative thread. We accept it (decision 3); the lineage line in the prompt recovers some of it at topic level.

"Heard" needs a signal. Until iOS reports playback (no server position exists today), "heard" = included in a published playlist, matching today's `told_log` semantics. Phase 3 adds `POST /capsules/{id}/heard`.

## 3. Episode as a playlist

`Episode` stays (history, Home, feedback targets all reference it). It becomes an ordered list of items:

`[intro] , capsule_1 , [transition] , capsule_2 , [transition] , ... , capsule_n`

New table `episode_items`: `episode_id`, `position`, `kind` (`intro|capsule|transition`), `capsule_id`, `voice_key`, `audio_ref` (resolved URL), `duration_s`, `reason` (`priority|signal|update|fill`), `is_update`, `playable` (bool). Existing `Block` rows are still written in Phase 1 (compat); in later phases they are derived views over capsule items.

**Ordering** (deterministic, explainable):
1. User-pinned order, if any (new nullable `requests.priority`, or a per-episode reorder the client PATCHes). The founder wants listener prioritisation (goal a), so this is required in Phase 3.
2. Then `FeedbackSignal.score` descending per topic (useful minus not_quite; `stop_topic > 0` excludes), ties by recency of the request.
3. Updates before repeats; never-heard before heard.

**Time budget**: `Profile.max_length_minutes` (5/10/15/20; null means no ceiling). Greedy fill in order: `intro + sum(capsule est + transition est) <= budget`. Capsules that do not fit are **not truncated**; they appear in the playlist with `playable=true, in_budget=false` under "More for later", voiced lazily on tap. This removes today's word-truncation (`trim_factor`) and the `had_more` hack. A capsule is never cut; a 3-min capsule in a 5-min budget simply means fewer capsules.

## 4. Intro and transitions

**Intro** (`kind=intro`): "Good morning, {name}." plus optional date/weather-free one-liner. Short (~20-60 chars, ~$0.004-0.011). Cached by (name_normalised, language, voice_key, daypart); the same user reuses it daily, so the marginal cost is about zero after the first day. Generated at episode assembly (name is known), never inside a capsule. Failure fallback: skip the intro (or text-only line in the UI).

**Transition library** (`transition_clips`): pre-voiced, keyed `(language, voice_key, from_category|*, to_category|*)` with text variants (2-3 per key, rotated to avoid repetition). Categories are the 12 in `news_pipeline.CATEGORIES`. Resolution order: exact pair, then `(from,*)` / `(*,to)`, then neutral, then **no transition** (the capsules already start/end neutral). Boundedness: the full pair matrix is 12x12=144 keys x 2 voices x 1-2 languages x ~10 words (60 chars, ~$0.011 each) is about $3-6 total if fully pre-generated once; realistically generate the 12 neutral + (to,*) clips eagerly (about 40 clips, under $1) and pairs lazily on first use, with a hard cap on the table. Library is content-addressed by text hash so a copy edit regenerates only that clip. Transitions never mention topics by name beyond category-level phrasing ("Switching to sports"), since the neighbouring capsule may differ per user.

**Prosody rules in the writing prompt** (so capsule bodies join cleanly): start in medias res with the fact, no greeting or "Welcome", no "as we said"; no "now / next / moving on / finally / that's all", no questions to the listener, no cliffhangers or teasers; end on a declarative, complete sentence, falling intonation, no sign-off; plain punctuation, no ellipses, no all-caps, no parenthetical asides (they synthesise unevenly); numbers and names written as spoken. Add a post-write validator (regex deny-list, ends with `.`) with one rewrite retry; a failing capsule is blocked from sharing rather than published. Whether ElevenLabs `eleven_multilingual_v2` request-stitching (previous/next text) can improve joins is **unverified**; not needed with neutral bodies plus transitions.

## 5. Voice variants

Two voices (Valentina/Andres placeholders; real ElevenLabs ids TBD, stored as config keyed by `voice_key`, not hardcoded in rows). `capsule_audio` is synthesised **lazily**: the first listener who needs voice V triggers it, with an in-flight claim (same idea as 2.3 step 5) so two simultaneous listeners do not both pay; later listeners hit the cache. Cost implication: worst case the first 2 listeners of a capsule each pay one voicing, then it is free. A capsule's total cost is `research + write + voicing x (voices actually used)`, so the second voice roughly doubles the cost of capsules that have listeners in both voices, but only after demand exists. `Profile.voice_id` maps to `voice_key` (migration: map unknown ids to a default; **unverified** what ids exist in production profiles). Language is part of the capsule key, so es and en do not share audio.

## 6. Cost model

Inputs. From `README.md` routing section and `episode_generator.py` comments: ElevenLabs about $0.18 per 1k characters; 150 wpm and ~6 chars/word gives about $0.16 per audio minute. Routed Claude cost per researched+written block about $0.11 (research on Sonnet is the bulk; I assume roughly $0.09 research and $0.02 writing, **unverified split**). The $0.43 research + $0.15 voicing = $0.58 one-request episode in the generator comment predates routing, so use it as the pre-routing reference, not the current run rate. Assume a 2-minute capsule (about 300 words, 1,800 chars): voicing about $0.32, text about $0.11, so about $0.43 for the first listener with one voice. Intro/transitions are at most a few cents per user per day and are omitted below.

Cost per listener, per topic, per day (one voice, 2-min capsule):

| Followers of the topic | Today (research shared inside the 6 h window, write+voice per listener) | Capsule model, one voice | Capsule model, 2 voices split 50/50 |
|---|---|---|---|
| 1 | $0.43 | $0.43 | $0.43 (only one voice is ever synthesised) |
| 10 | about $0.35 ($0.009 research + $0.02 write + $0.32 voice) | $0.043 | about $0.075 ($0.11 + 2 x $0.32 over 10) |
| 100 | about $0.34 | $0.0043 | about $0.0075 |
| Bespoke long tail (free-form, nobody else matches) | $0.43 | $0.43 (no regression, no gain) | $0.43 |

Caveats. (a) The "today" column assumes all followers hit the same 6 h research window; users spread across delivery times miss it, so today is at best this good. (b) Today's blocks are ~100-140 words (`_DEPTH_WORDS`), a 2-3 min capsule is 2-3x longer, so absolute spend per capsule is higher than per block today; the comparison above holds length constant. Longer capsules raise listener value but also total voice spend; the content-driven rule (no padding) is the cost control. (c) Capsules that are generated but never played cost text only if voicing is lazy for out-of-budget capsules (recommended, section 3). (d) The headline: voice is now the larger cost and today it does not amortise; capsules make it amortise, which is the real prize.

Budget attribution (`origin/feat/ai-budget`: `guard_paid_call`, per-customer daily budget, global budget, kill switch; news calls with `customer_id=None` or the zero-UUID sentinel are governed by `NEWS_DAILY_COST_CEILING_USD`, not the customer budget). Recommendation:
- Shared capsule creation is **platform cost**, attributed to a sentinel customer (like the news sentinel), counted in the global daily budget and visible in a per-day "capsule spend" metric, but **not** charged against the first requester's per-customer budget. Otherwise the unlucky first listener of a hot topic burns their budget for everyone, and a depleted budget would starve shared content.
- Bespoke capsules (key not matched by anyone else within the window; `capsule.owner_customer_id` set when the origin request was free-form and no other follower exists) are attributed to the requester via the existing `customer_id` in `AICall.context`. Rule: attribute to the requester at creation, then re-label as shared once a second user attaches, for reporting only (no refund).
- The kill switch must refuse capsule creation and lazy voicing equally. A budget-blocked customer can still **play** already-built shared capsules (no paid call), which is a feature; the generator must not treat "no new capsule" as "failed episode" (see section 8).
- Anchoring cost to `AICall.context` today uses a JSON `customer_id`; add `capsule_id` and `audio_id` there for per-capsule cost roll-ups. No new ledger.

## 7. API and iOS impact

All changes additive. Existing fields keep their meaning for the shipped iOS build.

- `GET /generation/episodes/{id}` (`EpisodeOut`): unchanged shape. Add optional `items: [PlaylistItemOut]`, `playlist_version: 2`. `audio_url` and `blocks[]` continue to be populated (Phase 1 and 2) by a server-built concatenated mp3 (byte-join of the cached per-item mp3s, same technique as today, cheap) so old clients keep working. Block offsets then still refer to the concatenated file. Retire when the old build is gone.
- New `GET /generation/episodes/{id}/playlist` returning items:
  `{position, kind, capsule_id, title (summary), category, topic_key, audio_url|null, duration_s, ready: bool, voiced: bool, in_budget, is_update, sources[], transcript_available}`. `audio_url` is per item; null while lazily unvoiced.
- `GET /capsules/{id}`: script, sources, `word_timestamps` (capsule-relative, so no offset math), `duration_s`.
- `POST /capsules/{id}/voice?voice=valentina`: triggers lazy voicing for a "tap to hear" item; returns 202 plus `audio_url` when ready; idempotent.
- `POST /capsules/{id}/heard` (Phase 3): completion telemetry.
- `GET /home`: banner states unchanged. Add to `blocks[]` items `capsule_id` optionally; add banner field `playable_now: bool` and `ready_items/total_items` so Home can show "3 of 5 ready" (section 8).
- `JobOut`: unchanged; add optional `items_ready`, `items_total`, and a `partial` status is NOT a new enum for old clients (they would not know it): keep `voicing` until the first item is playable then flip to `ready`. New per-item states live in the playlist endpoint only. This is the main backward-compat decision.
- Feedback: `target_type` stays `episode|story|news`; capsule feedback uses `story` with `target_id = capsule_id` (today it is a block id). Aggregation key remains topic, so signals still feed ordering. Check `feedback.py` mapping when Phase 3 lands (**unverified**: file is on `feat/feedback-signals`, not main).

iOS (for Juanfe, front-end owner):
- `PlayerViewModel` today equals one file plus `seek(to: block.startS)`. New mode: queue of per-item URLs through `AudioPlayerService.play(queue:startIndex:)`, which already swaps `AVPlayerItem`s on `DidPlayToEndTime`. "In this episode" list becomes the playlist; tap = `startIndex`; "Play all" = queue from index 0; "Pick one" = queue of one.
- Gapless: separate `AVPlayerItem`s are not guaranteed gapless; mitigation is preloading the next item and relying on transitions to mask joins. If gaps are audible in testing, fallback is the server concatenated file for "play all". Needs a device test (**unverified**).
- Resume position per capsule (local `UserDefaults` first, server later), transcript per capsule using capsule-relative `word_timestamps` (simpler than now: no `start_s` offset), per-item states (ready / voicing / "tap to generate voice").
- Time-to-first-audio: start playback at the first `ready` item; refresh the playlist while later items arrive (poll `GET .../playlist`).
- Feature-flag the new player behind `playlist_version` so one build supports both.
- Needs UI decisions: capsule priority controls and the voice selector (2 voices).

## 8. Failure isolation and partial episodes

Rule: **a capsule is the unit of failure; an episode is a best-effort assembly.**
- Each capsule has its own status and retry. Research/write/voice failure of capsule k marks that item `failed`, is retried by background job (existing `_run_with_escalation`), and does not touch the others. Today a single TTS failure fails the whole job and unpublishes the episode (`episode_generator.py` voicing `except` branch); that is replaced by per-item failure plus the existing "keep scripts, re-voice" principle (`_revoice_failed_job` generalises to "re-voice this item").
- Episode state: `ready` as soon as >= 1 voiced capsule is attached. `published_at` is stamped then (not at the end), still only when audio exists, preserving the told-log invariant for the items that exist. Missing items show `ready=false` in the playlist and fill in as they land (push/poll). If zero capsules ever succeed: `failed`/`empty` as today.
- `empty` day semantic is preserved: all capsules `empty` means job `empty`; the 45 min TTL still allows the retry path.
- Budget block/kill switch (`BudgetExceededError`, `AIKillSwitchError`) are not failures of other capsules: the episode may still be assembled from already-built shared capsules; only the missing paid steps are marked `blocked` (stable code `budget_exceeded`/`ai_paused`, already used by `_BLOCKED_CODES` on that branch).
- Time-to-first-audio: build order = highest priority first; research phase parallelised per capsule (today it is a sequential loop); voice item 1 immediately, rest in background. Cached capsules make the first item near-instant.
- Concurrency/idempotency carried over: unique (customer, fecha, path) job stays; add unique (episode_id, position).

## 9. Data model and migration plan

New tables, created by `create_all` (no `COLUMNAS_ESPERADAS` entry needed): `capsules`, `capsule_audio` (unique capsule_id+voice_key), `episode_items` (unique episode_id+position), `capsule_heard` (customer_id, capsule_id; unique), `transition_clips`, `intro_clips`. Indexes: capsules by (topic_key, scope_key, geography_key, language, valid_until); a partial unique index for in-flight claims. **Per `app/db/migraciones.py`, indexes on existing tables and any new unique/partial index need an `INDICES_ESPERADOS` entry only if they target existing tables; for new tables `create_all` creates them.**

Columns on existing tables to list in `COLUMNAS_ESPERADAS`:
- `("episodes", "playlist_version", "INTEGER DEFAULT 1")` (2 = capsule playlist)
- `("requests", "priority", "INTEGER")` (user ordering; nullable)
- `("profiles", "voice_key", "VARCHAR(30)")` (derives from `voice_id`, or reuse `voice_id` to hold the key; decide at build)
- `("blocks", "capsule_id", "UUID")` optional, only if Phase 1 keeps `Block` as the compat view.
Nothing else; `Episode.audio_url` stays as is.

Backfill: none. Old episodes keep `playlist_version=1` and behave as today. `FindingsCache` is untouched (research cache remains the first-level cache; capsule is the second-level cache of the written/voiced product).

Storage: capsule mp3 about 1 MB/min at 128 kbps **(unverified)**, so about 2 MB per voiced capsule on the Railway `/data/media` volume. History means capsules referenced by a published episode are kept; unreferenced stale capsules older than 14 days are deleted (audio only, text kept). Size the volume before Phase 2.

## 10. Phased rollout

**Phase 1: per-capsule audio, playlist API, iOS queue (still per user, no sharing).**
Backend: voice each block to its own file; add `episode_items` + playlist endpoint; keep the concatenated file for old clients; per-item failure isolation and first-audio-ready. iOS: queue player behind `playlist_version`.
Acceptance: a 3-topic episode returns 3 playable items; killing TTS for item 2 still yields an episode with items 1 and 3; old iOS build plays the concatenated file unchanged; word timestamps per item verified against audio.
Tests (pytest, run only in GitHub Actions `backend-tests.yml`): generator tests with a fake `synthesize` that fails for one item; contract tests that `EpisodeOut` existing fields are unchanged (golden JSON); playlist ordering test. iOS: unit test of queue advance plus manual device gapless check.

**Phase 2: shared capsules, listener-independent writing, intro and transition library.**
Backend: `capsules`/`capsule_audio`, key lookup, in-flight claim, new writing prompt (no `previously_told`, no `raw_text`), prosody validator, lazy per-voice synthesis, intro and transition tables, platform-cost attribution. Feature flag per customer (shadow mode first: generate both, compare).
Acceptance: two users following "premier league" within the window cause exactly one research+write call and one voicing per voice (assert on `AICall` counts); 10 concurrent first requests produce one capsule; a hit costs 0 USD; capsules pass the neutral-start/end validator at >=95% on a sample of 50; missing transition falls back to none without error; budget-blocked user still plays existing capsules.
Tests: concurrency test with asyncio gather over the claim; cost-attribution tests mirroring `test_ai_budget.py`; prompt snapshot/regex tests on a fixture set of findings; manual listening review of joins (not automatable).

**Phase 3: selection by signals and budget, "only what's new".**
Backend: ordering (priority, `FeedbackSignal`), time-budget fill, `capsule_heard`, "More for later" lazily voiced, `POST /capsules/{id}/heard`. iOS: priority UI, voice picker, update labels.
Acceptance: a 5-minute budget yields only capsules that fit, none truncated; a second episode the same day omits capsules already heard unless the fingerprint changed; `stop_topic` excludes a topic.
Tests: pure-function tests for selection (table-driven), told/heard edge cases (heard but not published), budget boundary cases.

**Later phases**: (4) embeddings (Voyage AI, account pending) to match free-form questions to existing capsules, with a high similarity threshold and an `exact` fallback so false hits stay rare; (5) multiple styles (Straight news/Story/Conversational) as additional `style_id` values, each fragmenting sharing, with the style fan-out rule below; (6) stale-on-news-slot invalidation; (7) retire the concatenated file once the old iOS build is gone.

## 11. Risks and open questions (with recommendation)

1. **Free-form questions rarely share until embeddings.** Expect long-tail cost like today for them. Recommendation: ship anyway, measure share rate per `topic_key` (event `capsule_cache_hit`), and encourage named topics in onboarding.
2. **False-hit risk once semantic matching lands.** A wrong capsule served is worse than a miss. Recommendation: conservative threshold, shadow-mode logging of near-misses before enabling, keep `exact` key path authoritative.
3. **Listener-independent writing loses personal continuity.** Recommendation: accept per decision 3; recover through topic-level lineage and "update" labelling; revisit if retention data says users miss it.
4. **Longer capsules (2-3 min vs ~45 s blocks today) raise absolute voice spend and may exceed what 3 web searches (`max_uses: 3`, 4096 max tokens) can support.** Recommendation: keep content-driven length with a hard cap (about 450 words) and let thin topics be short; revisit `max_uses`; track words per capsule.
5. **`depth` setting disappears from capsule writing.** Users who chose "brief"/"deep" lose that control. Recommendation: replace with the time budget now; if needed later add depth as a key component (costly for sharing) or two fixed lengths.
6. **Platform vs requester cost attribution** for shared capsules (section 6). Recommendation: shared capsules to the platform pool under the global budget, bespoke to the requester. Needs founder sign-off on who bears hot-topic spikes.
7. **Gapless playback with `AVPlayerItem` queue** is unverified. Recommendation: device test in Phase 1; keep the concatenated "play all" file as a fallback.
8. **Heard tracking without server playback position** (none exists). Recommendation: "delivered in a published playlist" in Phase 2, real completion telemetry in Phase 3; do not block on it.
9. **Voice ids and storage**: ElevenLabs ids still TBD; profiles may hold arbitrary `voice_id`. Recommendation: define `voice_key` config now, map unknown ids to a default; size the Railway volume for capsule history (policy in section 9).
10. **Prosody quality of neutral joins is subjective**; regexes do not guarantee good audio. Recommendation: a listening review of 20 joins before Phase 2 goes broad; transitions are the safety net.
11. **Multiple styles later** multiply capsule count per topic (styles x voices x languages). Recommendation: cap at 2 styles in the first iteration and only synthesise combinations someone selects; consider whether style should be a voicing-time option (SSML/tone) rather than a script change (**unverified** quality).
12. **Safety/legal on shared content**: every capsule stores `sources` with licenses, as `Block` does. A shared wrong capsule reaches many users, so corrections matter. Recommendation: an ops "retire capsule" action (mark `status=failed`, next lookup regenerates) in Phase 2.
13. **Legacy `Block`/`told_log` semantics diverge** during the mixed period (Phase 1-2). Recommendation: keep `told_log` for v1 episodes; do not mix the two for the same user on the same day.

Not verified in this pass: the iOS player behaviour beyond reading the code (no build/run); production data volumes; the $0.11 research/writing split; actual mp3 bitrate; ElevenLabs behaviour for request stitching; feedback API mapping (branch not merged). All numbers in section 6 are estimates from repo comments and README, not measured.
