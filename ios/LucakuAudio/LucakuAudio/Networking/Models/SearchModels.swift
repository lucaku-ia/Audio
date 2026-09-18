import Foundation

// Matches backend/app/api/routes/search.py exactly.

struct HistoryEntryOut: Decodable, Identifiable {
    let episodeId: String?
    let fecha: String
    let headline: String
    let durationS: Int?
    let style: String?
    /// None for a synthesized "No news" entry.
    let path: String?
    /// "ready" | "voicing" | "empty"
    let state: String

    var id: String { episodeId ?? fecha }

    enum CodingKeys: String, CodingKey {
        case episodeId = "episode_id"
        case fecha, headline
        case durationS = "duration_s"
        case style, path, state
    }
}

struct HistoryOut: Decodable {
    let items: [HistoryEntryOut]
    let offset: Int
    let limit: Int
    let total: Int
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case items, offset, limit, total
        case hasMore = "has_more"
    }
}

struct MatchedBlockOut: Decodable, Identifiable {
    let blockId: String
    let startS: Int
    let snippet: String

    var id: String { blockId }

    enum CodingKeys: String, CodingKey {
        case blockId = "block_id"
        case startS = "start_s"
        case snippet
    }
}

struct RequestTextMatchOut: Decodable, Identifiable {
    let requestId: String
    let blockId: String?
    let snippet: String

    var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case blockId = "block_id"
        case snippet
    }
}

struct EpisodeMatchOut: Decodable, Identifiable {
    let episodeId: String
    let fecha: String
    let headline: String?
    let path: String
    let headlineMatch: Bool
    let headlineSnippet: String?
    let matchedBlocks: [MatchedBlockOut]
    let matchedRequestTexts: [RequestTextMatchOut]

    var id: String { episodeId }

    enum CodingKeys: String, CodingKey {
        case episodeId = "episode_id"
        case fecha, headline, path
        case headlineMatch = "headline_match"
        case headlineSnippet = "headline_snippet"
        case matchedBlocks = "matched_blocks"
        case matchedRequestTexts = "matched_request_texts"
    }
}

struct UnmatchedRequestOut: Decodable, Identifiable {
    let requestId: String
    let snippet: String
    let status: String

    var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case snippet, status
    }
}

struct SearchOut: Decodable {
    let query: String
    let tookMs: Double
    let episodes: [EpisodeMatchOut]
    let unmatchedRequests: [UnmatchedRequestOut]

    enum CodingKeys: String, CodingKey {
        case query
        case tookMs = "took_ms"
        case episodes
        case unmatchedRequests = "unmatched_requests"
    }
}

// MARK: - "Add as a new interest" (backend/app/api/routes/requests.py)
//
// There is no dedicated interests-management endpoint (no POST
// /interests). What the Search mockup calls "adding a new interest" is,
// on the real backend, creating a standing Request — the same object
// Home's own "Your interests" section is ultimately built from
// (OnboardingState.selected_interests + standing Requests are what the
// Generator researches on a recurring cadence; see requests.py's
// CrearRequestBody and RequestKind.standing). `CreatedFrom.search` is a
// real, already-existing enum value on the backend specifically for this
// case — nothing here is invented to make the UI look wired up.

/// Matches backend/app/api/routes/requests.py's `CrearRequestBody`.
struct CreateRequestBody: Encodable {
    let rawText: String
    /// "standing" | "one_off" — Search's "Add as a new interest" always
    /// creates a standing request (tracked going forward), matching the
    /// mockup's "start tracking it regularly" copy.
    let kind: String
    /// "onboarding" | "interests" | "suggestion" | "search" | "home_empty_day"
    let createdFrom: String

    enum CodingKeys: String, CodingKey {
        case rawText = "raw_text"
        case kind
        case createdFrom = "created_from"
    }
}
