import Foundation

// Matches backend/app/api/routes/home.py's HomeOut/BannerOut/RecentEpisodeOut/
// SharedInventoryOut exactly.

struct BannerOut: Decodable {
    /// "ready" | "making" | "late" | "empty_day" | "re_entry"
    let state: String
    let headline: String?
    /// ready: number of answered requests (blocks). making/late: requests in progress.
    let requestsCount: Int?
    let durationS: Int?
    let style: String?
    /// making/late only.
    let eta: Date?

    enum CodingKeys: String, CodingKey {
        case state, headline
        case requestsCount = "requests_count"
        case durationS = "duration_s"
        case style, eta
    }
}

struct RecentEpisodeOut: Decodable, Identifiable {
    let date: String // backend sends a plain ISO "date" (YYYY-MM-DD), not a datetime
    let headline: String?
    let durationS: Int?
    let style: String?
    /// "completed" | "no_news"
    let state: String

    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date, headline
        case durationS = "duration_s"
        case style, state
    }
}

struct SharedInventoryOut: Decodable, Identifiable {
    let episodeId: String
    let headline: String?
    let durationS: Int?
    let style: String?
    /// e.g. "Because you follow technology"
    let reason: String

    var id: String { episodeId }

    enum CodingKeys: String, CodingKey {
        case episodeId = "episode_id"
        case headline
        case durationS = "duration_s"
        case style, reason
    }
}

struct HomeOut: Decodable {
    let banner: BannerOut
    let recent: [RecentEpisodeOut]
    /// Always empty today — Home's "suggestions" needs the AI Platform's
    /// shared semantic index, which the backend does not have yet (see
    /// home.py's module docstring). Decoded as `[JSONValue]` rather than a
    /// concrete type since the backend itself has not settled its shape.
    let suggestions: [JSONValue]
    let sharedInventory: [SharedInventoryOut]

    enum CodingKeys: String, CodingKey {
        case banner, recent, suggestions
        case sharedInventory = "shared_inventory"
    }
}

struct RequestTodayBody: Encodable {
    let rawText: String

    enum CodingKeys: String, CodingKey {
        case rawText = "raw_text"
    }
}

/// Matches backend/app/api/routes/requests.py's RequestOut — returned by
/// POST /api/home/request-today (a thin wrapper over POST /requests).
struct RequestOut: Decodable {
    let id: String
    let kind: String
    let rawText: String
    let status: String
    let createdFrom: String
    let lastAnsweredAt: Date?
    let fulfilledEpisodeId: String?
    let creadoEn: Date

    enum CodingKeys: String, CodingKey {
        case id, kind
        case rawText = "raw_text"
        case status
        case createdFrom = "created_from"
        case lastAnsweredAt = "last_answered_at"
        case fulfilledEpisodeId = "fulfilled_episode_id"
        case creadoEn = "creado_en"
    }
}

/// A tiny catch-all for backend JSON shapes this scaffold does not need to
/// interpret yet (e.g. Home's still-empty `suggestions` list). Deliberately
/// minimal — this app has no use for arbitrary JSON beyond "decode without
/// crashing and ignore."
enum JSONValue: Decodable {
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else {
            // Anything present in `suggestions` today would be unexpected
            // (the backend always returns an empty list); swallow it rather
            // than fail the whole Home decode over a field this scaffold
            // doesn't render.
            self = .null
        }
    }
}
