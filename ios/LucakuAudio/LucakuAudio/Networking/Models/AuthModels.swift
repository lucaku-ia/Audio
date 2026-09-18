import Foundation

// Matches backend/app/api/routes/auth.py exactly (field names, types,
// optionality) — read directly from the route file, not guessed.

struct SignupRequest: Encodable {
    let email: String
    let password: String
    let nombre: String
    let idioma: String // "es" | "en" — backend pattern "^(es|en)$", default "es"
}

/// POST /api/auth/login is NOT JSON — it's `OAuth2PasswordRequestForm`
/// (FastAPI's standard form-encoded username/password), so there is no
/// Encodable request struct for it; `APIClient.login` builds the
/// `application/x-www-form-urlencoded` body directly.
struct TokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    /// The client routes on this: false -> Onboarding, true -> Home.
    /// (Onboarding itself is out of scope for this scaffold — see README.)
    let onboardingComplete: Bool

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case onboardingComplete = "onboarding_complete"
    }
}

struct MeResponse: Decodable {
    let id: String
    let email: String
    let nombre: String
    let idioma: String
    let authProvider: String
    let onboardingComplete: Bool

    enum CodingKeys: String, CodingKey {
        case id, email, nombre, idioma
        case authProvider = "auth_provider"
        case onboardingComplete = "onboarding_complete"
    }
}
