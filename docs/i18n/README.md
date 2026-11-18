# Lucaku Audio iOS: Spanish (es) + English (en) localization kit

Status: **proposal, additive only.** Nothing under `ios/` was edited. These files are a hand-off for the iOS owner.

Founder decision: the app is fully bilingual (es + en) for UI, audio, news and voices, and a single language setting drives all of it. The old "UI English only" rule is superseded.

Files in this folder:

| File | What it is |
|---|---|
| `Localizable.xcstrings` | Xcode String Catalog. `sourceLanguage: en`, `es` translations, keys equal to the English source text, plural variations where needed. |
| `InfoPlist.xcstrings` | The two permission prompts (microphone, speech recognition), localized. |
| `README.md` | This file: integration, runtime switching, required code changes, style guide, glossary, test checklist, truncation table. |
| `audio-copy.md` | Spoken intro / transition lines (10 each, es + en) and the server-originated messages that must exist in both languages. |

## 1. Inventory

Walked every SwiftUI source under `ios/LucakuAudio/LucakuAudio` (Auth, Onboarding, Home, News, Player, Feedback, Interests, Search, Settings/Profile, Library, ContentView, DesignSystem, Networking errors, Services).

Catalog size: **494 keys** (485 plain + 9 plural keys). Some keys are shared by several screens, so the per-screen counts below add up to more than 494.

| Screen group | Keys | Notes |
|---|---|---|
| Shell (tab bar, app name) | 4 | Tab labels are the first truncation risk |
| Auth (LoginView) | 23 | |
| Onboarding (chat copy, cards, category labels) | 136 | The chat bubbles are plain `String`s, not localizable as-is |
| Home (top card, states, greeting) | 52 | |
| News (feed, story detail, day groups) | 24 | |
| Player (now playing, mini player, share sheet, list) | 48 | |
| Feedback (Useful / Not quite sheet) | 17 | |
| Interests (+ sheet, episode tiles, voice input) | 49 | |
| Search | 21 | |
| Profile / Settings (History, Downloads, Notifications, Account, Delivery & voice) | 112 | |
| Errors and services (APIError, audio, speech) | 21 | All `String`, all need code changes |
| Library (dev-only screen) | 11 | Debug surface, translated for completeness |
| **Plural keys** | 9 | Included in the groups above |

About 234 of the 494 keys are marked `NEEDS CODE CHANGE` in the catalog `comment` field. That means the text exists in the catalog, but the Swift call site will keep showing English until the change in section 4 is made. Plain `Text("literal")`, `Button("literal")`, `Label("literal", ...)`, `.navigationTitle("literal")`, `.alert("literal")`, `TextField("literal", ...)` and `.accessibilityLabel("literal")` pick the catalog up with no code change.

Not translated on purpose:
- Mock news stories in `Features/Home/HomeNews.swift:146-229` and `HomeView.swift:210,239,251` (debug/preview data). Real news is generated server-side per language.
- `Features/AudioDemo/AudioEngineDemoView.swift` (developer demo).
- Brand wordmark `lucaku.` (verbatim in all languages).

## 2. Adding the catalog to the Xcode project

The project uses a classic hand-listed `project.pbxproj` (no file-system-synchronized groups), so the files must be added in Xcode.

1. In Xcode: File > Add Files to "LucakuAudio"... pick `Localizable.xcstrings` (and `InfoPlist.xcstrings`). Tick **Copy items if needed** and tick the **LucakuAudio** app target (target membership). Put them next to `Info.plist`.
2. Project > Info > Localizations: press `+`, add **Spanish (es)**. This writes `es` into `knownRegions` in `project.pbxproj`. Today it reads `knownRegions = ( en, Base, );` (`ios/LucakuAudio/LucakuAudio.xcodeproj/project.pbxproj:432`). It should end up as `( en, Base, es, )`. Keep `developmentRegion = en` because the catalog source language is English.
3. Build once. Xcode will show the catalog with 100% `es` translated. `SWIFT_EMIT_LOC_STRINGS = YES` is already set, so Xcode will also extract any new literals into the catalog on the next build. Entries here are marked `extractionState: manual`; Xcode will take over the ones it finds in code (it flips them to `extracted_with_value`) and leave the dynamic ones as manual.
4. `InfoPlist.xcstrings` localizes `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`. These live in `Info.plist` today, which is fine; the catalog overrides them per language.
5. Plurals: Spanish also has a `many` category (used for large round numbers in some locales). It is filled in with the same text as `other`, so Xcode will not warn.

## 3. Switching language at runtime from the single in-app setting

Facts from the code:
- The setting already exists: `ProfileLanguage` (`.es` / `.en`) in `Networking/Models/SettingsModels.swift`, edited in Profile > Delivery & voice and saved by `PATCH /profile` (`SettingsViewModel.swift:109`). Signup sends `idioma` chosen from `Locale.current` (`LoginView.swift:435`).
- SwiftUI follows the **system** language by default, so changing the in-app setting will not change anything by itself.

Options:

| Option | How | Pros | Cons |
|---|---|---|---|
| A. `.environment(\.locale, Locale(identifier: lang))` on the root view | Set it once in `LucakuAudioApp` | Official, instant, no restart. Switches every `Text("literal")`, `LocalizedStringKey`, `Label`, `Button`, formatters that read `@Environment(\.locale)`, and `Date.FormatStyle`. | Does **not** affect `String(localized:)`, `NSLocalizedString`, `DateFormatter()` created without the locale, system alerts, share sheets, keyboard, or `Info.plist` prompts. |
| B. Bundle swizzle (`object_setClass(Bundle.main, ...)`, "LanguageBundle") | Override `localizedString(forKey:)` | Makes `String(localized:)` and `NSLocalizedString` follow the setting | Private-ish hack, breaks with String Catalog edge cases, plural handling gets fragile. Not recommended. |
| C. Write `AppleLanguages` in `UserDefaults` | Needs an app restart | Also switches system UI | Requires relaunch; poor UX. |
| D. iOS 17 per-app language (Settings > Lucaku > Language) | Free once `es` is in `knownRegions` | Zero code | Two sources of truth (the founder wants one). |

**Recommendation: A plus a thin helper for everything that is not a SwiftUI literal.**

1. Add `AppLanguage` (an `ObservableObject` or `@AppStorage("appLanguage")`, mirroring `ProfileLanguage`). On launch and on `PATCH /profile` success, update it. On first launch before login, default from `Locale.preferredLanguages.first` (es if it starts with `es`, else en).
2. In `LucakuAudioApp`: `ContentView().environment(\.locale, Locale(identifier: appLanguage.code))`. Use `es-CO` for formatting if desired (see section 6); string lookup falls back to `es`.
3. For non-SwiftUI strings (the 234 flagged ones), introduce one function and use it everywhere:
   ```swift
   func L(_ key: String.LocalizationValue, _ lang: AppLanguage = .current) -> String {
       String(localized: key, locale: Locale(identifier: lang.code))
   }
   ```
   `String(localized:locale:)` formats with that locale but still picks the bundle language from the process. For an exact bundle lookup, load the `es.lproj`/`en.lproj` sub-bundle that Xcode generates for the catalog: `Bundle(path: Bundle.main.path(forResource: lang.code, ofType: "lproj")!)` and call `String(localized: key, bundle: thatBundle)`. This is deterministic and needs no swizzling. Build `L` on this.
4. Keep the device-local setting and the server setting in sync: when the user flips language, set `appLanguage` immediately (UI flips at once), then `PATCH /profile` with the new `language`. Roll back both if the PATCH fails.
5. Send `Accept-Language: <code>` on every API request (add it in `APIClient`) so the backend can localize server messages (see `audio-copy.md`, section 3).
6. Speech: `LucakuLocale.speechLanguage(forIdioma:)` (`Services/Voice/SpeechService.swift:181`) already maps `es` to `es-MX`. `InterestsView.swift:506` instead derives the idioma from `Locale.current`; change it to the app language. Consider `es-CO` for recognition (supported by `SFSpeechRecognizer`), with `es-MX` as the fallback. Verify on device.

## 4. Code changes required

Grouped by cause. Line numbers are against `origin/main` at `da0c772`.

### 4.1 Strings that are `String`, not `LocalizedStringKey`

These will never localize through the catalog until wrapped (`String(localized:)` or the `L()` helper):

- **Ternaries inside `Text(...)`**: `Text(cond ? "a" : "b")` infers `String` and is rendered verbatim. Write `cond ? Text("a") : Text("b")` or `Text(LocalizedStringKey(cond ? "a" : "b"))`. Same for `.accessibilityLabel(cond ? "a" : "b")` and `.accessibilityHint(...)`. Sites: `HomeComponents.swift:296`; `HomeTopCard.swift:189,313,374,395`; `HomeNewsViews.swift:84,140,168,221,276,421`; `NowPlayingView.swift:262,325,452`; `InterestsComponents.swift:139,191,234,265,382,398`; `InterestsView.swift:270,425,444`; `LoginView.swift:315`; `OnboardingView.swift:262`; `MiniPlayerView.swift:119`; `SettingsView.swift:86,211`.
- **Parameters typed `String`** passed to custom components (`CardPrimaryButton(title:)`, `CardOutlineButton(title:)`, `PrimaryButton(title:)`, `SecondaryButton(title:)`, `TextButton(title:)`, `Chip(title:)`, `CardTitle(title:subtitle:)`, `ProfilePage(title:subtitle:backTitle:)`, `ProfileRow(title:subtitle:value:)`, `ProfileCardRow(title:)`, `ProfileNote(text:)`, `ProfileSectionLabel(text:)`, `EpisodeTile(label:value:)`, `SearchSectionHeader(title:)`, `sectionLabel(_:)`, `optionRow(label:)`, `providerButton(title:message:)`, `smallButton(_:)`, `requestField(placeholder:)`). Inside, they do `Text(title)` which is verbatim. Change the stored property to `LocalizedStringKey` (literals keep working) or call `Text(LocalizedStringKey(title))`. For values that are built at runtime (`"\(n) min"`), pass `LocalizedStringResource` or a pre-localized `String` and use `Text(verbatim:)` on purpose.
- **Enum raw values used as labels**: `LoginView.swift:32-33` (`case login = "Sign in"`), `SettingsModels.swift:20-58` (narration style names, `ProfileLanguage.displayName`), `AppearancePreference.swift:23-25` (System/Light/Dark), `ProfileStore.swift:61` (`"15 min"`, `"1 h"`), `HomeNews.swift:14-25` (category `label`), `HomeTopCard.swift:14-22` (debug state names, ignore), `ProfilePages.swift:318-329`. Return `LocalizedStringResource`/`String(localized:)` from a `displayName` property and keep the raw value stable for the API. Keep `Español` / `English` language names **untranslated** (each in its own language).
- **View-model / service errors** (user-visible): `LoginView.swift:408,482-511`, `APIError.swift:17-161` (`errorDescription`, `humanize`), `AudioPlayerService.swift:275,325,452,456`, `SpeechService.swift:167,169`, `InterestsViewModel.swift:194`, `InterestsView.swift:509`, `PlayerViewModel.swift:284`, `SettingsViewModel.swift` (load/save messages), `ProfilePages.swift:496-498`, `ProfileComponents.swift:326` (`"Off"`). Wrap in `String(localized:)`.
- **`APIError.server` passes the backend message through verbatim** for 4xx and 503 (`APIError.swift:25-33`). That text is English today. The backend must localize it (see `audio-copy.md`, section 3). Recommended: backend returns `{"detail": "...", "code": "budget_exceeded"}` and the client prefers a catalog string keyed by `code`, falling back to `detail`.
- **FastAPI validation text** (`extractErrorDetail`, `APIError.swift:109-161`): already humanized on the client in English; `humanize()` must use localized fragments, and the field labels (`Password`, `Email`, `Name`) must be localized separately.

### 4.2 Onboarding chat copy

`OnboardingChatFlow.say(_ text: String)` (`OnboardingView.swift:458`) and `userSays(_:)` (`:465`) take plain `String`s, and ~60 call sites between lines 516-1100 pass English literals. Change both to take `String.LocalizationValue` (or call `L(...)` at each site). The interpolated ones need `%@` / `%lld` format keys; they are in the catalog (for example `Added %@ to %@. Anything else, or tap Next?`).

Also in this file:
- `inputPlaceholder`, `inputHint`, `statusLine`, `topicsToConfirm`, `suggestionSubtitle`, `nextCategoryTitle`, `summaryTopics` (lines 361-425) return `String`.
- `joined(_:)` (`:1108-1113`) hard-codes " and " and an Oxford-free comma list. Use `ListFormatter` / `Array.formatted(.list(type: .and))` with the app locale, so Spanish gets "y".
- `isDonePhrase` (`:448-453`) only recognizes English "i'm done / done / that's all". Add Spanish: `ya terminé`, `ya termine`, `listo`, `eso es todo`, `ya está`, `ya esta`, `nada más`, `nada mas`, `terminé`, `termine`, `ya`.
- `parseTime` (`:1002-1020`) understands `am`/`pm` only. Add `a. m.`, `p. m.`, `a.m.`, `de la mañana`, `de la tarde`, `de la noche`, 24-hour input, and `y media`/`y cuarto` is optional.
- `genericTopics` (`:589-592`), the " and " splitter (`:598`), `keywords` (`:1344-1358`, used by `guess(for:)`), `HomeNews.swift:52-63` and `HomeComponents.swift:140-150` (icon matching) are English keyword lists. Add Spanish equivalents (deportes, fútbol, economía, inflación, salud, política, clima, etc.) or the classification and icons silently degrade for Spanish input.
- **Category `label` is used as an identifier** (`OnboardingCategories.guess` returns a label, `suggestions(for: category)` does `first(where: { $0.label == category })`, `HomeNews.swift`/`InterestsViewModel` compare labels). If `label` becomes localized, that matching breaks. Split into `id` (stable, already present: `local`, `politics`, ...) and `displayLabel`, and compare on `id`.
- Time chips (`:1996-1999`: `"6:00 AM"`) and length chips (`:2017`: `"As long as it needs"`) are tuples of `String`. Format the time with `Date.FormatStyle` (see section 6) and localize the label.
- `OnboardingPlace` data (`:1153-1215`: cities, politics, markets, sports) and `topics:` arrays (`:1303-1340`) are English strings that become **topic suggestions and the text of standing requests sent to the backend** (`request(forTopic:)` builds "Latest news on X"; `"Top X stories"` at `:893,921`; `InterestCatalog.followText` in `InterestsViewModel.swift`; `InterestsViewModel.swift:427` `popular`). Decide with the backend which language the research prompt is written in (recommended: the user's language, so the generated script matches). These tables need an `es` variant (the Colombia one first; most are proper nouns).

### 4.3 Interpolation, plurals and concatenation

- Manual plurals by string slicing: `HomeTopCard.swift:199` (`"stor\(n == 1 ? "y" : "ies")"`) and `:450` (`"topic\(n == 1 ? "" : "s")"`), `NowPlayingView.swift:251` (`"story"/"stories"`). Replace with `String(localized: "\(count) stories")` and the plural variations already in the catalog (`%lld stories`, `Following %lld topics`).
- Composite strings that mix plural, ternary and nested interpolation cannot be translated as written: `HomeNewsViews.swift:123` (`"\(n) stories · \(unread > 0 ? "\(unread) unread" : "all read")"`), `:276` (`"\(day) · \(time) · \(n) min read"`), `HomeNews` summary line `HomeNewsViews.swift:48`, `SettingsView.swift:211` (mode · notifications · language). Split into separate `Text`s or separate localized pieces joined with a locale-aware separator.
- Numbers and counts: `"\($0) min"`, `"\($0) minutes"` (`InterestsComponents.swift:346-349,398`, `DeliverySettingsViews.swift:303`, `InterestsView.swift:138`). Use `Measurement<UnitDuration>` with `.formatted(.measurement(width: .abbreviated))` or the plural keys (`%lld minutes`).
- `Text("a") + Text("b")` and brand wordmark: `LoginView.swift:528` (`Text("lucaku") ... + Text(".")`), `NowPlayingView.swift:285`, `ShareSheetView.swift:178` (`Text("lucaku.")`), `OnboardingView.swift:1588-1592` (spoken-text highlight built from `Text(head + " ")`). Wordmarks should become `Text(verbatim: "lucaku")` so they never enter the catalog. The spoken-text builder is fine (it renders runtime content, use `Text(verbatim:)`).
- Greeting by time of day (`HomeComponents.swift:39-41`) and ordinal-less date strings: localize and keep the 5/12/18 hour cut-offs.
- Share text `"\(first) thinks you'll like this story on Lucaku:"` (`ShareSheetView.swift:72`): translate the whole sentence; the Spanish version uses a different name position, so keep `%@` as one placeholder.

### 4.4 Dates, times and numbers

- 12-hour clocks with hard-coded `"PM"/"AM"` via `String(format:)`: `HomeViewModel.swift:38`, `HomeNews.swift:96`, `InterestsComponents.swift:488`. Replace with `Date.FormatStyle`: `date.formatted(.dateTime.hour().minute())` (es-CO renders `7:00 a. m.`).
- `DateFormatter` with a hard-coded `en_US` locale or English pattern: `HomeComponents.swift:30` (`"EEEE, MMMM d"`), `:56-58` (`"EEE"`, `"MMM d"`), `HomeNews.swift:111-112`, `ProfileComponents.swift:359-374` (`"h:mm a"`, `"EEE, MMM d"`), `NowPlayingView.swift:259-260`, `OnboardingView.swift:441-443`. Use `setLocalizedDateFormatFromTemplate("EEEEMMMMd")` or `.formatted(.dateTime.weekday(.wide).month(.wide).day())` with the **environment locale**. Spanish output: `jueves, 13 de noviembre`.
- `Calendar.current.isDateInToday` returns "Today": `ProfileComponents.swift:346` (use localized `Today`/`Hoy`, or `RelativeDateTimeFormatter`).
- Keep `en_US_POSIX` only for **parsing** wire formats (`yyyy-MM-dd`, `HH:mm`): `HomeComponents.swift:51`, `InterestsView.swift:574`, `ProfileComponents.swift:352,366`, `ProfilePages.swift:292`, `SettingsViewModel.swift:198`. Those are correct.
- Elapsed/remaining durations (`HomeFormat.clock(left)` in `HomeTopCard.swift:313`) are `m:ss` and locale-neutral.

### 4.5 Misc

- `Text(variable)` where `variable` is server content (headline, topic labels, news titles) is correctly verbatim: no change.
- `Text(episode.headline ?? "Daily briefing")` and similar `??` fallbacks are `String`: wrap the fallback with `String(localized:)`.
- Screen-reader strings built by concatenation: `HomeNewsViews.swift:168` (`"Unread. " + category + ". " + title`), `SettingsView.swift:86`. Localize each piece.
- `HomeView.swift:60` / `SearchView.swift:72` / `LibraryView.swift:71` navigation titles are plain literals and work, but tab titles and nav titles must match (Inicio / Buscar / Biblioteca).
- Speech synthesis voices (`SpeechService.swift:41`): fallback voice is `en-US`; add `es-MX` fallback when the app language is es.
- Verify there is no layout that assumes English string length (section 8).

## 5. Spanish style guide applied

- **Register**: `tú`. Never `vos`, never `usted`. Warm, direct, short. Example: "Tus noticias, contadas a tu manera."
- **Variety**: neutral Latin American Spanish with Colombian-friendly choices. No Spain-specific vocabulary (no `ordenador`, `móvil`, `vale`, `coger`, `vosotros`, no `¡Genial!` as filler); no Argentine, Mexican or Caribbean slang. Prefer words understood from Bogotá to Mexico City.
- **Brand voice**: same as English: short, plain, human. Keep sentences under ~12 words where possible. Contractions in English map to simple verbs in Spanish, not formal constructions.
- **Verbs**: infinitive for buttons and actions (`Guardar`, `Reintentar`, `Cerrar sesión`), imperative `tú` for instructions (`Toca`, `Elige`, `Escribe`). Never the polite `Toque`.
- **Capitalization**: sentence case in titles and buttons (Spanish does not capitalize each word): `Cerrar sesión`, not `Cerrar Sesión`. Uppercase only for existing all-caps labels (`EPISODIO`).
- **Punctuation**: always the opening `¿` / `¡`. Ellipsis uses `…`. Straight quotes `"…"` in strings (angular quotes `«»` are rare in LatAm UI); `“…”` curly quotes are kept where the English used them.
- **Time**: `7:00 a. m.` (with spaces and dots, as iOS renders `es-CO`). 24-hour input accepted. Never `AM/PM`.
- **Numbers**: decimal comma, thousands with a space or period depending on locale; let `NumberFormatter` decide.
- **Inclusive language**: avoid gendered nouns for the user where possible (use `¿Primera vez aquí?`, not `¿Eres nuevo?`). Use "tu cuenta", not "bienvenido/a".
- **Loanwords**: `feed`, `push`, `Wi-Fi`, `ID`, `Lucaku`, `WhatsApp`, `Google` stay as is. `IA` (not `AI`) for artificial intelligence.
- **Tone words to avoid**: `Oops`, `¡Ups!`, `Lamentablemente`, `Por favor` repeated in every error. Errors say what happened and what to do: "No pudimos cargar Inicio" + a Reintentar button.
- **We/I voice**: the product and the chat avatar use first person plural for the company (`No pudimos…`) and first person singular for the assistant in the onboarding chat (`Te escucho`, `Lo capté`), mirroring English "We couldn't" and "I didn't catch".

## 6. Dates, numbers and formats: es-CO vs en

| Item | en (en_US) | es (es-CO) |
|---|---|---|
| Time | `7:00 AM` | `7:00 a. m.` |
| Long date | `Thursday, November 13` | `jueves, 13 de noviembre` |
| Short date | `Nov 13` | `13 nov` |
| Weekday short | `Thu` | `jue` |
| Decimal | `1,234.5` | `1.234,5` |
| Currency | `$1,200` | `$1.200` |
| Duration | `8 min` | `8 min` |
| List | `A, B and C` | `A, B y C` |
| Greeting | `Good morning` | `Buenos días` |

Implementation: never set `en_US` on formatters that show text to users; take the locale from `@Environment(\.locale)` (set by the language setting) and use `FormatStyle` APIs. For the Spanish locale use `Locale(identifier: "es-CO")` for formatting only (Colombian conventions), and keep string lookup on `es`. If the user's device region is Mexico or Argentina, formats still follow the app language; if you want regional formats from the device, use `Locale(identifier: "es_" + Locale.current.region!.identifier)`. Decision for v1: es-CO everywhere (first market), revisit when other regions ship.

## 7. Glossary and decisions

| English | Spanish | Reason |
|---|---|---|
| Lucaku | Lucaku | Brand. Never translated, never declined ("tu Lucaku"). |
| Episode | episodio | Natural for audio/podcast in all of LatAm. Used consistently, including "Today's episode" / "Episodio de hoy". |
| Capsule | cápsula (reserved) | The word is **not used in the current UI** (it says episode / story / block). If the audio script copy needs a name for one short segment, use `cápsula` in Spanish and `capsule` in English everywhere, never mixed with `bloque`. |
| Story (news item) | noticia | In news, `historia` reads as a narrative or Instagram story. `noticia` is what users call it. |
| Story (narration style) | Narrativo | `Historia` would clash with the news meaning; `Narrativo` also pairs with `Noticia directa` and `Conversacional`. |
| Home | Inicio | iOS Spanish uses `Inicio`. Short (6 chars) for the tab bar. |
| Interests | Intereses | Direct, short, 9 chars. Alternatives considered: `Temas` (clashes with "topics"). |
| Profile | Perfil | iOS standard. |
| Search | Buscar | Verb form, as in iOS tab bars (`Buscar`). |
| Topic | tema | Short, plain. "Following 3 topics" becomes `Siguiendo 3 temas`. |
| Follow / Following | Seguir / Siguiendo | Matches social and news apps. |
| Standing request | pedido (user-facing), "interés" | `Pedido` is understandable (a thing you asked for); `solicitud` is too formal. Needs native review. |
| Useful / Not quite | Útil / No del todo | `No del todo` keeps the soft "not quite" tone. Alternative: `Podría mejorar`. Needs native review. |
| Briefing | resumen | `Briefing` is business jargon; `resumen` is plain. |
| Delivery time | hora de entrega | Where English says "delivery", Spanish pairs it with `hora`. "Ready at" becomes `Listo a las`. |
| Narration style | estilo de narración | |
| Straight news / Story / Conversational | Noticia directa / Narrativo / Conversacional | |
| Sign in / Create account | Iniciar sesión / Crear cuenta | Standard iOS wording. |
| Sign out | Cerrar sesión | |
| Notifications | Notificaciones | |
| Downloads | Descargas | |
| Transcript | Transcripción | |
| Ticket | caso | `Ticket` is common but anglicised; `caso` is plain. Needs native review. |
| Wi-Fi | Wi-Fi | |
| Push notifications | notificaciones push | |
| Settings (iOS) | Ajustes | Matches iOS Spanish. |
| Mark read / unread | Marcar leído / no leído | Kept short for buttons. |
| Reintentar / Cancelar / Listo / Aceptar | Retry / Cancel / Done / OK | `OK` becomes `Aceptar` (iOS wording). `Done` is `Listo`. |

Words deliberately not used: `vos` forms, `usted`, `ordenador`, `móvil` (use `celular` only if ever needed), `ahora mismo` repeated, `genial`, `chévere`, `parce`.

## 8. Truncation risk and text expansion

Spanish runs about 15-30% longer than English; individual labels can double (`Mark read` 9 chars to `Marcar leído` 12; before shortening it was 17). Strings below have a fixed container (tab bar, chip, 54pt button, `lineLimit`) and were flagged. The Spanish shown is the shipped catalog value after shortening.

Riskiest screens, in order:
1. **Tab bar** (`ContentView.swift:74-86`): `Inicio`, `Intereses`, `Perfil`: 6, 9, 6 chars, all fit; but Dynamic Type at AX sizes still truncates, same as English.
2. **News feed row actions** (`HomeNewsViews.swift:37,221`): `Todo leído`, `Marcar leído`, `Marcar no leído` in small capsule buttons.
3. **Home top card buttons (54pt, `CardPrimaryButton`)**: `Generar mi episodio ahora`, `Generar uno ahora`, `Agregar pedido`, `Pedir para hoy` plus an icon; single line at 54pt height.
4. **Onboarding chips and buttons**: time chips (`7:00 a. m.` is 2 chars longer than `7:00 AM`), `Lo que haga falta`, `Ya terminé de agregar temas` (text button), `Agregar selección`, `Ya terminé, omitir el resto`, and the 4-step header (`Temas · Detalles · Entrega · Estilo`).
5. **Feedback sheet**: chips `No me interesa`, `Dejar de cubrir este tema`, and the two-line placeholder.
6. **Interests episode tiles** (`Listo a las`, `Duración`, `Estilo`, `Voz`): four 2-column tiles.
7. **Profile rows** with subtitles (`Hora, zona horaria, duración, narración, idioma`, `Método de acceso`, `Reporta un problema o envíanos tus comentarios`).
8. **Player**: `PLAYING YOUR BRIEFING` caps line, segmented tabs `En este episodio` / `Transcripción`, `Volver al audio` pill.

Table of strings flagged for truncation risk (sorted by Spanish/English length ratio; `lineLimit(2)` or fixed-width containers):

| English | Spanish | EN / ES chars | Ratio | Screen |
|---|---|---|---|---|
| Resume auto-scroll | Reanudar desplazamiento automático | 18 / 34 | 1.89 | Player |
| Mark read | Marcar como leído | 9 / 17 | 1.89 | News |
| Sign-in method | Método de inicio de sesión | 14 / 26 | 1.86 | Profile |
| Mark unread | Marcar como no leído | 11 / 20 | 1.82 | News |
| Mark all read | Marcar todo como leído | 13 / 22 | 1.69 | News |
| Home | Inicio | 4 / 6 | 1.5 | Shell/Home |
| Add selected | Agregar selección | 12 / 17 | 1.42 | Onboarding |
| Remind me before research starts | Avísame antes de que empiece la investigación | 32 / 45 | 1.41 | Profile |
| Ready at | Listo a las | 8 / 11 | 1.38 | Interests |
| A standing request matched — no episode covering it yet | Coincide con un pedido que ya sigues; todavía no hay episodio sobre esto | 55 / 72 | 1.31 | Search |
| Transcript | Transcripción | 10 / 13 | 1.3 | Player |
| Report a problem or send us feedback | Reporta un problema o envíanos tus comentarios | 36 / 46 | 1.28 | Profile |
| Add request | Agregar pedido | 11 / 14 | 1.27 | Home |
| Start tracking it regularly | Empezar a seguirlo con regularidad | 27 / 34 | 1.26 | Search |
| I'm done adding topics | Ya terminé de agregar temas | 22 / 27 | 1.23 | Onboarding |
| Add, remove or change anything | Agrega, quita o cambia lo que quieras | 30 / 37 | 1.23 | Interests |
| Not quite | No del todo | 9 / 11 | 1.22 | Feedback |
| Style | Estilo | 5 / 6 | 1.2 | Onboarding/Interests |
| e.g. Start with what it means for my savings | p. ej. Empieza por lo que significa para mis ahorros | 44 / 52 | 1.18 | Feedback |
| I'm done, skip the rest | Ya terminé, omitir el resto | 23 / 27 | 1.17 | Onboarding |
| %@ · password, terms, your data | %@ · contraseña, términos, tus datos | 31 / 36 | 1.16 | Profile |
| A short daily audio episode about only what you follow. | Un episodio de audio corto cada día, solo con lo que tú sigues. | 55 / 63 | 1.15 | Auth |
| PLAYING YOUR BRIEFING | REPRODUCIENDO TU RESUMEN | 21 / 24 | 1.14 | Player |
| Details | Detalles | 7 / 8 | 1.14 | Onboarding |
| Add a topic, team or question | Agrega un tema, equipo o pregunta | 29 / 33 | 1.14 | Interests |
| Start my Lucaku | Empezar mi Lucaku | 15 / 17 | 1.13 | Onboarding |
| By creating an account you agree to the Terms and Privacy Policy. Your topics are never sold or shared. | Al crear una cuenta aceptas los Términos y la Política de privacidad. Tus temas nunca se venden ni se comparten. | 103 / 112 | 1.09 | Auth |
| Search your episodes or a new topic | Busca en tus episodios o un tema nuevo | 35 / 38 | 1.09 | Search |
| Generate my episode now | Generar mi episodio ahora | 23 / 25 | 1.09 | Home |
| Time, time zone, length, narration, language | Hora, zona horaria, duración, narración, idioma | 44 / 47 | 1.07 | Profile |
| In this episode | En este episodio | 15 / 16 | 1.07 | Player |
| Generate one now | Generar uno ahora | 16 / 17 | 1.06 | Home |
| Something's wrong? Report a problem | ¿Algo no va bien? Reporta un problema | 35 / 37 | 1.06 | Feedback |
| Stop covering this topic | Dejar de cubrir este tema | 24 / 25 | 1.04 | Feedback |
| Appearance & notifications | Apariencia y notificaciones | 26 / 27 | 1.04 | Profile |
| %@ mode · notifications %@ · %@ | Modo %@ · notificaciones %@ · %@ | 31 / 32 | 1.03 | Profile |
| Not something you've asked about yet — start tracking it regularly | Aún no has preguntado por esto: empieza a seguirlo con regularidad | 66 / 66 | 1 | Search |
| Continue with Google | Continuar con Google | 20 / 20 | 1 | Auth |
| Interests | Intereses | 9 / 9 | 1 | Shell/Interests |
| Add or change something | Agregar o cambiar algo | 23 / 22 | 0.96 | Onboarding |
| Lucaku researches | Lucaku investiga | 17 / 16 | 0.94 | Interests |
| As long as it needs | Lo que haga falta | 19 / 17 | 0.89 | Onboarding |
| Delivery | Entrega | 8 / 7 | 0.88 | Onboarding/Profile |
| Topics | Temas | 6 / 5 | 0.83 | Onboarding |
| Request for today | Pedir para hoy | 17 / 14 | 0.82 | Home |
| Not relevant to me | No me interesa | 18 / 14 | 0.78 | Feedback |

Mitigations, in order of preference: shorten the Spanish (already done for the worst offenders), allow `lineLimit(2)` with `minimumScaleFactor(0.85)`, then give the container flexible height. Do not shrink fonts below the design minimum. Strings with no Spanish expansion problem (ratio 1.0 or lower) are listed too only because their containers are fixed-size.

## 9. Checklist: testing the Spanish UI on device

Set the in-app language to Español (Profile > Delivery & voice > Language), and also test the device in English with the app set to Español (and the reverse) to catch strings that follow the system instead of the app.

- [ ] Fresh install, device in English: signup screen, then change language and confirm the UI flips immediately without relaunch.
- [ ] Every tab: Inicio, Intereses, Perfil, and the Search screen. No English left. No raw keys (`%@`, `%lld`) visible.
- [ ] Onboarding chat end to end in Spanish: greeting with and without a name, topic entry by typing and by mic, "Ya terminé", suggestions, category flow, time ("6:45 a. m." and "18:30" typed), length, style, voice, summary, "Empezar mi Lucaku", error states ("Intentar de nuevo").
- [ ] Plural forms: 1 and 2+ for topics, stories, unread, minutes, notifications.
- [ ] Dates and times show `a. m.` / `p. m.`, Spanish weekday and month names, `jueves, 13 de noviembre`.
- [ ] Alerts and confirmation dialogs (Delete account, Change password, Problem reported, Couldn't listen): titles, messages, button labels (`Aceptar`, `Cancelar`, `Eliminar`).
- [ ] System permission prompts (microphone, speech) appear in Spanish (`InfoPlist.xcstrings`).
- [ ] Server messages: trigger a 400 (short request), a 401 (wrong password), a 503, a rate limit, and confirm they arrive in Spanish.
- [ ] VoiceOver in Spanish: tab bar, mini player, news row (`Sin leer. ...`), share, feedback chips, `Paso 2 de 4, Detalles`.
- [ ] Dynamic Type: default, Large and the biggest accessibility size on iPhone SE (small width) and Pro Max.
- [ ] Truncation: every row in the table in section 8, plus tab bar, onboarding chips, 54pt buttons, two-line subtitles, the share sheet (`Enviar con`), the notification cards.
- [ ] Dark mode and light mode (strings are the same; check wrapping at the card edges).
- [ ] Speech: dictation recognizes Spanish (es-CO or es-MX) and the synthesized/preview voice is Spanish.
- [ ] Share sheet message and the Messages/WhatsApp text are Spanish when the app is Spanish.
- [ ] Switching language mid-session: open Profile, flip to English and back; no stuck strings in cached view models (`homeBanner`, notification cards, toasts, alert text).
- [ ] Sign out and back in: the language persists from the profile.

## 10. Wording that needs native-speaker review

1. `Pedido` / `Pedir para hoy` / `Agregar pedido` for "request" (alternatives: `solicitud`, `petición`).
2. `No del todo` as the pair of `Útil` (alternative: `Podría mejorar`).
3. `Crear caso` for "Create ticket".
4. `Narrativo` vs `Historia` for the "Story" narration style.
5. `Noticia directa` for "Straight news" (alternative: `Solo noticias`).
6. `Listo a las` as the label for the "Ready at" tile (a time follows).
7. `¿Primera vez aquí?` (gender-neutral) vs `¿Eres nuevo?`: the catalog uses the neutral form.
8. Onboarding chat tone: `Toma como un minuto` (colloquial), `Armemos juntos` (inclusive "let's"). Check it does not feel too Mexican or too Colombian.
9. `Lo que haga falta` for "As long as it needs".
10. `Volver al audio` for "Resume auto-scroll".
11. Currency/time formats in the share and notification copy (es-CO vs es-MX).
12. The spoken intro/transition lines in `audio-copy.md` (they are read aloud by a TTS voice; check the rhythm out loud).
