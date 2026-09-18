import Foundation

// Matches backend/app/api/routes/generation.py's JobOut/EpisodeOut/BlockOut
// exactly.

struct JobOut: Decodable, Identifiable {
    let id: String
    let fecha: String // ISO date (YYYY-MM-DD)
    let path: String // "on_demand" | "scheduled"
    let status: String // queued | researching | writing | voicing | ready | late | empty | failed
    let creadoEn: Date
    /// Carries the {"error": ...} entry when status == "failed".
    let stages: [JSONValue]

    enum CodingKeys: String, CodingKey {
        case id, fecha, path, status
        case creadoEn = "creado_en"
        case stages
    }
}

struct BlockOut: Decodable, Identifiable {
    let requestId: String?
    let startS: Int
    let endS: Int
    let summary: String
    let script: String
    let sources: [JSONValue]
    let hadMore: Bool

    var id: String { "\(startS)-\(endS)" }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case startS = "start_s"
        case endS = "end_s"
        case summary, script, sources
        case hadMore = "had_more"
    }
}

struct EpisodeOut: Decodable, Identifiable {
    let id: String
    let fecha: String
    let headline: String?
    let language: String?
    let style: String?
    let voiceId: String?
    let durationS: Int?
    let audioUrl: String?
    let hadMoreAny: Bool
    let publishedAt: Date?
    let blocks: [BlockOut]

    enum CodingKeys: String, CodingKey {
        case id, fecha, headline, language, style
        case voiceId = "voice_id"
        case durationS = "duration_s"
        case audioUrl = "audio_url"
        case hadMoreAny = "had_more_any"
        case publishedAt = "published_at"
        case blocks
    }
}
