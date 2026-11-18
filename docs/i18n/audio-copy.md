# Lucaku Audio: spoken copy and bilingual server messages

Proposal for the backend and audio team. Spanish is neutral Latin American, `tú`, warm and short (see README section 5). The lines are meant to be read aloud by a TTS voice: short sentences, no abbreviations, no symbols, numbers as words where it matters.

Placeholders: `{name}` is the first name; `{n}` is a number of stories; `{topic}` is a topic label.

## 1. Personal intro lines

Pick the greeting by the listener's local hour (same cut-offs as the app: 05:00-11:59 morning, 12:00-17:59 afternoon, otherwise evening), then add one intro line. If the name is unknown, use the `no name` variant (never say "null" or "friend").

### Spanish (es)

| # | With name | No name |
|---|---|---|
| 1 | Buenos días, {name}. Esto es lo que pasó mientras dormías. | Buenos días. Esto es lo que pasó mientras dormías. |
| 2 | Buenos días, {name}. Empecemos con lo importante. | Buenos días. Empecemos con lo importante. |
| 3 | Buenas tardes, {name}. Te pongo al día en pocos minutos. | Buenas tardes. Te pongo al día en pocos minutos. |
| 4 | Buenas tardes, {name}. Esto es lo que te interesa hoy. | Buenas tardes. Esto es lo que te interesa hoy. |
| 5 | Buenas noches, {name}. Cerremos el día con lo que importa. | Buenas noches. Cerremos el día con lo que importa. |
| 6 | Hola, {name}. Tu episodio de hoy ya está listo. | Hola. Tu episodio de hoy ya está listo. |
| 7 | Hola, {name}. Hoy tenemos {n} noticias para ti. | Hola. Hoy tenemos {n} noticias para ti. |
| 8 | {name}, qué bueno tenerte por aquí. Vamos con las noticias. | Qué bueno tenerte por aquí. Vamos con las noticias. |
| 9 | Buenos días, {name}. Tus temas, contados a tu manera. | Buenos días. Tus temas, contados a tu manera. |
| 10 | Hola, {name}. Solo lo que sigues, sin vueltas. | Hola. Solo lo que sigues, sin vueltas. |

Greeting-less variants 6 to 10 may be used at any hour. For lines 1 to 5 and 9, swap the greeting word to match the hour. If `{n}` is 1, say "una noticia".

### English (en)

| # | With name | No name |
|---|---|---|
| 1 | Good morning, {name}. Here is what happened while you slept. | Good morning. Here is what happened while you slept. |
| 2 | Good morning, {name}. Let's start with what matters. | Good morning. Let's start with what matters. |
| 3 | Good afternoon, {name}. Here is your catch-up, in a few minutes. | Good afternoon. Here is your catch-up, in a few minutes. |
| 4 | Good afternoon, {name}. Here is what you care about today. | Good afternoon. Here is what you care about today. |
| 5 | Good evening, {name}. Let's close the day with what matters. | Good evening. Let's close the day with what matters. |
| 6 | Hi {name}. Your episode for today is ready. | Hi. Your episode for today is ready. |
| 7 | Hi {name}. We have {n} stories for you today. | Hi. We have {n} stories for you today. |
| 8 | {name}, good to have you here. Let's get to the news. | Good to have you here. Let's get to the news. |
| 9 | Good morning, {name}. Your topics, told your way. | Good morning. Your topics, told your way. |
| 10 | Hi {name}. Only what you follow, nothing else. | Hi. Only what you follow, nothing else. |

If `{n}` is 1, say "one story".

## 2. Transition lines between capsules (segments)

Spoken between two segments of the episode. Keep each under two seconds. Vary them; do not repeat the same one twice in a row. "Capsule" is `cápsula` in Spanish and is internal vocabulary: listeners hear "next story / siguiente noticia".

### Spanish (es)

1. Pasemos a lo siguiente.
2. Ahora, otra noticia.
3. Cambiamos de tema.
4. Seguimos.
5. Y ahora, esto.
6. Una más para ti.
7. Vamos con la siguiente.
8. Mientras tanto, en otro frente.
9. Ahora, algo de lo que sigues.
10. Y para cerrar este bloque, una última.

### English (en)

1. Let's move on.
2. Now, another story.
3. Switching topics.
4. Moving on.
5. And now, this.
6. One more for you.
7. On to the next one.
8. Meanwhile, on another front.
9. Now, something you follow.
10. And to wrap up this part, one last story.

Closing line (optional, last capsule): es "Eso es todo por hoy. Nos escuchamos mañana." / en "That's all for today. Talk to you tomorrow."

## 3. Server-originated messages that must exist in both languages

The app shows `detail` from 4xx and 503 responses verbatim (`ios/.../Networking/APIError.swift`, 4xx/503 pass-through). Today they are all English. Recommended contract:

- The client sends `Accept-Language: es` or `en` (from the single app language; the server falls back to `profile.language`, then `cliente.idioma`).
- The server returns `{"detail": "<localized text>", "code": "<stable_code>"}`. The client may map `code` to its own catalog string and use `detail` as fallback.

Messages found in `backend/app/api/routes/*.py` and `backend/app/main.py` (read-only review). Code names are proposed (they do not exist in the code yet); the source location is where the English string lives today.

| Proposed code | Source | English | Spanish |
|---|---|---|---|
| `model_unavailable` | `main.py` (503 handler `ModelUnavailable`) | I could not reach the model just now. Try that again in a moment. | No pude conectarme en este momento. Inténtalo de nuevo en un momento. |
| `invalid_credentials` | `auth.py:87` | Incorrect credentials | Correo o contraseña incorrectos. |
| `email_exists_other_provider` | `auth.py:60` | This email already has an account using the '{provider}' method. Sign in with that method instead. | Este correo ya tiene una cuenta con el método '{provider}'. Inicia sesión con ese método. |
| `wrong_signin_method` | `auth.py:95` | This account signs in with '{provider}', not email and password. | Esta cuenta inicia sesión con '{provider}', no con correo y contraseña. |
| `too_many_attempts` | `auth.py:103` | Too many attempts. Try again in {seconds} seconds. | Demasiados intentos. Inténtalo de nuevo en {seconds} segundos. |
| `job_not_found` | `generation.py:143` | Job not found | No encontramos esa generación. |
| `no_episode_yet` | `generation.py:176` | No episode yet | Aún no hay episodio. |
| `episode_not_found` | `generation.py:196`, `requests.py:485` | Episode not found | No encontramos ese episodio. |
| `news_item_not_found` | `news.py:186` | News item not found | No encontramos esa noticia. |
| `invalid_cursor` | `news.py:94` | Invalid cursor | No pudimos cargar más noticias. Actualiza e inténtalo de nuevo. |
| `request_too_short` | `requests.py:114` | This request is too short to research anything from. | Este pedido es muy corto para investigar algo. Cuéntanos un poco más. |
| `request_not_researchable` | `requests.py:127` | This request can't be researched as written. (the AI `rejected_reason` is appended and must also come in the user's language) | Este pedido no se puede investigar como está escrito. |
| `request_not_found` | `requests.py:137` | Request not found | No encontramos ese pedido. |
| `block_not_found` | `requests.py:354` | Block not found for this request/episode | No encontramos esa noticia en este episodio. |
| `profile_not_ready` | `profile.py:120,201` | Profile not set up yet (Onboarding incomplete) | Tu perfil aún no está listo. Termina primero la configuración inicial. |
| `unknown_timezone` | `profile.py:227` | Unknown timezone: {tz} | No reconocemos esa zona horaria. |
| `no_settings_provided` | `profile.py:243` | No settings fields were provided. | No enviaste ningún cambio. |
| `need_one_request` | `onboarding.py:340,400` | At least one standing request is required before confirming. | Necesitas al menos un tema para continuar. |
| `need_delivery_time` | `onboarding.py:344` | Set a delivery time first before confirming. | Elige primero una hora de entrega. |
| `unknown_interest` | `onboarding.py:262,285` | Unknown interest | No reconocemos ese interés. |
| `validation_*` | FastAPI 422 | (client-humanized today) | Localized client-side: see README section 4.1. |
| `generic_server_error` | any 5xx | Something went wrong on our side. Try again in a moment. | Algo falló de nuestro lado. Inténtalo de nuevo en un momento. |

`internal.py` messages (`Unknown tag`, `slot must be one of`) are internal and need no translation.

### Messages that do not exist yet but should (found no matching code)

I searched the routes and services for a budget cap, a kill switch and a pause message and found none surfaced to users. What exists: `NEWS_DAILY_COST_CEILING_USD` and `NEWS_SCHEDULER_ENABLED` (`core/config.py`, `services/scheduler.py`) which silently stop the news pipeline; `JobStatus.failed` is deliberately mapped to banner state `making` (`home.py` around line 238); banner states `ready`, `late`, `making`, `re_entry`, `empty_day`; and `RequestStatus.paused` (`requests.py:390`). If these should be visible to users, the proposed copy is:

| Proposed code | When | English | Spanish |
|---|---|---|---|
| `budget_exceeded` | Daily cost ceiling reached | We've reached today's limit for new research. Your news is still here, and new episodes start again tomorrow. | Llegamos al límite de investigación de hoy. Tus noticias siguen aquí y los episodios nuevos vuelven mañana. |
| `service_paused` | Kill switch / scheduler disabled | Lucaku is taking a short break. Your news is safe, and we'll be back soon. | Lucaku está en una pausa breve. Tus noticias están a salvo y volvemos pronto. |
| `generation_failed` | Job failed (instead of silently showing "making") | We couldn't finish your episode this time. We'll try again shortly. | No pudimos terminar tu episodio esta vez. Lo intentaremos de nuevo en un momento. |
| `empty_day` | No news for the user's topics (banner `empty_day`, episode state `no_news`) | Nothing new for your topics today. Your next episode arrives tomorrow. | Hoy no hay nada nuevo en tus temas. Tu próximo episodio llega mañana. |
| `request_paused` | A request was paused (`request_paused` event) | We paused this topic. You can turn it back on anytime. | Pausamos este tema. Puedes reactivarlo cuando quieras. |
| `audio_not_ready` | Episode has no audio yet | The audio isn't ready yet. Check back shortly. | El audio aún no está listo. Vuelve en un momento. |
| `rate_limited` | Generic rate limit | You're going a little fast. Try again in a moment. | Vas muy rápido. Inténtalo de nuevo en un momento. |

Banner state labels (`ready`, `late`, `making`, `re_entry`, `empty_day`) are state codes, not text; the app maps them to localized copy (see the `Home` keys in `Localizable.xcstrings`).

### Language of generated content

Episode scripts, voices and news are generated per `profile.language` (`episode_generator.py:755` already reads it; line 1074 hard-codes `idioma="es"` in one place and should be checked). The intro and transition lines above should be picked by the same language and synthesized with a voice of that language (Valentina / Andrés need Spanish and English voice ids, or one multilingual voice).
