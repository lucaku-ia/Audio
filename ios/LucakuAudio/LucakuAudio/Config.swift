import Foundation

/// App-wide configuration.
///
/// `apiBaseURL` points at the real, live Lucaku Audio backend on Railway
/// (see the root `README.md`'s "Current status" table: "Live in production
/// on Railway: https://audio-production-2a77.up.railway.app"). This is not a
/// placeholder — the whole point of this scaffold is a real request/response
/// round trip against the deployed FastAPI service, not a mock.
///
/// If that URL ever changes (a new Railway service, a custom domain, a
/// staging environment), update it here — this is the single source of
/// truth for the app's backend host.
enum Config {
    /// Where the app sends its requests.
    ///
    /// Production by default. A DEBUG build will instead use
    /// `LUCAKU_API_BASE_URL` from the environment when it is set, so the app
    /// can be pointed at a backend running on this machine:
    ///
    ///     SIMCTL_CHILD_LUCAKU_API_BASE_URL=http://127.0.0.1:8077 \
    ///       xcrun simctl launch --terminate-running-process \
    ///       booted com.lucaku.audio
    ///
    /// The `SIMCTL_CHILD_` prefix is not optional: anything written after the
    /// bundle id is passed to the app as a launch *argument*, not as an
    /// environment variable, so `simctl launch ... KEY=VALUE` silently leaves
    /// the app talking to production.
    ///
    /// This exists because the only way to exercise a failing backend from
    /// the app — the 503 path, a dropped connection, a slow response — is to
    /// run one you control. Release builds ignore the variable entirely, so
    /// no shipped app can be pointed somewhere else.
    static let apiBaseURL: URL = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["LUCAKU_API_BASE_URL"],
           let url = URL(string: override), url.scheme != nil {
            return url
        }
        #endif
        return URL(string: "https://audio-production-2a77.up.railway.app")!
    }()

    /// Every route in the backend is mounted under `/api` (see
    /// `backend/app/main.py`'s `app.include_router(..., prefix="/api")` calls).
    static let apiPrefix = "/api"

    // MARK: - TODO (needs product-owner action, see ios/LucakuAudio/README.md)
    //
    // Google Sign-In: needs a GIDClientID from a registered OAuth client in
    // Google Cloud Console. Not wired up here — see README "Wiring up Google
    // Sign-In later".
    //
    // Push notifications (APNs): needs an active Apple Developer Program
    // membership, an App ID with the Push Notifications capability, and a
    // provisioning profile that includes it. Not wired up here — see README
    // "Wiring up push notifications later".
}
