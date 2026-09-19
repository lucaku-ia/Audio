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
    /// ready only — per-block breakdown of today's episode, in playback
    /// order. Empty (default) for every other banner state. See
    /// BlockSummaryOut's docstring.
    let blocks: [BlockSummaryOut]
    /// ready only — today's episode id, so Home can tell "the shared player is
    /// playing today's episode" apart from "playing a sample / a past day".
    let episodeId: String?

    enum CodingKeys: String, CodingKey {
        case state, headline
        case requestsCount = "requests_count"
        case durationS = "duration_s"
        case style, eta, blocks
        case episodeId = "episode_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(String.self, forKey: .state)
        headline = try container.decodeIfPresent(String.self, forKey: .headline)
        requestsCount = try container.decodeIfPresent(Int.self, forKey: .requestsCount)
        durationS = try container.decodeIfPresent(Int.self, forKey: .durationS)
        style = try container.decodeIfPresent(String.self, forKey: .style)
        eta = try container.decodeIfPresent(Date.self, forKey: .eta)
        // Older/other banner states omit `blocks` entirely rather than send
        // `[]` — decode defensively so those states don't fail the whole
        // Home load.
        blocks = try container.decodeIfPresent([BlockSummaryOut].self, forKey: .blocks) ?? []
        episodeId = try container.decodeIfPresent(String.self, forKey: .episodeId)
    }
}

/// Per-block breakdown for the ready episode's banner — matches backend/app/
/// api/routes/home.py's `BlockSummaryOut` exactly (added alongside the
/// existing aggregate headline/duration_s/requests_count fields). This is
/// what lets Home render one real row per topic instead of a single
/// synthesized "whole episode" row (see HomeView.swift).
struct BlockSummaryOut: Decodable, Identifiable {
    let id: String
    /// nil = intro/outro block (not tied to a customer request).
    let requestId: String?
    /// 0-based position in playback order (== this array's own order).
    let sequence: Int
    let startS: Int
    let endS: Int
    let durationS: Int
    /// The one-line topic/question text for this block (backend field name
    /// is `summary`, not `topic`).
    let summary: String
    let hadMore: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case requestId = "request_id"
        case sequence
        case startS = "start_s"
        case endS = "end_s"
        case durationS = "duration_s"
        case summary
        case hadMore = "had_more"
    }
}

struct RecentEpisodeOut: Decodable, Identifiable {
    let date: String // backend sends a plain ISO "date" (YYYY-MM-DD), not a datetime
    let headline: String?
    let durationS: Int?
    let style: String?
    /// "completed" | "no_news"
    let state: String
    /// nil for a synthesized "no news that day" entry — nothing to play.
    let episodeId: String?

    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date, headline
        case durationS = "duration_s"
        case style, state
        case episodeId = "episode_id"
    }
}

struct SharedInventoryOut: Decodable, Identifiable {
    let episodeId: String
    let headline: String?
    let durationS: Int?
    let style: String?
    /// e.g. "Because you follow technology"
    let reason: String
    /// The interest tag this sample belongs to (e.g. "technology").
    let tag: String?

    var id: String { episodeId }

    enum CodingKeys: String, CodingKey {
        case episodeId = "episode_id"
        case headline
        case durationS = "duration_s"
        case style, reason, tag
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
    /// Shared samples for topics the customer does NOT follow yet — Home's
    /// "Explore" shelf. Honestly labelled as exploration, never as a match.
    let explore: [SharedInventoryOut]

    enum CodingKeys: String, CodingKey {
        case banner, recent, suggestions
        case sharedInventory = "shared_inventory"
        case explore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        banner = try container.decode(BannerOut.self, forKey: .banner)
        recent = try container.decode([RecentEpisodeOut].self, forKey: .recent)
        suggestions = try container.decodeIfPresent([JSONValue].self, forKey: .suggestions) ?? []
        sharedInventory = try container.decodeIfPresent([SharedInventoryOut].self, forKey: .sharedInventory) ?? []
        explore = try container.decodeIfPresent([SharedInventoryOut].self, forKey: .explore) ?? []
    }
}

struct RequestTodayBody: Encodable {
    let rawText: String

    enum CodingKeys: String, CodingKey {
        case rawText = "raw_text"
    }
}

/// {topic, scope, geography, depth} — `ai_platform.structure_request`'s
/// output, stored on `Request.structured` and now exposed on `RequestOut`.
/// Every `Request` that exists has one: a rejected structuring attempt
/// never creates a row (see requests.py's `_structure_or_reject`), so this
/// is never optional/partial on a real request.
struct RequestStructured: Decodable, Equatable {
    let topic: String
    let scope: String
    let geography: String?
    let depth: String
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
    let structured: RequestStructured

    enum CodingKeys: String, CodingKey {
        case id, kind
        case rawText = "raw_text"
        case status
        case createdFrom = "created_from"
        case lastAnsweredAt = "last_answered_at"
        case fulfilledEpisodeId = "fulfilled_episode_id"
        case creadoEn = "creado_en"
        case structured
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
