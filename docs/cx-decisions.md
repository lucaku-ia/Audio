# Audio capsules: CX decisions for the founders

Status: recommendations for founder approval. Author: CX / product research. No code changes.
Inputs: `docs/capsules-design.md` rev 3 (branch `docs/capsules-design`), `lucaku-audio-screens.md`, README, `docs/TASKS.md` (branch `docs/tasks-backlog`).
Convention: **[H]** = hypothesis (a starting value to validate in the pilot, not a fact). Evidence is cited only where it was actually found; the rest is judgement and says so.

## Decision table

| # | Question | Recommended decision | Confidence | Founder approval |
|---|---|---|---|---|
| 1 | Max research age at delivery | Per category: markets/sports 3 h, politics/world/Colombia/tech 6 h, evergreen 24 h; label "as of HH:MM" if older than 3 h; omit rather than serve stale | Med | Yes (cost vs freshness) |
| 2 | Discovery ceiling and per-user limit | ~50-user pilot: $10/day ceiling, 10 new voicings/user/day; max 3 discovery items per Home day-group, labelled "Because you follow X" or "Popular today"; pull only | Med | Yes (money) |
| 3 | Capsule length and 5-min regression | Length by topic type (45-90 s quick, 90-150 s standard, up to 180 s explainers), 3 min hard ceiling; default budget 10 min; "More for later" is a first-class list with durations | Med | Yes (cost, default budget) |
| 4 | Drop depth and narration style | Drop both; remove the copy that promises them; collect demand with feedback chips and a "noted" tap | High | No |
| 5 | "Heard" and telemetry | Heard = played >= 80% (or >= 30 s); skipped (<10 s) = not told; 6 minimal iOS events; implicit signals weak, never destructive | High | No |
| 6 | Two voices | One female + one male, neutral Latin American (Colombian-leaning), warm and clear; blind audition with 6-8 users | Med | Yes (brand) |
| 7 | Intro and transitions | Intro <= 6 s, transition <= 2.5 s, 6+ variants with no immediate repeat, name only in intro, no-name fallback | High | No |
| 8 | Audio language vs English UI | Keep English UI for the pilot; ask audio language explicitly in onboarding (default Spanish for Spanish-region devices); decide on Spanish UI from pilot evidence | Med | Yes (scope) |
| 9 | Day zero and metrics | First capsule playable in ~4 min [H]; ask for notifications after first listen; metric set with hypothesis ranges in section 9 | Med | No (targets are hypotheses) |
| 10 | Pilot research | 8-12 interviews + 14-day in-app diary; Spanish script in section 10 | High | No |

## Decisions that really need a founder call (max 6)

1. Discovery spend: $10/day ceiling and 10 new voicings/user/day (money).
2. Per-category research age 3 h / 6 h / 24 h, and omit-when-stale (cost vs freshness).
3. Default time budget 10 min and the 3 min capsule ceiling (cost vs attention).
4. The two voices and their personas (brand).
5. Audio language default (Spanish) and English-only UI for the pilot (scope, audience fit).
6. Removing the depth/style promises from sign-in and onboarding copy (low cost, but it changes the approved screen copy).

---

## Evidence note (read first)

Web search found little directly usable benchmark data for audio news briefings.
- Daily-news-roundup podcast completion of about 62% is quoted by an aggregator blog attributing it to Chartable (https://www.voxbooster.com/blog/podcast-completion-rate-statistics-2026). **Weak**: secondary source, no methodology. Use only as "completion in the 50-70% range is plausible", never as a target.
- Average US audio listening is about 4 h/day (Edison Research, https://www.edisonresearch.com/americans-spend-over-four-hours-daily-with-audio/). Says nothing about briefings.
- Reuters Institute Digital News Report 2026, Colombia: 35% get news weekly from creators/influencers, about 9% weekly from AI chatbots (https://reutersinstitute.politics.ox.ac.uk/digital-news-report/2026/colombia). Suggests the audience is used to informal, personality-led news; informs tone only, not length.
- Nothing usable was found for NPR One, Apple News+ audio, Particle, Artifact, 1440, Axios, Morning Brew or NotebookLM skip rates or length norms. Statements below about "category practice" (short daily briefs, headline-first style) are professional judgement, not cited figures. The pilot is the real evidence source.

---

## 1. Max research age at delivery

**Recommendation.** One config map instead of a single 3 h:

| Category group | Max age at delivery | Rationale |
|---|---|---|
| Economy and business, Sports | 3 h | Listeners compare with their phone; a stale price or score destroys trust |
| Politics, World, Colombia and your city, Technology and AI | 6 h | Stories move but rarely reverse within hours; morning listeners expect "overnight" news |
| Science, Health, Climate, Culture, Lifestyle, Personal finance | 24 h | Evergreen; re-researching is wasted money |

**Why.** Research is about 1% of capsule cost (voice is about 99%), so freshness is cheap where it matters; 3 h everywhere mostly spends money on categories that do not need it. Unknown or unmapped category defaults to 3 h.

**Labelling.** If findings are older than 3 h at delivery, show "As of {time}" in the UI. Do not read it in audio for fresh items.

**Stale fallback.** If re-research fails and only older findings exist: omit the capsule and show "Nothing new on X" on Home. Never read stale news as current. Evergreen categories may fall back with "As of yesterday".

**Risks.** Config surface; a mis-categorised story gets the wrong age.

**Measure.** Re-research rate by category; capsules omitted for staleness; feedback reason "outdated" (add as a chip, section 4).

**Safe default.** 3 h for everything, as in the design. Costs slightly more, never wrong.

## 2. Discovery: ceiling, per-user limit, surfacing

**Assumptions.** Pilot of 30-100 users (about 50 at start). A voicing costs about $0.06-0.16, paid once per (item, voice) and shared by every tapper.

**Recommended values.**
- Global ceiling **$10/day** at about 50 users (about 60-170 voicings). Rule of thumb: ceiling = users x $0.20/day, min $5, max $15 until real data exists. It is a safety net; expected spend is much lower because taps concentrate on few items and cache hits are free.
- Per-user **10 new voicings/day** (not 20). Replaying a voiced item is free and unlimited. Honest use rarely reaches 10; abuse exposure halves. Config value, review after week 1.
- At the per-user limit: "You've explored a lot today. More tomorrow." At the global ceiling: "Audio for this story isn't available right now" plus Read. Never a technical error.
- Item age limit 3 days, as designed.

**Surfacing (no Discover tab, per the spec).**
- Discovery is the **Listen button on news rows** (speaker icon plus duration). Pull only: no autoplay, no push, no separate shelf in the pilot.
- Items on followed topics: no label (Listen plays the related capsule). Items outside the user's topics: small secondary label **"Because you follow {Topic}"** when a real tie exists (category or cluster), otherwise **"Popular today"**. Never invent a reason.
- Cap: at most **3 non-followed items per day-group** and no more than 1 in 4 rows. Followed topics are not capped.
- Never put discovery audio in the episode playlist or "Play all" in the pilot.
- After a discovery listen the usual Useful / Not quite appears; on Useful offer a quiet "Follow {topic}".

**Risks.** Labels overselling relevance; discovery cannibalising the daily-episode habit (watch listen-through).

**Measure.** Discovery tap rate (3-10% [H]); voicings and $ per day vs ceiling; cache-hit rate; share of users hitting the limit (under 2% [H]); "Follow" conversions.

**Safe default.** $10/day, 10 per user, 3 per day-group, labels as above.

## 3. Capsule length, cost and the 5-minute regression

**Principle.** Length is content-driven with a ceiling; never padded. Voice is about $0.16/min, so each minute per capsule costs the platform per listener ($0.28-0.49 for 2-3 min). Attention points the same way: a briefing is a habit product.

**Length by topic type** (about 150 wpm; [H], confirm with the words-per-capsule metric):

| Topic type | Target | Ceiling | Examples |
|---|---|---|---|
| Quick update (one fact or number changed) | 45-75 s | 90 s | prices, match results, exchange rate |
| Standard news | 90-150 s | 3 min | politics, Colombia, world, tech |
| Explainer / evergreen | 120-180 s | 3 min | science, health, climate, personal finance |
| Nothing new | omit | | never padded |

Hard ceiling stays 3 min (about 450 words). Most capsules should land at 60-120 s. A standard 100 s capsule is about $0.27 voice; a 5-topic, 10 min episode is about $1.6/user/day: use that as the cost frame.

**The 5-minute regression.** Make it feel like a feature:
- **Honest copy where the choice is made**: "5 min fits about 2-3 short topics. The rest wait in More for later." Show the consequence, do not hide it.
- **Default budget 10 min** pre-selected in onboarding (options 5 / 10 / 15 / "As long as it needs" stay). Founder call.
- **Ordering**: user priority, then feedback score (design Phase 3). Make it visible: a drag handle in Interests labelled "Most important first".
- **More for later** sits directly under the player queue: title, duration, play icon; tap voices on demand ("Preparing...") and appends to the queue. Home badge: "3 more topics for later, 6 min". Never truncate a capsule to fit.
- **End-of-episode prompt**: "Want to keep going? 3 more topics, 6 min" with Play. Prefetch the first "More for later" item during the last capsule to hide voicing latency.
- Allow a 15% overrun when the next capsule just misses the budget.

**Risks.** Silent-drop perception (mitigated by visible counts); on-demand latency.

**Measure.** Seconds per capsule by category; share at ceiling; "More for later" tap rate; completion by length bucket; $/episode/user; share of 5-min users who move to 10+ within 14 days (high means 5 is a poor option or default).

**Safe default.** 3 min ceiling, content-driven, default 10 min, More for later visible under the queue.

## 4. Dropping depth and narration style

**What users lose.** Depth (brief/standard/deep) and style (Straight news / Story / Conversational, screen 2.10). Also the sign-in promise "Short or in depth, you decide... Plain or with the numbers, calm or upbeat".

**Copy fix (important).** In the pilot, those promises must not appear or users are promised controls that do nothing. Sign-in card: "Short on time? Pick your episode length. It learns from what you rate." Remove the style picker from 2.10 (keep voice).

**What to tell users.** One line in onboarding and Profile: "Lucaku picks the right length for each topic. Tell us when you want more or less." Do not say "coming soon" for style; say "We're testing one style first".

**Demand signals (near-zero build).**
- After Useful / Not quite, optional chips: "Too short", "Too long", "Too basic", "Too technical", "Outdated", "Sounds off".
- A one-tap "Want more on this?" per capsule logs `more_detail_requested` per topic. Copy: "Noted. We're learning what to go deeper on." Do not promise delivery.
- Profile row "Suggest a style" (three options or free text) logs `style_request`.
- Interview and diary questions in section 10.

**Risks.** Users who valued control may be disappointed; "more detail" read as a promise.

**Measure.** Too short / Too long share (investigate if over 15% [H]); `more_detail_requested` by topic; style requests; interview mentions.

**Safe default.** Drop both, remove promising copy, collect chips.

## 5. "Heard" and playback telemetry

**Definition for continuity** (`told_log`): **heard** = played at least 80% of the capsule, or at least 30 s when the capsule is longer than 40 s. **Skipped** = left within 10 s of start. Anything in between is **partial**. Heard and partial count as told (facts were exposed); skipped counts as not told so the story can return if there is news. Until iOS reports playback, keep the design fallback (told_log on published and voiced) and accept over-counting.

**Minimum iOS events,** each with `capsule_id` (block id), `episode_id`, `source` (episode | more_for_later | discovery), `position_ms`, `duration_ms`, `ts`:
1. `capsule_play_start`
2. `capsule_progress` once each at 25 / 50 / 80%
3. `capsule_complete`
4. `capsule_skip` (with `position_ms`; under 10 s is the early-skip flag)
5. `capsule_seek` (direction, amount)
6. `episode_play_start`, `episode_end`, `episode_abandon`, `playlist_pick` (manual choice); `speed_change` if the player has it.

**Feeding feedback signals.**
- Explicit Useful / Not quite always wins over implicit.
- Complete = weak positive (about a quarter of a Useful); early skip = weak negative (about a quarter of a Not quite). Weight skips on position 1 at half (mood, not topic).
- Two early skips on the same topic within 7 days triggers a "Pause this topic?" prompt, never an automatic `stop_topic`.
- Priority ordering (Phase 3) uses explicit score first; implicit only as tie-break, and only after 2 weeks of data.

**Risks.** Skips caused by context (bus arrived); autoplay counted as heard while the user was elsewhere. Hence weak weights, nothing destructive.

**Measure.** Listen-through per capsule; early-skip rate by category and position; agreement between implicit and explicit (if low, drop implicit use).

**Safe default.** 80% / 30 s rule; skipped = not told; implicit logged but not used for ranking at first.

## 6. Voices

**Choosing the two.** One female and one male, same register: warm, clear, calm, mid pace; **neutral Latin American Spanish, Colombian-leaning intelligibility** (no strong regional markers such as Argentine voseo, Mexican slang, Caribbean s-dropping). Neutral Bogota/Medellin speech is widely accepted for news in Colombia, but this is judgement: verify in the audition. Avoid hyper-energetic podcast voices, over-precise robotic voices and whispery voices (tiring at 10 min, poor in noise). The spec's Valentina ("warm, calm female") and Andres ("clear, steady male") match the persona; the open question is whether the actual ElevenLabs voices do.

**Per-language voices.** Allowlist keyed (language, voice_key) as the design recommends. Spanish voices for Spanish text, English voices for English text; never a Spanish voice reading English. Keep persona names across languages where practical.

**Audition protocol (5-8 users, about 45 min).**
1. Pre-select 4 candidates (2 female, 2 male) with identical settings and pace.
2. Same three clips per voice: a 20 s markets headline, a 90 s standard capsule (Colombian politics), and an intro with a name. Include hard names (Petro, Maria Fernanda, an English company name such as Nvidia).
3. Blind, randomised order, test on headphones and phone speaker. After each clip, 1-5 ratings: clarity, trustworthiness, pleasantness, "would listen daily at 6 am", "sounds like a real person"; one open comment "what bothered you?".
4. Forced choice: top two overall and "which would you not want daily?". Ask whether gender preference changes by topic.
5. Include 1-2 listeners from outside Bogota (Cali, Medellin, Barranquilla) for accent acceptance.
6. Decision rule: two voices with best median "would listen daily" and no more than one clarity rating below 3; ties broken by name pronunciation. Check artifacts (breaths, clipping).

**Risks.** n=6 is directional; preference is personal (mitigated because users pick between two); ElevenLabs library changes, so pin voice ids.

**Measure.** Voice selection split; voice switching in first 2 weeks (over 15% [H] means defaults are wrong); "Sounds off" by voice; listen-through by voice.

**Safe default.** Valentina and Andres if both pass a 3-person sanity audition; otherwise the two best from the protocol.

## 7. Intro and transitions

**Tone.** Warm, neutral Latin American Spanish, tuteo, calm, no hype, no exclamations, no regionalisms. English: simple and friendly. Colombian audiences are used to informal creator-led news (Reuters 2026), but a morning briefing wants calm.

**Length.** Intro <= 6 s (best 3-8 words, at most about 14). Transition <= 2.5 s (3-6 words). Capsule bodies still start with the fact (design).

**Variation.** 6 intro variants per daypart; 6-8 transition variants per family. Never the same intro variant two episodes in a row; never the same transition twice in one episode; seeded rotation so it is testable. Optionally a different pool on weekends. Clips are pre-voiced and cached, so variety costs cents.

**Name and greeting rules.**
- Greeting by the user's local time at **delivery** (clips are cached): 05:00-11:59 "Buenos dias", 12:00-18:59 "Buenas tardes", 19:00-04:59 "Buenas noches". English: morning / afternoon / evening.
- Name: first given name as entered; treat as unknown if it looks like an email, has digits or emoji, or exceeds 20 characters.
- Unknown name: greeting only ("Buenos dias."). Never "Hola, usuario"; never guess from the email.
- Onboarding should ask "How should we call you?" since legal and used names differ. Listen to early intros for mispronounced names and fix manually; a phonetic field is post-pilot.
- No weather, date, "welcome back" or questions in the intro (design: greeting and name only).

**10 intro lines, neutral Latin American Spanish** (accents omitted here for file simplicity; production text must carry them).
1. Buenos dias, {name}.
2. Buenos dias, {name}. Esto es lo de hoy.
3. Hola, {name}. Buenos dias.
4. Buenos dias, {name}. Vamos con lo importante.
5. Buenas tardes, {name}.
6. Buenas tardes, {name}. Esto es lo que paso hoy.
7. Hola, {name}. Buenas tardes.
8. Buenas noches, {name}.
9. Buenas noches, {name}. Un repaso del dia.
10. Buenos dias. (no name)

**10 intro lines, English.**
1. Good morning, {name}.
2. Good morning, {name}. Here's your day.
3. Hi {name}, good morning.
4. Good morning, {name}. Let's start with what matters.
5. Good afternoon, {name}.
6. Good afternoon, {name}. Here's what happened today.
7. Hi {name}, good afternoon.
8. Good evening, {name}.
9. Good evening, {name}. Here's your day in review.
10. Good morning. (no name)

**10 transitions, Spanish** (use sparingly; some pairs get none).
1. Siguiente tema.
2. Pasamos a {category}.
3. Ahora, economia.
4. En deportes.
5. Y en tecnologia.
6. Cambiamos de tema.
7. Seguimos.
8. Del mundo, ahora a Colombia.
9. Algo mas.
10. Un tema mas.

**10 transitions, English.**
1. Next topic.
2. On to {category}.
3. Now, business.
4. In sports.
5. And in tech.
6. Changing topic.
7. Moving on.
8. From the world to Colombia.
9. One more.
10. Another topic.

Transitions are separate clips, so the design's prosody ban on "now/next/moving on" applies to capsule bodies only. Avoid "finally" and "por ultimo" in clips since order changes. Category-level wording only.

**Risks.** Chatty intros become skip-fodder; robotic repetition; mispronounced names (highest-emotion error). A missing transition clip falls back to none, which is acceptable.

**Measure.** Early skip in the first 10 s of the episode (intro skip); "Sounds off" reports; diary item "did anything sound robotic?".

**Safe default.** Spanish tuteo, 6 variants, name only in intro, unknown name means greeting only.

## 8. Audio language vs English-only UI

**Situation.** UI is English-only (TASKS.md global rule 7), the audience is mostly Spanish-speaking in Colombia, and audio language comes from onboarding. Risks: Spanish listeners misconfigure; language choice is invisible; the voice must match language; English category names and chips create friction for users typing Spanish interests.

**Recommendation.**
1. **Keep the UI in English for the pilot** (scope control, deliberate rule) and say so in recruitment ("the app is in English, the audio is in Spanish"). This is a limiting assumption: it may select a different audience than the target; record it.
2. **Ask audio language explicitly, early, bilingual**: two large buttons "Audio en Espanol / Audio in English", shown once, pre-selected from device region.
3. Show **language plus voice** together on the Your Lucaku summary (2.11) and in Profile: "Audio: Espanol, Valentina".
4. Free-text topics accept Spanish; the label stays in the user's language ("Millonarios"), categories stay English chips. If interviews show confusion, Spanish category labels (12 words) are the cheapest first localisation, before a full Spanish UI.
5. Capsule titles, headlines and news summaries follow the **audio language**, even inside the English UI. A mixed state is the right pilot compromise.
6. Post-pilot trigger: if over 30% [H] of interviewees stumble on English text, or onboarding drop-off concentrates on English steps, prioritise a Spanish UI.

**Risks.** English UI may depress activation; mixed languages feel unfinished.

**Measure.** Onboarding completion by device language; language switches in Profile; feedback and interviews about language.

**Safe default.** English UI, Spanish audio pre-selected for Spanish-region devices, explicit question in onboarding.

## 9. Onboarding, day zero and pilot metrics

**Day zero should feel like:** "I said what I care about and within minutes I heard something real about it", not "I filled a form and must wait until tomorrow".

Flow (builds on screens 2.x and 3.10):
1. Onboarding as designed (about 1 minute). After "Start my Lucaku" generate the first episode **now**, not at the delivery time.
2. **First capsule playable as soon as voiced** (design). Card 3.10 shows live steps and a count "1 of 4 ready". Target first audio under about 4 minutes [H]; measure the real figure.
3. Put the user's first-named, most specific topic first.
4. After the first listen, one line on Home: "Your next episode will be ready tomorrow at 7:00 AM." Ask for notification permission **after** the first successful listen, not at signup.
5. Keep day-zero audio identical to normal audio; teach the feedback loop in the UI with a small tip: "Tap Useful or Not quite so it learns."
6. If research for a topic fails, omit it and say so ("We couldn't find fresh news on X yet"); never block the whole first episode (failures are per capsule).
7. Acknowledge the first Not quite visibly ("Got it. We'll adjust").

**Success metrics** (ranges are hypotheses to calibrate in the first 2 weeks, not targets from data):

| Metric | Definition | Initial range [H] |
|---|---|---|
| Activation | Completed onboarding and heard >= 1 capsule (80%) within 24 h of signup | 60-75% |
| Time-to-first-audio | "Start my Lucaku" to first `capsule_play_start` | median under 5 min, p90 under 10 min |
| D1 retention | Opened app or played audio on day 1 | 40-55% |
| D7 retention | Same on day 7 | 25-40% |
| Episode listen-through | Capsules heard / capsules in played episodes | 55-70% |
| Capsule early-skip rate | Skipped within 10 s / starts | under 15% |
| Capsule completion | complete / start | 55-70% |
| Discovery tap rate | Taps / discovery impressions | 3-10% |
| Feedback rate | Capsules with Useful or Not quite / played | 8-20% |
| Useful ratio | Useful / (Useful + Not quite) | over 70% |
| Habit | Users with 4+ listening days in week 2 | 25-35% |
| Cost | Platform $ per active user per day | under $2 |

With about 50 users one person is 2%: read cohorts and trends, not decimals. Segment by audio language, voice and time budget. Do not change anything on fewer than about 20 sessions of evidence.

**Risks.** A long first wait kills activation; asking too much at signup; over-reacting to tiny N.

## 10. Pilot research plan

**Design.** 8-12 interviews (30-40 min, Spanish, video) at day 2-3 of use; a **14-day diary** as an in-app micro-survey (2 taps plus optional comment); final 20 min calls with 5-6 diary participants. Recruit Spanish-speaking, Colombia-based users, mixed ages (18-24, 25-40, 40+) and interests (markets, sports, politics, culture), at least 2 outside Bogota, at least 3 who already listen to news podcasts or radio. Get recording consent; keep data within the product's privacy promise.

**Daily micro-survey** (max once per day, after an episode ends; under 15 s):
- Q1 (1 tap): "Como estuvo el episodio de hoy?" 1-5 faces. (Overall satisfaction, trend.)
- Q2 (1 tap, optional): "El largo fue...?" Muy corto / Justo / Muy largo. (Decision 3.)
- Q3 (optional text): "Algo que te molesto o te gusto hoy?" (All.)

**Interview guide (Spanish) with the decision each question informs.**

Context and habits (decisions 3, 9)
1. Cuentame como te enteras de las noticias en un dia normal. Que usas, a que hora, cuanto tiempo? (Baseline habit, delivery time.)
2. Cuando escuchas audio (podcast, radio), donde estas y que haces? (Context, length, noise.)
3. Cuanto tiempo quisieras dedicar a tu resumen diario? Que te parece largo? (Default budget, decision 3.)

First impressions (decisions 8, 9)
4. Cuentame que recuerdas de cuando empezaste a usar la app. Que fue lo primero que hiciste? (Day zero.)
5. Hubo algo en ingles que te costo entender o te hizo dudar? Que? (Decision 8.)
6. Que esperabas escuchar la primera vez y que escuchaste? Cuanto tardo? (Time-to-first-audio expectations.)
7. Elegiste el idioma del audio? Lo recuerdas? Cambiarias algo? (Decision 8.)

The audio (decisions 3, 4, 6, 7, 1)
8. Pon un episodio ahora y dime en voz alta lo que piensas. (Think-aloud; skip points.)
9. Que te parecio la voz? Te cansa, te gusta, suena a persona o a robot? Hombre o mujer? (Decision 6.)
10. Como te sono el saludo con tu nombre? Lo dijo bien? Te gusto o te molesto? (Decision 7.)
11. Notaste el aviso entre un tema y otro? Ayudo o estorbo? (Decision 7.)
12. Alguna nota te parecio muy corta, muy larga o repetida? Cual y por que? (Decision 3.)
13. Escuchaste algo que ya sabias o que sentiste viejo? (Decisions 1 and 5.)

Control (decisions 3, 4)
14. Hay algo que quisieras ajustar en como te cuentan las noticias? (Open; depth/style demand without suggesting.)
15. Entre "mas corto y rapido" y "mas detalle", que escogerias para cada uno de tus temas? (Depth demand by topic.)
16. Si no cabe todo en tu tiempo, prefieres que lo demas quede para despues o que se acorte todo? Muestra el diseno de "Mas para despues": se entiende? (5-min regression.)

Discovery (decision 2)
17. En la lista de noticias, tocaste el boton de escuchar en alguna? Por que si o no? (Tap behaviour.)
18. Te parece bien ver noticias de temas que no sigues? Cuantas serian demasiadas? Muestra "Porque sigues X" y "Popular hoy": cual entiendes mejor? (Frequency cap, labels.)
19. Que quedo claro y que no sobre cuando recibes tu episodio y por que a veces no estaba listo? (Status, trust.)

Value and habit (decision 9)
20. Si manana dejara de existir, que extranarias? Que usarias en su lugar? (Value, substitutes.)
21. Que te haria abrirla todos los dias? Que te haria dejarla? (Retention drivers.)
22. Cuanto pagarias, si algo, y por que? (Light price signal; ask last, do not anchor.)

**Diary, day 7 and day 14 (in-app, Spanish).**
- "Cuantos dias esta semana escuchaste tu episodio?" 0-7 (habit).
- "Cuando lo escuchas normalmente?" Manana / Trabajo o estudio / Transporte / Noche / Otro (delivery time, context).
- "Que tan actualizadas te parecieron las noticias?" 1-5, y "alguna ya la sabias?" (decision 1).
- "Que tan acertados fueron tus temas?" 1-5, y "Falto algo?" (topics, discovery).
- "Que cambiarias de la voz?" Nada / Mas rapida / Mas lenta / Otra voz / Otro (decision 6).
- "Prefieres episodios..." mas cortos / como estan / mas largos (decision 3).
- "Te gustaria elegir la profundidad o el estilo?" No / Si, profundidad / Si, estilo / Ambos (decision 4).
- "Entendiste el texto de la app en ingles?" Todo / Casi todo / Poco (decision 8).
- "Del 0 al 10, recomendarias Lucaku a un amigo?" (Directional only at this N.)

**Analysis.** Tag every note with decision numbers; produce a one-page readout per decision (keep / change / need more data) within 3 days of the last interview. Combine with section 5 telemetry: trust observed behaviour for habits and the interviews for reasons.

**Schedule (3 weeks).** Week 0: recruit, voice audition (section 6). Week 1: first 4-5 interviews. Weeks 1-2: diary. Week 3: 4-6 more interviews at day 10-14, final calls, readout.

**Risks.** Friends-and-family bias; small N; translation drift (have a native speaker review the survey wording); recording consent and privacy.

**If time is short.** Run 8 interviews with questions 1, 3, 5, 8-13, 15-18, 20-21 plus the daily Q1-Q2.
