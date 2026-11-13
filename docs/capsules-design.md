# Capsules: design document (rev 3, per-person capsules)

Status: proposal for founder review. Author: software architect. Design only, no production code.
Baseline read: `origin/main` (da0c772), `origin/fix/combined-review` (PR #65 state) and `origin/feat/ai-budget`. Anything marked **(unverified)** was not confirmed from the repository.
Rev 3 reflects the founders' change: capsules are per person; cross-user reuse exists only for discovery (news items voiced on tap).

## 1. Problem, goals, decisions

Today one request yields one monolithic episode per listener: sequential research (shared via `findings_store`), `write_block`, `_synthesize_episode` (voices each block, byte-joins into one mp3, sets `Episode.audio_url`). One TTS failure fails the whole job; the listener cannot choose or reorder topics.

Decisions (final, not re-opened):
1. **A capsule is one topic block of that user's own episode**: written and voiced for that user at their own delivery time. No script or audio is shared between users to assemble episodes. Research stays shared through the findings store (about 99% of a block's cost).
2. **The only cross-user reuse is discovery**: a **news item** (listener-independent text) voiced lazily on tap, once per (news item, voice), cached and served to everyone who taps it.
3. News items link to the **related capsule** in the user's own episode (by `cluster_id` / `topic_key`) with a Listen button; otherwise Listen voices the news item (discovery).
4. Kept: play-all and pick/prioritise capsules; short personal intro (greeting + name only); transitions between capsules; 2 voices synthesised lazily; ONE writing style in the pilot; content-driven length (ceiling 2-3 min, no padding, no minimum).

What this means honestly: **episode audio costs the same per user as today.** The efficiency is the existing shared research plus (new) bounded discovery voicing. The value of capsules is control, resilience and the news-to-audio link, not a voice saving.

## 2. Current state (facts the design depends on)

- `episode_generator.run_generation`: inline on one `AsyncSession` (no queue; the scheduler calls it inline), sequential research then write then voice, trigger at T-60 before delivery in the profile timezone (`scheduler`). Voicing failure fails the whole job (`_synthesize_episode`); `published_at`/`audio_url` are set only after audio exists (PR #43). `trim_factor` truncates scripts by words to honour `max_length_minutes`. `run_generation` calls `guard_paid_call("generation_precheck")` up front (feat/ai-budget).
- `Block`: `start_s/end_s` estimated at 150 wpm, `word_timestamps` block-relative. `told_log` treats any non-`no_news` Block of a published episode as told. `search.py`: `state = ready iff audio_url`.
- `findings_store`: key (topic, scope, geography) normalised; TTL 6 h fresh, 45 min empty. `research_topic` puts the user's `raw_text` in the prompt, so the first requester's phrasing shapes the shared entry (existing issue, flagged in section 8). **Observation (unverified impact):** the news pipeline researches with scope `"latest news"` and no geography (`news_pipeline.run_news_for_topic`), so its findings key differs from an episode request's key and the two do not share research today.
- News (`models/news.py`, `news_pipeline`): `NewsItem` per `topic_key` with `category`, `cluster_id`, `body`, `short_version`, `sources`; written with no customer (`customer_id` None/UUID(0)); `NewsRun` has `MAX_ATTEMPTS=3`, `STALE_RUNNING` 30 min, committed cost per run; own daily ceiling. Feed API `GET /api/news` (`NewsItemOut`: id, topic_key, category, title, summary, short_version, body, sources, published_at, cluster_id, read, ...), `GET /api/news/{id}`.
- ai-budget: `guard_paid_call` treats `customer_id` None or `UUID(0)` as a news caller (kill switch only). `AICall` rows roll back on failure.
- Feedback: `story` targets resolve by `Block.id`, request taken from `Block.request_id`; signals per user per request. `account.py` deletes customer data explicitly; `conftest._FULL_SESSION_TABLES` lists truncated tables.
- iOS: `PlayerViewModel` plays one file and seeks to `block.startS`. `AudioPlayerService` has `play(queue:)` but with one `AVPlayer` and item swap on `DidPlayToEndTime` (no preload, not gapless). No server-side playback position.
- `Profile.voice_id` is client-settable free text; null resolves to `_default_voice_id()` at synthesis.

## 3. The capsule (per person)

A capsule is a **per-user, per-episode item**: it is the existing `Block` generalised and given its own audio. No new shared cache of scripts.

- Keep `Block` as the capsule record (so feedback by Block id, `told_log`, history, Home all keep working). Add `blocks.audio_url`, `blocks.duration_s` (real), `blocks.audio_status` (`pending|voiced|failed|blocked`), `blocks.voice_key`. `word_timestamps` becomes meaningful per block file (capsule-relative, as today it is block-relative).
- Continuity stays exactly as today: `told_log.recent_for_request` feeds `previously_told` into `write_block`, since the capsule is for this user. The writing prompt is the existing per-listener one with: one pilot style, content-driven length (hard cap about 450 words, no padding), and the prosody rules in 5.
- `depth` (brief/standard/deep) is replaced by the content-driven cap plus the user's time budget (founder question 4); `Profile.narration_style` is ignored in the pilot (one style); `Episode.style` still records the style used.

### 3.1 Research freshness at delivery

Research for an episode starts at about T-60 and the findings TTL is 6 h, so today an episode can rest on research up to about 7 h old at the moment the listener hears it. New rule:
- `MAX_RESEARCH_AGE_AT_DELIVERY` (recommended **3 h**, tunable). When assembling a capsule, `findings_store.lookup` is called with a `max_age` that is the stricter of the TTL and `delivery_time - MAX_RESEARCH_AGE_AT_DELIVERY` (i.e. the findings must have been researched no earlier than that instant).
- If the shared findings are older than that: **re-research** (and write through, which refreshes the entry for everyone after). Never serve older findings silently; the empty TTL (45 min) is unchanged.
- Cost effect: users whose delivery times fall within one 3 h window still share one research call; spread-out delivery times share less than the 6 h TTL implies. Quantified in section 7.
- On-demand episodes: delivery is now, so the same rule means findings at most 3 h old.
- Fallback if re-research fails or is blocked: use the older findings only if younger than the 6 h TTL and mark the capsule `as_of` accordingly (new `blocks.research_as_of`), so the UI can show "as of 06:10"; otherwise the capsule is omitted (failure isolation, section 6).

## 4. Episode as a playlist

`Episode` stays. New `episode_items` (`episode_id`, `position`, `kind` intro|capsule|transition, `block_id`, `audio_url`, `duration_s`, `voiced`, `in_budget`, `reason`) describes order; capsule items point at the user's `Block`. Intro and transition items point at library clips (Phase 3).

**Ordering and budget (Phase 3):** user priority (new `requests.priority`), then `FeedbackSignal.score` (useful minus not_quite; `stop_topic>0` excludes). Greedy fill within `max_length_minutes` (5/10/15/20): intro + capsules + transitions. Capsules that do not fit are not truncated: they appear as **"More for later"** (`in_budget=false`), written and voiced lazily on tap. Honest regression to flag: with 5 min only 1-2 capsules fit, where today every topic is trimmed into the episode; "More for later" must be prominent. Because capsules are per user, items outside the budget cost at most research (shared) and writing (about $0.001) until the user taps.

### 4.1 Publishing and old-client contract (partial episodes)
- The job stays `voicing` until the concatenated file exists. `published_at` and `audio_url` are set once, together, when the file is built; never rewritten after publish.
- Partial state is exposed only through the playlist endpoint (works pre-publish, owner-checked); old clients see `making` until the file exists, so `search.py` and Home banner semantics are unchanged.
- Blocks (and `episode_items`) exist as voiced only for items whose audio exists; `told_log` and the future "heard" logic filter on `audio_status=voiced`, which fixes the partial-voicing hole.
- `Block.start_s/end_s` in the concatenated file come from **real audio durations** (ElevenLabs alignment end or an mp3 probe), not 150 wpm. mp3 frame concatenation may drift slightly; verified only by a manual smoke test.
- Failed items are omitted from the file and retried by the bounded re-voice path (3 attempts, backoff, cost counted); late items are visible only to new clients via the playlist.
- One-off requests are marked `fulfilled` only when their item is voiced and attached (today: at assemble, before voicing).

## 5. Intro, transitions, prosody (Phase 3)

- **Intro**: "Good morning, {name}." Personal, short (about 20-60 chars, $0.004-0.011). Cached by (normalised name, language, voice_key, daypart). It is customer data: random uuid filename (never derived from the name; `/media` is a static, unauthenticated mount), deleted on account deletion, included in export. Failure: skip.
- **Transitions**: pre-voiced `transition_clips` keyed `(language, voice_key, from_category|*, to_category|*)` over the 12 news categories; 2-3 rotating text variants; resolution exact pair, wildcard, neutral, none. Bounded: the full matrix of 144 pairs x 2 voices x 1-2 languages x ~60 chars at $0.18/1k is about $3-6 if ever fully generated; in practice eager neutral and `(to,*)` clips (~40, under $1), pairs lazily, hard row cap, content-addressed by text hash. Category-level wording only.
- **Prosody rules in the capsule writing prompt** (bodies neutral at both ends so joins work, and so single capsules play well alone): start with the fact; no greeting or "welcome"; no "as we said"; no "now/next/moving on/finally/that's all"; no questions or teasers; end on a complete declarative sentence, no sign-off; no ellipses, parentheticals or all-caps; numbers and names written as spoken. A post-write validator (deny-list, ends with `.`) allows one rewrite; a failing capsule is still delivered without validation claims rather than dropped. ElevenLabs request stitching is **unverified** and not relied on. Capsules still say nothing personal; the name appears only in the intro.

## 6. Failure isolation and execution model

- The capsule is the unit of failure. A failed item is `failed`/`blocked`, retried boundedly; the episode is `ready` when the file is built from the voiced items; the job fails only if zero items succeed (`empty` if all no-news, existing retry rule kept). Per-customer budget (`guard_paid_call`) applies to capsules exactly as today (the up-front precheck stays valid because nothing is served from other users' capsules); a mid-episode `BudgetExceededError` marks the remaining items `blocked` with the stable code instead of failing the job.
- **Phase 1 stays sequential and synchronous** in the same session, with per-item try/except and per-item commit. Background voicing or parallel research is **not** assumed: it needs separate sessions per task, a named task owner, heartbeat and stale-claim reclaim (a Railway redeploy kills in-flight tasks). Decide a worker before optimising latency.
- Time-to-first-audio: highest-priority item first; new clients start on the first voiced item via the playlist; old clients wait for the file.

## 7. Cost model (honest)

Inputs (README routing section, code constants): one researched+written block $0.1106; research (Sonnet, about 50K input tokens, plus a $0.01/search surcharge, up to about $0.03) is about 99% of it; writing (Haiku) is about $0.001. Voice: README measured $0.142/audio-minute (Starter; $0.117 Scale); code constant $0.18/1k chars (about $0.16/min). A 2-3 min capsule costs **$0.28-0.49 to voice per listener**.

**Episodes**: each user's capsule is voiced for that user, so voice cost per episode equals today's per-user voicing for the same audio length. What changes: (a) capsules are 2-3 min vs about 45 s blocks today, so spend per topic rises if capsules really reach that length (the content-driven cap is the control; thin topics stay short); (b) the budget fill (Phase 3) can cut spend by not voicing "More for later" items until tapped; (c) research sharing is unchanged but now bounded by the freshness rule.

Per listener per topic (2-min capsule, voice $0.32, research $0.11, write $0.001):

| Followers (within one 3 h research window) | Research per listener | Write + voice | Episode capsule total |
|---|---|---|---|
| 1 | $0.11 | $0.32 | $0.43 |
| 10 | $0.011 | $0.32 | $0.33 |
| 100 | $0.0011 | $0.32 | $0.32 |

If delivery times spread over 6 h, two research windows apply: roughly double the research column (still small). Voice is about 99% of marginal cost and does **not** amortise for episodes. That is the accepted trade for personal, fresh capsules.

**Discovery voicing** (news item voiced on tap, per (item, voice)): cost = voice of the item's `body`/`short_version` only (a 150-word body is about $0.16, 60 words about $0.06), paid once per item per voice and zero if nobody taps; it amortises across every tapper. It is bounded by taps, rate limits and a daily ceiling (section 8). Research/writing for news is already paid by the news pipeline and its own ceiling.

## 8. Discovery: news item to audio, and the news to capsule link

### 8.1 Link rules
For a news item shown in Home/feed:
1. If the user has a **published episode today** (or the current in-progress one) with a capsule whose request `topic_key` equals the item's `topic_key`, or whose news cluster matches (`cluster_id`; the capsule records the `topic_key`/`cluster_id` of the findings it used, new `blocks.topic_key`, `blocks.cluster_id`), the item carries `related_capsule: {episode_id, block_id}`; its Listen button plays **that capsule** (position in the user's queue).
2. Otherwise Listen plays the **news item audio** (discovery).
This realises backlog T-306 (episode and news link) in both directions: the news detail can say "In today's episode" and the capsule can link to its news items.
Matching is by normalised `topic_key` first, `cluster_id` as a secondary hint; a miss falls to discovery rather than guessing.

### 8.2 Discovery audio
- `news_item_audio` (news_item_id, voice_key, `audio_url` random uuid filename, real `duration_s`, `word_timestamps`, `chars`, `cost`, `status`, `attempts`, heartbeat). Unique (news_item_id, voice_key). Text is the item's own listener-independent text: **no user data in the shared path**: `news_pipeline` calls research with a synthetic prompt ("Latest news about {topic}"), `customer_id` None, and writes no customer reference. Spoken text = `title` plus `short_version`/`body` as stored; no greeting, no name.
- **Single-flight, only here**: many users tapping one item at once. First tapper claims the (item, voice) row, synthesises, commits `voiced`. Others poll the claim row (timeout about 60 s) and are told `voicing` (client polls). Stale claim (heartbeat older than 30 min, e.g. redeploy) is re-claimable consuming an attempt; `attempts <= 3` with 45 min backoff, as `NewsRun`. A crash or block for one tapper is not inherited: another tap re-evaluates against the guards.
- **Guards** (any user can trigger platform-paid voicing by tapping): ownership is not needed (news is public to followers/explorers), but:
  - **voice allowlist** (`valentina`, `andres` config; ids TBD);
  - **per-user rate limit** on *new* voicings (suggest 20/day; playing an already-voiced item is unlimited and free);
  - item age limit (only items from the last N days, suggest 3, can be voiced);
  - **daily global voicing ceiling** for discovery, with a **distinct sentinel** (`DISCOVERY_SENTINEL = UUID(int=2)`, not the news sentinel, which would bypass budgets) and its own branch in `guard_paid_call` (kill switch + discovery ceiling), computed from a committed ledger (`news_item_audio.cost`, committed even on failure since `AICall` rows roll back on failure), additive cost per attempt, hard per-UTC-day cap; `AICall.context` tagged `source=discovery`, `news_item_id`;
  - the per-customer budget is not charged (platform cost), which is exactly why the ceiling and rate limit exist.
- **Privacy**: confirmed no user data: the voiced text is the stored `NewsItem`; no `raw_text`, no `researched_from`, no names. A test asserts this.

## 9. API and iOS impact

All additive; the shipped iOS build keeps working.
- `GET /generation/episodes/{id}`: unchanged shape; new optional `playlist_version` (1 old, 2 new), optional `items`. `audio_url` and `blocks[]` keep meaning (concatenated file, Block offsets). New optional per-block fields: `audio_url`, `duration_s`, `audio_status`, `research_as_of`.
- `GET /generation/jobs/{id}/playlist` (and by episode id, owner-checked, usable before publish): items `{position, kind, block_id, title, category, topic_key, audio_url|null, duration_s, state (ready|voicing|pending|blocked|failed), voiced, in_budget, as_of}`.
- `POST /generation/blocks/{id}/voice`: voice a not-yet-voiced capsule (e.g. "More for later"); owner-only, per-customer budget.
- News: `NewsItemOut` gains optional `related_capsule {episode_id, block_id}` and optional `audio {state, audio_url, duration_s}` (null until voiced). New `POST /news/{id}/audio?voice=...` (idempotent; 202 with state while voicing, 200 with `audio_url` when ready); guards in 8.2. `GET /news/{id}/audio` for status polling. Backward compatible: old clients ignore the new fields.
- Home: banner states unchanged (`making` until the file exists); optional `items_ready/items_total` for new clients; Home/feed discovery fill uses `GET /news?scope=all`.
- Feedback unchanged (`story` + Block id; capsule feedback keeps request context for `stop_topic`). Feedback on a discovery news item uses the existing `news` target.
- `Profile.voice_key` (validated allowlist, separate from client-settable `voice_id`; null/unknown maps to a pinned default; today null resolves to `_default_voice_id()` at synthesis).

**What Juanfe must build**
1. **Queue player** (1b): replace the single-`AVPlayer` item swap with `AVQueuePlayer` and prefetched next items; MP3 encoder padding prevents truly gapless joins, so transitions (Phase 3) do real masking work. A **device gapless test is a gate**; fallback is the concatenated file for "play all".
2. Per-capsule resume (local first), lock-screen Now Playing per item, capsule-relative transcript timestamps (no `start_s` offset math), per-item states, "Play all" vs "pick one", reorder/prioritise UI, prominent "More for later". Feature-flag on `playlist_version`.
3. News list/detail: **Listen** button on each news item. If `related_capsule` is set, enqueue/jump to that capsule; otherwise call `POST /news/{id}/audio`, show `voicing`, poll, then play the item audio. "Read first, listen later" stays: reading does not trigger voicing.
4. Voice picker (2 voices) and handling of 429 (rate limit) and `ai_paused`/ceiling states ("audio unavailable right now").

## 10. Data model and migration plan (only what each phase needs)

New tables via `create_all`: `episode_items` (1a), `news_item_audio` (2), `transition_clips`, `intro_clips` (3). Each goes into `conftest._FULL_SESSION_TABLES` and, if it holds customer data (`episode_items` through the episode, `intro_clips`), into `account.py`'s explicit deletion and export. `news_item_audio` and `transition_clips` hold no customer data.

Columns on existing tables, for `app/db/migraciones.py` `COLUMNAS_ESPERADAS`, added in the phase that uses them:
- 1a: `("blocks","audio_url","VARCHAR(1000)")`, `("blocks","duration_s","INTEGER")`, `("blocks","audio_status","VARCHAR(20)")`, `("episodes","playlist_version","INTEGER DEFAULT 1")`.
- 2: `("blocks","topic_key","VARCHAR(300)")`, `("blocks","cluster_id","UUID")`, `("blocks","research_as_of","TIMESTAMPTZ")`; `("profiles","voice_key","VARCHAR(30)")` with the voice picker.
- 3: `("requests","priority","INTEGER")`.
`INDICES_ESPERADOS` only for an index on an existing table (an index on `blocks (topic_key)` for the link lookup, Phase 2). Old episodes keep `playlist_version=1`; no backfill.

**Storage**: mp3 about 1 MB/min at 128 kbps (unverified), so about 2 MB per voiced capsule per user. Phase 1 stores per-item audio **and** the concatenated file (double). Retention: per-item files deleted 14 days after publish once the concatenated file exists and no new client references them; discovery audio kept while the news item is within the feed window (about 30 days). Size the Railway `/data/media` volume before Phase 1 ships.

## 11. Phased rollout and tests (tests run only in GitHub Actions, `backend-tests.yml`)

**1a: backend per-capsule voicing, failure isolation, concatenated-file compatibility, told_log partial-voicing fix. No iOS change; does not cut cost.** Value: a single TTS failure no longer fails the job, groundwork for time-to-first-audio and control. Includes the research-age rule (3.1) as it touches only `findings_store.lookup`/generator. Acceptance: item 2 of 3 failing yields an episode with 1 and 3; existing `EpisodeOut` fields unchanged (golden JSON); told_log ignores unvoiced items; `search.py` and Home banner state correct for a partial episode; Block offsets match real audio; findings older than the max age trigger re-research.
**1b: iOS queue** behind `playlist_version`, `AVQueuePlayer` with prefetch, resume, Now Playing. Gate: device gapless test.
**2: news to capsule link, Listen on news items, discovery voicing, Home/feed fill.** Acceptance: related capsule resolved by `topic_key`/`cluster_id`, none gives discovery; 10 concurrent taps on one item produce one voicing; second tap is free; rate limit, allowlist and item-age limit enforced; daily discovery ceiling stops new voicing and returns a clear state; killed winner recovered by stale-claim after 30 min; attempts cap at 3.
**3: intro + transitions library, priority ordering from feedback signals, "More for later" under a time budget.** Acceptance: 5-min budget yields only fitting capsules, none truncated, rest voiced on tap; missing transition falls back to none; prosody validator passes at least 95% on 50 real capsules; manual listening review of 20 joins.
**Later:** multiple writing styles; embeddings/semantic matching (they would matter for discovery matching and linking free-form capsules to news clusters); aligning episode research key with news research key (see section 2, unverified); shared shelves (`generate_shared_episode`, `Episode.shared`, `InventoryItem`) stay on the v1 path.

Test list (as each phase applies): migration test against a DB created **without** the new columns (conftest only uses `create_all`); told_log partial voicing; per-customer budget on capsules through the real `guard_paid_call`; discovery ceiling/attribution through the real `guard_paid_call` (sentinel must not bypass news or customer limits); crash plus stale-claim; concurrency of taps; privacy (no name/`raw_text`/user text in news audio; `researched_from` never serialised); link resolution; feedback via capsule Block id; account deletion/export of new tables; `search.py`/Home state for partial episodes; research-age boundary (just inside/outside the max age); words-per-capsule metric on real topics; **manual smoke test**: real mp3 concatenation, `word_timestamps` offsets, real ElevenLabs durations (README says live timestamp verification is still outstanding).

## 12. Risks and open questions (with recommendations)

Founder questions:
1. **Max research age at delivery** (recommend 3 h) and what to show when only older findings exist (recommend omit the capsule rather than show stale, or label "as of").
2. **Discovery daily voicing ceiling and per-user rate limit values.** Recommend ceiling about $15/day at pilot scale (about 100 item voicings at $0.15), 20 new voicings per user per day; founders set the number.
3. **Capsule length vs cost**: 2-3 min capsules cost $0.28-0.49 voice per listener per topic, 2-3x today's blocks. Recommend content-driven length with the 450-word cap and a words-per-capsule metric before committing to the budget.
4. **`depth` setting and `narration_style` are ignored in the pilot.** Recommend: time budget replaces depth; keep style choice for the later multi-style phase.
5. **"Heard" and update labelling**: with per-user capsules continuity stays `told_log` (published and voiced items). Recommend no new "heard" table until iOS reports playback.
6. **Per-language voices in the 2-voice allowlist.** Recommend one entry per (language, voice_key).
7. **Time-budget regression** (5 min = 1-2 capsules). Recommend prominent "More for later".

Engineering risks:
8. Research key mismatch between news and episodes (unverified): potential duplicated research spend. Recommend measuring hit rate and aligning keys later.
9. Gapless playback: device gate, concatenated fallback.
10. Execution model (section 6) is the biggest unbuilt dependency for parallelism; ship sequential first.
11. Existing issue: episode research puts the user's `raw_text` in the shared findings prompt, so one user's phrasing can shape a shared entry. Recommend a separate hardening ticket (not part of capsules).
12. Discovery abuse: tapping spam can spend platform money. Mitigated by rate limit, age limit, ceiling and kill switch.
13. Storage growth (per-user capsules plus the double storage in Phase 1). Recommend retention above and volume sizing.

Not verified in this pass: iOS behaviour beyond reading code; production volumes; mp3 bitrate; ElevenLabs request stitching; real audio durations; the per-search surcharge in production; `search.py`, `ai_platform.py` and `home.py` were re-read from main only. Cost figures are estimates from README and code constants, not measurements.
