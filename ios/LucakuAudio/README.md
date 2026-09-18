# Lucaku Audio — iOS app scaffold

This is the **first client/mobile code** for Lucaku Audio. The backend
(`../../backend`) is fully built and live on Railway; nothing here existed
before this scaffold. Its job is to prove **real data flowing end to end** —
sign up, hit the real production API, decode real responses, render them —
not to look good. Visual design is being handled separately from HTML
mockups; don't try to match that pixel-for-pixel here yet.

## What's real

- **A real Xcode project** (`LucakuAudio.xcodeproj`), SwiftUI lifecycle,
  targeting iOS 17+, Swift 5.0 language mode with async/await concurrency —
  no completion-handler networking anywhere.
- **`APIClient`** (`LucakuAudio/Networking/APIClient.swift`): a `URLSession`
  + async/await networking actor that calls the real, deployed backend at
  `https://audio-production-2a77.up.railway.app` (see `Config.swift` —
  `apiBaseURL`). This URL is not a placeholder: it's the exact address in
  the backend repo's root `README.md` ("Live in production on Railway").
- **Codable models** (`LucakuAudio/Networking/Models/*.swift`) that mirror
  the backend's actual Pydantic response/request schemas field-for-field —
  read directly from `backend/app/api/routes/{auth,home,generation,search}.py`,
  not guessed. Field names, optionality, and enum-ish string values (e.g.
  `BannerOut.state` being one of `ready|making|late|empty_day|re_entry`) all
  match the route files as of this scaffold's creation. If those routes
  change shape later, these models will need updating to match — they are
  not auto-generated from an OpenAPI schema (see "Next steps" below).
- **Auth**: email+password signup/login/logout/me against
  `POST /api/auth/signup`, `POST /api/auth/login` (note: this one is
  `application/x-www-form-urlencoded`, FastAPI's `OAuth2PasswordRequestForm`
  — not JSON, unlike every other endpoint here), `POST /api/auth/logout`,
  `GET /api/auth/me`. The bearer token is stored in the Keychain
  (`Session/SessionStore.swift`) and attached as `Authorization: Bearer
  <token>` on every authenticated call.
- **Home tab**: calls the real `GET /api/home` and renders the actual
  banner state, recent episodes, and shared-inventory items it gets back.
  When the banner is `empty_day`, it shows a text field wired to the real
  `POST /api/home/request-today`.
- **Library tab**: calls the real `GET /api/search/history` and
  `GET /api/search/query`, plus a "Generate today's episode now" button
  wired to the real `POST /api/generation/run` (the on-demand Episode
  Generator path — this can take a while server-side since it runs the
  whole research → write → voice pipeline synchronously; the button shows a
  spinner and says so).
- **Settings tab**: calls the real `GET /api/auth/me` and has a working
  "Sign Out" that calls `POST /api/auth/logout` and clears the local
  session.
- **Loading/error states**: every screen shows a plain `ProgressView` while
  a request is in flight and a plain error message (from
  `APIError.errorDescription`, which unwraps FastAPI's `{"detail": "..."}`
  error bodies) on failure, with a manual retry button. This is intentionally
  unstyled — proving the request/decode path works, not polishing it.

## What's stubbed / not built

- **Onboarding.** The backend has a whole Onboarding flow
  (`backend/app/api/routes/onboarding.py`); this scaffold's login always
  routes into the same three-tab shell regardless of `onboarding_complete`.
  A real client would branch on that flag (the backend's `TokenResponse`
  already returns it) into an Onboarding flow before Home. Not built here —
  out of scope for "prove the API surface works."
- **Player.** There is no playback UI anywhere in this scaffold (nor in the
  backend — see the backend README's status table: "Player — Not started").
  `EpisodeOut`/`BlockOut` models exist and `GET /api/generation/episodes/latest`
  is wired into `APIClient`, but nothing calls it from a screen yet.
- **Settings CRUD.** The backend has `PATCH /api/profile` (voice, narration
  style, delivery time, max length) and `GET /api/account/export` /
  `DELETE /api/account`. The Settings tab only reads `GET /api/auth/me` and
  signs out — none of the mutation endpoints are wired to UI yet.
- **Google/Apple Sign-In and push notifications** — see the two sections
  below. Both need credentials only the product owner can create.
- **Token refresh.** The backend's JWT has no refresh endpoint (see
  `backend/app/core/security.py`) — `create_access_token` just issues a
  token with `ACCESS_TOKEN_EXPIRE_DAYS` and `logout` invalidates every
  outstanding token by bumping `token_version`. This scaffold does not
  attempt silent re-auth on a 401; it surfaces `APIError.notAuthenticated`
  and the user has to log in again.

## Opening and running the project

1. You need a full Xcode install (Xcode 15 or later; the project targets
   iOS 17+, Swift 5.0 language mode / Swift 6 concurrency-ready code). This
   scaffold was written on a machine with only the Command Line Tools
   installed, **so it could not be opened in Xcode or run in Simulator here
   — build/run verification is still needed on a machine with full Xcode**
   (see "Build verification" below for exactly what was and wasn't checked).
2. Open `ios/LucakuAudio/LucakuAudio.xcodeproj` in Xcode.
3. Pick any iOS 17+ Simulator (e.g. iPhone 16) as the run destination and hit
   Run. No signing/provisioning changes should be needed for the Simulator —
   `CODE_SIGN_STYLE` is `Automatic` and `PRODUCT_BUNDLE_IDENTIFIER` is
   `com.lucaku.audio` (change this before shipping to a real device or the
   App Store if that identifier isn't registered to the team).
4. On first launch you'll land on the login screen (no stored session). Use
   "Sign Up" to create a real account against the live backend, or "Log In"
   if you already have one. From there the three tabs (Home / Library /
   Settings) call the real API.

### Build verification

`xcodebuild -project LucakuAudio.xcodeproj -scheme LucakuAudio -destination
'platform=iOS Simulator,name=iPhone 16' build` could **not** be run in this
environment — only Xcode's Command Line Tools are installed, not the full
Xcode app (`xcodebuild -version` and the iOS Simulator both refused to run
and pointed at `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
after installing Xcode, which needs the product owner's own machine access).
What *was* verified here instead, by hand:

- `project.pbxproj` parses as a valid property list (`plutil -lint`) and
  every file/group reference in it resolves to a real object with no
  dangling IDs (checked programmatically against the parsed JSON form).
- Every `.swift` file was manually reviewed for brace balance, correct
  `Codable`/`CodingKeys` mapping against the actual backend schemas, correct
  actor-isolation usage (`APIClient` as an `actor`, `SessionStore` and the
  view models as `@MainActor`), and the imports each file actually needs
  (e.g. `Session/SessionStore.swift` needs `import Security` for the
  Keychain calls — easy to miss, added deliberately).
- The file tree on disk matches the project's file manifest exactly (no
  orphaned files, nothing referenced that doesn't exist).

**This is not a substitute for a real build.** The first thing to do with
this scaffold on a machine with full Xcode installed is exactly that
`xcodebuild` command (or just hitting Run in Xcode) — treat any compiler
error that turns up as expected first-pass fallout from writing Swift
without a compiler in the loop, not a sign the approach is wrong.

## Wiring up Google Sign-In later

Not attempted here — it needs credentials only the product owner can create:

1. Create an OAuth 2.0 Client ID (iOS application type) in
   [Google Cloud Console](https://console.cloud.google.com/apis/credentials),
   under the project that will own this app's identity.
2. Add the **GoogleSignIn-iOS** Swift Package
   (`https://github.com/google/GoogleSignIn-iOS`) via Xcode's Swift Package
   Manager integration (File → Add Package Dependencies).
3. Add the resulting `GIDClientID` (from step 1) to `Info.plist`, plus the
   reversed-client-ID URL scheme Google's setup docs specify, so the OAuth
   redirect can come back into the app.
4. Call `GIDSignIn.sharedInstance.signIn(...)` from a new button on
   `LoginView`, get the resulting ID token, and send it to the backend.
   **Note**: the backend doesn't have a Google OAuth callback endpoint yet
   either — `Cliente.auth_provider` already supports the value (see
   `backend/app/api/routes/auth.py`'s module docstring: "Google and Apple
   are out of scope for this first cut... each one's callback endpoint is
   still missing") but nothing server-side accepts a Google token today.
   That backend endpoint has to exist before this client step is useful.

## Wiring up push notifications later

Not attempted here — it needs an active Apple Developer Program membership
and credentials only the product owner can create:

1. Enroll in the Apple Developer Program (or use an existing membership) —
   required for any push entitlement, Simulator can't fully test real APNs
   delivery anyway.
2. In the App ID's configuration (Apple Developer portal → Certificates,
   Identifiers & Profiles), enable the **Push Notifications** capability for
   `com.lucaku.audio` (or whatever bundle ID ships), and add the matching
   entitlement (`aps-environment`) to the Xcode target's Signing &
   Capabilities tab — this also requires a provisioning profile that
   includes the capability, which Xcode can usually regenerate automatically
   once the App ID has it enabled.
3. Request notification permission at runtime
   (`UNUserNotificationCenter.requestAuthorization`) and register for remote
   notifications (`UIApplication.registerForRemoteNotifications`), then send
   the resulting device token to the backend so it has somewhere to deliver
   to.
   **Note**: the backend doesn't have a device-token endpoint or an APNs
   sender yet either — see the backend README's "Notifications & Settings
   scope" section: "Push notification delivery (APNs/FCM) — needs an
   Apple/Google push provider credential that doesn't exist in this repo."
   That's also a product-owner-gated step (an APNs auth key from the
   Developer portal), separate from the push *capability* above.

## Next steps for whoever picks this up

- Generate models from the backend's own OpenAPI schema
  (`https://audio-production-2a77.up.railway.app/docs` /
  `/openapi.json`) instead of hand-mirroring route files, once the API
  surface stabilizes — hand-written Codable structs like these will silently
  drift from the backend if a route's response model changes and nobody
  updates both sides.
- Wire Onboarding, Player, and Settings CRUD screens against the backend
  routes that already exist for them (see "What's stubbed" above).
- Get this project opened and built in real Xcode (see "Build verification"
  above) — that's the very next thing to do, before anything else lands on
  top of this scaffold.
