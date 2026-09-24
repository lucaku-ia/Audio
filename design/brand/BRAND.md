# Lucaku brand

> **Lo que quieres saber, en punto.**
> *What you want to know, on the dot.*

Lucaku investigates what one person asked about and reads the answer back to them, every day, at the hour they chose. The identity is built on one object: **el punto**, the point.

- **It ends the name.** `lucaku.` closes the way a finished answer closes a sentence.
- **It carries Spanish meaning.** *En punto* means "on the dot": delivered every day at 7:00 sharp. *Al punto* means "to the point": no filler.
- **It's the whole app icon:** the first letter of the name, then the point.
- **When Lucaku speaks, the point moves.** It replaces the equaliser bars other audio apps use.

Open `brand_showcase.html` in a browser to see all of this rendered, in light and dark.

---

## 1. Files

| Path | What |
|---|---|
| `logo/lucaku-wordmark-{accent,ink,white,accent-dark}.svg` | Primary wordmark `lucaku.` as filled outlines, one colour per file |
| `logo/lucaku-mark-{accent,ink,white,accent-dark}.svg` | Compact mark `l.` |
| `app-icon/lucaku-app-icon.svg` / `-1024.png` | iOS app icon, default appearance. Full-bleed and opaque; iOS applies the mask |
| `app-icon/lucaku-app-icon-dark.svg` / `-dark-1024.png` | iOS dark appearance. Transparent; iOS supplies the dark field |
| `app-icon/lucaku-app-icon-tinted.svg` / `-tinted-1024.png` | iOS tinted appearance. White on transparent; iOS recolours it |
| `brand_showcase.html` | Self-contained reference page with the Login redesign |
| `explorations/` | The eight mark concepts and why seven were rejected |
| `source/` | The Python that draws everything |

**Never edit the SVGs by hand.** They are generated:

```sh
pip install skia-python          # on Linux also: apt-get install libegl1 libgl1
python3 design/brand/source/build.py
```

The letters are defined in `source/letters.py` and the mark in `source/mark.py`. Change the geometry there and rebuild; the showcase regenerates at the same time.

### Two-tone wordmark

In product UI, the letters take `text-primary` and the point takes `accent`: the page's accent marks the point. The single-colour files are for places that can't do two colours (embroidery, one-colour print, the reversed version on accent). To build a two-tone wordmark in code, use `letters.wordmark_parts()`, which returns the letters and the point as separate shapes. The showcase's inline SVG does exactly this.

---

## 2. The wordmark

It's drawn, not typeset: six lowercase letters built from three rules.

1. **The nib cut.** Every stem top is sheared 18 units over a 92-unit stem, rising left to right, like a broad pen held at a shallow angle. It's the one idiosyncratic detail. It is what separates the wordmark from a font.
2. **The tail.** The l, and both u's, turn out to the right on the baseline. The round letters inherit that motion, which gives the word an even forward rhythm.
3. **Contrast.** Curves and horizontals (84) are drawn lighter than stems (92), and round letters overshoot the baseline and x-height by 9. Without this, *c* and *a* would look heavier and shorter than *l*, *k* and *u*.

The **a** is double-storey. Next to the u and c, a single-storey *a* made the word read like a geometric children's typeface.

The wordmark is lowercase. A capital L broke the rhythm and would have required a second, cap-height nib angle. **This is a deliberate change from how the name has been written so far (`Lucaku Audio`), and it's flagged for the founder in §11.** In running text, write *Lucaku* with a capital.

### Clear space

Keep clear space on every side equal to the **x-height**, the height of the *u*. Nothing enters it: no other logos, no text, no edges.

### Minimum size

| Medium | Wordmark (full width) | Mark (height) |
|---|---|---|
| Screen | **72 pt** | **16 pt** |
| Print | 20 mm | 5 mm |

Below 72 pt the nib cut fills in and the point merges with the u. Use the mark instead.

### Colour

| Surface | Letters | Point |
|---|---|---|
| `bg` or `surface`, light | `#1C1C1E` | `#1E647E` |
| `bg` or `surface`, dark | `#F2F2F2` | `#74B9D1` |
| Accent `#1E647E` | `#FFFFFF` | `#FFFFFF` |
| Photography | Don't. Put the wordmark on a flat field |

### Don't

- Retype it in any font, SF included, or add "Audio" after it.
- Recolour letters individually, or use a colour other than the four above.
- Put the mark next to the wordmark. The wordmark already contains it.
- Stretch it, outline it, add a shadow, or set it on a gradient.
- Remove the point. `lucaku` without the point isn't the logo.
- Animate the letters. Only the point moves (§6).

---

## 3. The mark

The mark is `l.`: the first and last characters of the wordmark. It has the same construction, drawn heavier, so the tail and the point stay separate down to 16 pt. Use it where the wordmark can't fit: app icon, favicon, avatar, notification badge, watermark.

**Clear space:** one point diameter on every side.

---

## 4. App icon

- **Grid:** 1024 × 1024.
- **Glyph:** the mark, at 56% of the canvas height, centred on its bounding box and dropped 0.5% for optical centre.
- **Field:** the approved accent, lit from above. A linear gradient runs from `#23708C` to `#1A5870`, with the accent `#1E647E` as its midpoint, both stops inside the accent's own hue. On top of that is a 7% white radial glow from the top-left. It reads as one colour with a little depth, and it isn't the purple/blue gradient that was rejected.
- **Dark appearance:** the l in `#F2F2F2` and the point in `#74B9D1`, on the black field iOS supplies.
- **Tinted appearance:** all white; iOS tints it by luminance.

The icon doesn't use the lowercase-L-plus-dot to spell anything. On a home screen the label below it already says *Lucaku*. The icon only has to be recognisable, and at 60 pt it's one tall stroke and one round dot, which neither the blank icon nor the neighbouring apps look like.

**Installing it (not done in this PR):**

1. Copy the three `-1024.png` files into `ios/LucakuAudio/LucakuAudio/Assets.xcassets/AppIcon.appiconset/`.
2. Add `appearances` entries for `luminosity: dark` and `luminosity: tinted` in its `Contents.json`.

With Xcode 26 and Icon Composer, import `lucaku-app-icon.svg` as one layer group: the l and the point are separate paths, so the point can take its own Liquid Glass specular if wanted.

---

## 5. Colour roles

The palette is the approved one and is unchanged. The new part is **a rule for where the accent goes: the accent marks the point.** It appears in three places, and it is never decoration:

1. the wordmark's point;
2. the **one** primary action on a screen;
3. the word being spoken right now (§6).

| Token | Light | Dark | Role |
|---|---|---|---|
| `accent` | `#1E647E` | `#74B9D1` | The point, primary action, the spoken word |
| `accent-on` | `#FFFFFF` | `#05262F` | Text and glyphs on an accent fill, nowhere else |
| `bg` | `#F2F2F7` | `#000000` | The screen |
| `surface` | `#FFFFFF` | `#1C1C1E` | Grouped fields, the listening card. Separation by value, **not by a border** |
| `surface-2` | `#FFFFFF` | `#262629` | Raised above a surface in dark mode (sheets, menus) |
| `text-primary` | `#1C1C1E` | `#F2F2F2` | Wordmark letters, titles, body |
| `text-secondary` | `rgba(60,60,67,0.68)` | `rgba(235,235,245,0.64)` | Metadata, field labels, context |
| `border` | `rgba(60,60,67,0.29)` | `rgba(84,84,88,0.6)` | Hairline dividers *inside* a group, never an outline around a card |

The dark `text-secondary` and `border` values weren't in the approved list, so they come from the existing `ios/…/DesignSystem/LucakuColor.swift`.

---

## 6. Motion: the point speaks

Other audio apps show equaliser bars. **Lucaku shows the point.**

- **While Lucaku reads,** a small accent circle (8–14 pt) scales between 1.0 and about 1.2 with the voice's loudness envelope. Drive it from the audio's RMS level, smoothed over about 80 ms. It should not run on a loop.
- **When paused,** the point is still at 1.0.
- **Transcript:** the word being read takes `accent`, words already read take `text-primary`, and upcoming words take `text-tertiary`.
- **Reduce Motion:** the point doesn't scale, and the transcript shows fully read.

This is also the answer to the founder's note that the app lacked something *"live"*: the brand's one object is the thing that's alive. The showcase's "The point speaks" section and the Login card both demo it.

---

## 7. Type

The type is **San Francisco, the system face**, at the Apple HIG scale already in `LucakuTypography.swift`. There is no brand typeface. The only drawn letters are the wordmark's, and they are never used to set text.

| Role | Size / line | Weight | Use |
|---|---|---|---|
| Large Title | 34 / 41 | Regular | One per screen: the greeting or the screen's statement |
| Title 1 | 28 / 34 | Regular | Section openers |
| Title 2 | 22 / 28 | Regular | Story or topic titles |
| Title 3 | 20 / 25 | **Semibold** | "Tu resumen de hoy" |
| Headline | 17 / 22 | **Semibold** | Row titles: the topic name |
| Body | 17 / 22 | Regular | Transcript, explanations |
| Callout | 16 / 21 | Regular | Context under a title |
| Subhead | 15 / 20 | Regular | Metadata lines ("Tres temas · 6 minutos") |
| Footnote | 13 / 18 | Regular | Sources |
| Caption 1 | 12 / 16 | Regular | Timestamps |
| Caption 2 | 11 / 13 | Regular | Legal, version |

Rules:

- Mostly Regular, with **one Semibold moment per screen**.
- Sentence case. No all-caps eyebrows.
- Text is left-aligned, including the Login screen. Centre only single words inside buttons.

**Spacing** is on the 8 px base: 4 / 8 / 12 / 16 / 24 / 32 / 48. Screen margins are 24 on phones and 16 at the tightest.

**Radii** follow the element's size, never one uniform value:

| Radius | Used on |
|---|---|
| 8 | Rows, thumbnails, colour swatches |
| 10 | Chips and segmented controls |
| 16 | Cards: grouped fields, the listening card, the mini-player |
| 20 | Sheets and large panels |
| Full capsule (height ÷ 2) | Buttons |

---

## 8. Voice and tone

Lucaku talks like **a well-read friend who did the reading for you**: calm, direct and specific, in **tú**, in Colombian Spanish. It says what it found and why it matters to *your* question. When there's nothing new, it says so plainly instead of padding.

Principles:

- **Specific over generic.** Name the topic, the source, the hour.
- **First person singular in speech** ("te leo", "vuelvo a buscar"). The app talks to one person.
- **Never make the listener do work.** Errors say what Lucaku is doing about it.
- **No hype.** No exclamation marks, no emoji, no "AI-powered", no "¡Increíble!"
- **Numbers as people say them.** "6 min", "a las 7", not "07:00:00".

| Where | Before | After |
|---|---|---|
| Onboarding prompt | Selecciona tus intereses *("Select your interests")* | **¿Qué quieres saber? Dilo como se lo dirías a un amigo.** *("What do you want to know? Say it the way you'd tell a friend.")* |
| Nothing new today | No se encontraron noticias. *("No news found.")* | **Hoy no hubo nada nuevo sobre la Premier League. Mañana a las 7 vuelvo a buscar.** *("Nothing new on the Premier League today. I'll look again tomorrow at 7.")* |
| Notification | 🎧 ¡Tu nuevo episodio ya está disponible! *("🎧 Your new episode is available!")* | **Tu resumen de hoy está listo · 6 min** *("Today's summary is ready · 6 min")* |
| Error | Error 500: la solicitud falló. *("Error 500: request failed.")* | **No pude terminar tu resumen. Lo intento de nuevo en unos minutos; no tienes que hacer nada.** *("I couldn't finish your summary. I'll try again in a few minutes; you don't need to do anything.")* |
| Spoken opening | ¡Bienvenido a tu podcast diario generado por IA! *("Welcome to your daily AI-generated podcast!")* | **Buenos días, Ana. Hoy tengo tres cosas sobre el café y una sobre Atlético Nacional.** *("Good morning, Ana. Today I have three things about coffee and one about Atlético Nacional.")* |
| Login headline | Lucaku Audio · Log In | **Lo que quieres saber, en punto.** |

We call it a **resumen** (summary), not an *episodio* or *podcast*: it's research read aloud, not a show.

---

## 9. What Lucaku is not

- **Not a music app.** No equaliser bars, soundwave bars, vinyl, headphones, microphones or play triangles as brand elements.
- **Not a news aggregator or feed.** No tickers, breaking-news red, or endless lists. One summary a day, and it ends.
- **Not an "AI" brand.** No sparkles, glowing orbs, or purple/blue gradients. The research is the product, not the model.
- **Not a podcast network.** No show art, no hosts.
- **Not warm-editorial pastiche.** No cream paper, serif headlines or terracotta.
- **Not loud.** No emoji as UI markers, no exclamation marks, no streaks or gamification.
- **Not generic UI.** Not everything centred, not one radius on everything, no accent bars on cards, no borders around every card, no stock thin-line icon sets. Use SF Symbols at the text weight they sit next to.

---

## 10. Research: what I actually looked at

This environment's network policy blocked opening the web pages themselves. Every WebFetch to sonos.com, instrument.com, fabrikbrands.com, elhilo.audio, everyinteraction.com and developer.apple.com's rendered HIG failed. **So what follows is based on search-result summaries, not on reading the case studies.** Treat it as orientation, not a citation you can lean on.

- **Headspace.** Its mark is one orange dot, deliberately not a perfect circle, so it reads as drawn by hand ([DesignRush](https://www.designrush.com/best-designs/logo/headspace)). *Lesson:* a calm product can be carried by one simple shape, if the shape has a reason. *Not copied:* Lucaku's point is a period with a typographic job, it is geometric, and it isn't the whole logo.
- **Sonos.** Bruce Mau's wordmark is an ambigram, and the 2024 refresh was done by Instrument. The results didn't describe the refresh in detail ([Sonos blog](https://www.sonos.com/en-us/blog/sonos-brand-design-refresh) and [Instrument](https://www.instrument.com/work/sonos-brand-refresh), search summaries only). *Lesson:* an audio company can use a pure wordmark, with no sound symbol, and still own its category.
- **BBC Sounds.** The logo adds three growing orange blocks, "intended to symbolize volume or sound" ([Fabrik Brands](https://fabrikbrands.com/branding-matters/logofile/bbc-sounds-logo-history/)). *Lesson, by contrast:* this is the literal-volume route the brief asked to avoid.
- **Pocket Casts / Overcast.** A play button in a square, and a cloud with a lightning bolt ([LogoCrafter roundup](https://www.logocrafter.app/blog/best-podcast-logos), [Android Authority](https://www.androidauthority.com/pocket-casts-material-design-redesign-864146/)). *Lesson, by contrast:* the play-triangle icon is the category default, so avoiding it is itself a way to stand out.
- **The Economist Espresso.** A daily, finite, "short, sharp shot" edition, with audio of every piece ([Campaign](https://www.campaignlive.com/article/economist-goes-daily-espresso-app/1321069), [Twipe](https://www.twipemobile.com/how-the-economist-uses-the-espresso-app-to-appeal-to-a-younger-audience/)). *Lesson:* for a daily product, "it ends" is a feature. That's where the voice rule "one summary a day, and it ends" and the "not a feed" stance come from.
- **Radio Ambulante / El Hilo.** A Latin-American Spanish audio journalism reference for register ([Wikipedia](https://en.wikipedia.org/wiki/Radio_Ambulante), [Apple Podcasts](https://podcasts.apple.com/us/podcast/el-hilo/id1504713161)). I couldn't open their sites, so this informed tone only. **Worth a human listening session before voice copy is finalised.**
- **Apple app icon guidance.** Summarised via third parties ([App Launchpad](https://theapplaunchpad.com/blog/ios-app-icon-guidelines/), [AppLaunchFlow on iOS 26 variants](https://www.applaunchflow.com/blog/ios-26-app-icon-sizes-variants)): avoid text, simple shape, and provide dark and tinted variants, with the dark variant leaving the background out. The icon here follows all four.

---

## 11. Open questions for the founder and a designer

1. **Lowercase `lucaku.`** is a real change from "Lucaku Audio". It needs sign-off.
2. **Tú vs usted.** Many Colombian apps use *tú*. Some audiences expect *usted*. Test it with five real customers.
3. **The nib-cut angle** (18/92) was judged on screen, at sizes from 72 pt to 560 px. A type designer should review the *a* (its shoulder-to-stem join has a small taper) and the *k* (junction weight) at display size before anything is printed large.
4. **Icon squircle.** The previews use a 22.37% rounded rectangle, not Apple's continuous-corner mask. Check the real thing in the Icon Composer or Xcode preview.
