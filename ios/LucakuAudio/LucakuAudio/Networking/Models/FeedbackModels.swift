import Foundation

// Matches backend/app/api/routes/feedback.py (POST /feedback, GET /feedback,
// POST /feedback/report).

struct FeedbackBody: Encodable {
    let targetType: String
    let targetId: String
    /// "useful" | "not_quite"
    let rating: String
    let reasons: [String]
    let suggestion: String?

    enum CodingKeys: String, CodingKey {
        case targetType = "target_type"
        case targetId = "target_id"
        case rating, reasons, suggestion
    }
}

struct FeedbackOut: Decodable {
    let targetType: String
    let targetId: String
    let rating: String
    let reasons: [String]
    let suggestion: String?

    enum CodingKeys: String, CodingKey {
        case targetType = "target_type"
        case targetId = "target_id"
        case rating, reasons, suggestion
    }
}

struct FeedbackResult: Decodable {
    /// True when the identical resend toggled the rating off.
    let removed: Bool
    let feedback: FeedbackOut?
}

struct FeedbackReportBody: Encodable {
    let targetType: String
    let targetId: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case targetType = "target_type"
        case targetId = "target_id"
        case text
    }
}

struct FeedbackReportOut: Decodable {
    let id: String
}

/// What the feedback is about; raw values are the backend's `target_type`.
enum FeedbackTarget: String {
    case story, episode, news
}

enum FeedbackMapping {
    /// UI labels of `FeedbackSheet.options` -> backend reason codes.
    static let reasonCodes: [String: String] = [
        "Too long": "too_long",
        "Too short": "too_short",
        "Not relevant to me": "not_relevant",
        "Needs more detail": "needs_more_detail",
        "Too technical": "too_technical",
        "Stop covering this topic": "stop_topic",
    ]

    static func codes(for labels: [String]) -> [String] {
        labels.compactMap { reasonCodes[$0] }
    }

    /// Empty/blank suggestions are omitted (the backend stores null).
    static func suggestion(_ text: String?) -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The backend requires UUID target ids; sample/local ids are skipped.
    static func isSendable(_ id: String) -> Bool { UUID(uuidString: id) != nil }
}

/// The payload the server currently holds for a target: re-sending it exactly
/// is how a rating is toggled off.
struct SavedFeedback: Equatable {
    let rating: String
    let reasons: [String]
    let suggestion: String?
}
