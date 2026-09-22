import Foundation

// Matches backend/app/api/routes/profile.py exactly (field names, types,
// optionality, enum values) — read directly from the route/model files, not
// guessed. Backing model: backend/app/models/profile.py (`Profile`,
// `NarrationStyle`, `Language`).

/// Mirrors `app.models.profile.NarrationStyle` — the only three values the
/// backend enum accepts.
enum NarrationStyle: String, Codable, CaseIterable, Identifiable {
    case news
    case story
    case casual

    var id: String { rawValue }

    /// Human-readable label — the backend only ever sees/returns the raw value.
    var displayName: String {
        switch self {
        case .news: return "News"
        case .story: return "Story"
        case .casual: return "Casual"
        }
    }
}

/// Mirrors `app.models.profile.Language`. Distinct from `SignupRequest`'s
/// free-form `idioma: String` (`"es" | "en"`) so this settings surface stays
/// tied to the same enum the backend validates PATCH bodies against.
enum ProfileLanguage: String, Codable, CaseIterable, Identifiable {
    case es
    case en

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .es: return "Español"
        case .en: return "English"
        }
    }
}

/// GET /api/profile response body (`ProfileOut` in profile.py).
struct ProfileOut: Decodable {
    let customerId: String
    let voiceId: String?
    let narrationStyle: NarrationStyle
    let language: ProfileLanguage
    /// "HH:MM" local time, or nil if never set.
    let deliveryTime: String?
    let deliveryTimezone: String
    /// nil = no limit (a ceiling, never a target — per the backend's own comment).
    let maxLengthMinutes: Int?
    // `signals` (completion/skip/rating, refinements, adoptions, dismissals) is
    // derived, never shown or edited here — deliberately not decoded.

    enum CodingKeys: String, CodingKey {
        case customerId = "customer_id"
        case voiceId = "voice_id"
        case narrationStyle = "narration_style"
        case language
        case deliveryTime = "delivery_time"
        case deliveryTimezone = "delivery_timezone"
        case maxLengthMinutes = "max_length_minutes"
    }
}

/// PUT /api/profile request body (`ProfileBody` in profile.py) — the
/// Onboarding-only full initial write (as opposed to `SettingsBody`'s partial
/// PATCH). Deliberately has no `language` field: language is copied from
/// `Cliente.idioma` server-side the first time this creates the row, per the
/// umbrella PRD rule "captured once, never asked again" — see profile.py's
/// module docstring.
struct ProfileSetupBody: Encodable {
    var voiceId: String?
    var narrationStyle: NarrationStyle = .news
    /// "HH:MM" local time.
    var deliveryTime: String?
    var deliveryTimezone: String = "America/Bogota"
    var maxLengthMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case voiceId = "voice_id"
        case narrationStyle = "narration_style"
        case deliveryTime = "delivery_time"
        case deliveryTimezone = "delivery_timezone"
        case maxLengthMinutes = "max_length_minutes"
    }
}

/// PATCH /api/profile request body (`SettingsBody` in profile.py). Every
/// field is optional — only properties actually set are encoded, since
/// Swift's synthesized `Encodable` uses `encodeIfPresent` for `Optional`
/// properties, matching the backend's `model_fields_set` partial-update
/// semantics (a field that's `nil` here is omitted from the JSON entirely,
/// not sent as `null`, except `clearMaxLength` which is never optional).
struct SettingsBody: Encodable {
    var voiceId: String?
    var narrationStyle: NarrationStyle?
    var language: ProfileLanguage?
    /// "HH:MM" local time.
    var deliveryTime: String?
    var deliveryTimezone: String?
    var maxLengthMinutes: Int?
    /// Explicit flag — the backend treats `maxLengthMinutes == nil` alone as
    /// "field not sent", so clearing an existing limit requires this.
    var clearMaxLength: Bool = false

    enum CodingKeys: String, CodingKey {
        case voiceId = "voice_id"
        case narrationStyle = "narration_style"
        case language
        case deliveryTime = "delivery_time"
        case deliveryTimezone = "delivery_timezone"
        case maxLengthMinutes = "max_length_minutes"
        case clearMaxLength = "clear_max_length"
    }
}

/// PATCH /api/profile response body (`SettingsOut` in profile.py) — the
/// updated profile plus one human-readable message per changed field,
/// stating when it applies (the PRD's "every change says when it applies,
/// never silence" tenet).
struct SettingsOut: Decodable {
    let customerId: String
    let voiceId: String?
    let narrationStyle: NarrationStyle
    let language: ProfileLanguage
    let deliveryTime: String?
    let deliveryTimezone: String
    let maxLengthMinutes: Int?
    let messages: [String]

    enum CodingKeys: String, CodingKey {
        case customerId = "customer_id"
        case voiceId = "voice_id"
        case narrationStyle = "narration_style"
        case language
        case deliveryTime = "delivery_time"
        case deliveryTimezone = "delivery_timezone"
        case maxLengthMinutes = "max_length_minutes"
        case messages
    }
}

/// DELETE /api/account response body (`{"deleted": true}` in account.py).
struct DeleteAccountResponse: Decodable {
    let deleted: Bool
}

// Note: GET /api/account/export (`AccountExportOut` in account.py) is
// intentionally NOT modeled field-by-field here. It's a deep export of every
// Request/RequestVersion/Episode/Block the customer has, whose only client
// use is "hand the user their raw data" (the PRD's "export (JSON of requests
// and episodes list)"), not to render — so `APIClient.exportAccountData`
// returns the raw `Data` for a share sheet instead of decoding it into
// structs nothing in this screen would otherwise use.
