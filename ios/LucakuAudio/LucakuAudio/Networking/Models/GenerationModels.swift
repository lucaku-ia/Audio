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

/// A single word's timing within a block's own audio, as synthesized by
/// ElevenLabs (see backend/app/models/episode.py's `Block.word_timestamps`
/// docstring and backend/app/api/routes/generation.py's `BlockOut`).
/// `startS`/`endS` here are BLOCK-RELATIVE — per PR #15's own integration
/// note, the absolute highlight window against the episode's single
/// `audio_url` (and against `AudioPlayerService.currentTime`, which is
/// episode-relative) is `block.startS + word.startS ..< block.startS + word.endS`.
struct WordTimestamp: Decodable, Equatable {
    let word: String
    let startS: Double
    let endS: Double

    enum CodingKeys: String, CodingKey {
        case word
        case startS = "start_s"
        case endS = "end_s"
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
    /// Null when this block's audio wasn't synthesized with ElevenLabs
    /// timestamps (TTS not configured, or the block predates this field) —
    /// callers must fall back to the proportional mock highlight in that
    /// case (see `TranscriptLine.mockLines`), per PR #15's integration note.
    let wordTimestamps: [WordTimestamp]?

    var id: String { "\(startS)-\(endS)" }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case startS = "start_s"
        case endS = "end_s"
        case summary, script, sources
        case hadMore = "had_more"
        case wordTimestamps = "word_timestamps"
    }

    /// Memberwise init with `wordTimestamps` defaulted to `nil` — Decodable's
    /// synthesized init already treats a missing/null JSON key this way; this
    /// mirrors that for the previews/tests that construct a `BlockOut`
    /// directly and predate this field.
    init(
        requestId: String?, startS: Int, endS: Int, summary: String, script: String,
        sources: [JSONValue], hadMore: Bool, wordTimestamps: [WordTimestamp]? = nil
    ) {
        self.requestId = requestId
        self.startS = startS
        self.endS = endS
        self.summary = summary
        self.script = script
        self.sources = sources
        self.hadMore = hadMore
        self.wordTimestamps = wordTimestamps
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
