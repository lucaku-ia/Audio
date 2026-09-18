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
    static let apiBaseURL = URL(string: "https://audio-production-2a77.up.railway.app")!

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
