# Backend session — 2026-11-11

Written while you were out. Everything below is pushed and waiting on merges.

---

## First: `main` was broken when you left

After the nine merges, **12 of 38 tests failed on `main`** with none of my new
code involved.

```
AttributeError: module 'app.services.ai_platform' has no attribute
'research_and_write_block'
```

PRs #31 and #36 were **each individually reported MERGEABLE**, git merged the
text with **zero conflicts**, and the break was purely semantic: #36 deleted a
function #31's tests patched by name. Neither PR's suite was ever run against
the other's merged result.

The runtime was never affected — only comments referenced the old name — but a
red suite everyone knows is red stops being a signal.

**That one is on me.** I flagged that those two PRs collided, told you to merge
#31 first and ping me for #36, and when you merged both I moved on instead of
checking the combined result. Fixed in **#42**.

---

## Merge order

Stacked, each on the one before. GitHub retargets as they land.

| # | What | Why it matters |
|---|---|---|
| **#42** | Test suite repair | `main` is red without it |
| **#43** | Voicing failures + connection pool | the "no audio" trio |
| **#45** | Findings store | the cache you asked for |
| **#46** | Timestamp correctness | the cache would never have expired |
| **#47** | Docs | — |
| **#48** | Re-voice failed jobs | **matters the moment you top up ElevenLabs** |
| **#49** | Episode continuity | the product half of the cache |
| **#50** | Docs | — |

**#44** (signup error messages) is independent — merge any time.
**#41** is superseded by #43: **close it.**

80 tests pass on the full stack.

---

## The two features you actually asked for

### Shared research, bespoke episodes (#45)

> "if 2 people are researching for same thing, then the info is there and no
> need to research again" — "I don't want the same podcast for everyone. never."

Both hold. The cache stores **findings — facts**, never a script and never
audio. Two customers on the same topic pay for that research once between them
and still get two different episodes. A hit costs **zero**, not less.

Keyed on `(topic, scope, geography)`, normalized — casefolded, accent-folded
(because customers write in Spanish: *Bogotá* and *Bogota* must collide),
whitespace-collapsed. Deliberately no stemming or synonyms: a false miss costs
one research call, a false hit serves someone findings they didn't ask about.

`no_news` expires in well under an hour, while real findings last hours. A
quiet topic at 7am can be the day's story by 10am — a long-lived empty entry
would reintroduce the empty-day lockout #31 just fixed, for everyone at once.

### Continuity (#49)

> "this is also good for the customer no? like having a connection from the
> previous episode?"

Each segment now knows what you heard yesterday **on that same topic**, so it
moves the story forward instead of restarting it.

The asymmetry is load-bearing: findings are **shared and keyed by topic**; the
told-log is **per customer and keyed by their own request**, and lives only in
the writing half. `research_topic` can't even accept a history — there's a test
asserting it never will. Findings are common; memory is personal.

Only **published** episodes count as told. An episode that died in voicing has
finished scripts in the database and reached nobody; counting it would open
tomorrow with "yesterday we covered the rate decision" to someone who heard
silence.

---

## Two bugs worth knowing about

### The "no audio" cause was one swallowed exception

```python
except Exception as exc:
    # Don't fail the whole job over a TTS problem — the text episode is
    # still good and published; audio_url just stays null this time.
```

That comment was the bug. The job never reached a terminal status (stuck on
`voicing` forever), the episode published silent, and `episode_published` fired
anyway — **so the funnel counted silent episodes as successful deliveries.**
That's why this never showed up as a metric. You found it by listening.

### The cache would never have expired anything

`datetime.utcnow()` is naive, and asyncpg encodes a naive datetime for a
`timestamptz` using the **process's local timezone**. On this machine
(UTC-8), a row stamped "now" was stored **eight hours in the future**:

```
sent naive : 2026-11-11 17:20:48
echoed     : 2026-11-12 01:20:48+00:00
```

Every age computed negative. Every entry fresh forever. It would have served
yesterday's news indefinitely **while looking like it worked perfectly.**

Two things about this are worth keeping:

- My first fix — pinning the **DB session** timezone — was wrong. The
  conversion happens client-side in asyncpg, before Postgres sees anything.
  It failed the round-trip test, which is the only reason the real cause got
  found instead of a non-fix shipping on top of the bug.
- The first expiry test **passed in isolation and failed through the real
  fixture**. SQLAlchemy's identity map returned the value just assigned in
  Python and hid the conversion entirely. A test that asserts on an object it
  just wrote, in the same session, is not testing persistence.

**Production was never affected** — Railway's containers run UTC, so
naive-local happened to equal UTC. Correct by luck, not construction, and wrong
in local dev the whole time.

---

## What I need from you

1. **ElevenLabs credits.** Still the thing keeping the product non-functional.
   Every path around voicing is now correct and tested; **not one real episode
   has been verified end to end, because none can be.** #48 means every job
   that failed for lack of credits becomes recoverable for the price of audio
   alone once you top up.
2. **Merges.** I can't click them.
3. **An Anthropic key I can use locally.** The 64% routing saving is measured
   on **price, not quality** — no Haiku-written block has ever been compared
   against an Opus one. Don't trust that number yet.
4. **`INTERNAL_DASHBOARD_KEY`** in Railway Variables — until it's set, Home's
   "For you" and "Explore" shelves render nothing in production.
5. **A Voyage AI key** for the semantic index.

---

## What I deliberately did not do

**Move generation off the request path.** `POST /generation/run` still awaits
the whole pipeline inline, holding a DB connection ~40s — that's the real cause
behind the pool exhaustion, and #43's pool sizing only treats the symptom.

I stopped short because it changes an API contract the app on your phone
depends on (300s timeout, spinner), and shipping a half-migrated contract while
you're away and can't test would leave you with an app that can't generate at
all. Onboarding already does it correctly (#31's background task) and is the
pattern to copy. It needs the iOS client changed in the same step.

**The aware-UTC sweep across all 31 call sites.** #46 makes the existing
convention correct from one place; removing the hazard entirely is a larger,
riskier change that deserves you awake.
