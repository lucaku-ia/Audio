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
        return trimmed.isEmpty ? nil : String(trimmed.prefix(2000)) // backend max_length
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

extension SavedFeedback {
    init(_ out: FeedbackOut) {
        self.init(rating: out.rating, reasons: out.reasons, suggestion: out.suggestion)
    }
}

/// Serialises rating writes per target id.
///
/// One request is in flight per id; taps made meanwhile coalesce into the
/// latest intent that runs right after it. A stale response never reaches the
/// UI, a failure restores the last state the server confirmed (and only when
/// no newer tap is waiting), and setting a rating is idempotent: the backend
/// toggles an identical resend off, so a `removed` answer to a "set" is
/// re-posted once.
@MainActor
final class FeedbackSyncQueue {
    enum Intent {
        case set(FeedbackBody)
        /// Clears the rating; `fallback` is only used when the server state is unknown.
        case clear(fallback: FeedbackBody?)
    }

    /// Called with the confirmed server state (nil = no rating) for an id.
    private let targetType: FeedbackTarget
    private let onState: (String, SavedFeedback?) -> Void
    private var pending: [String: (intent: Intent, token: String)] = [:]
    private var running: Set<String> = []
    private var saved: [String: SavedFeedback] = [:]
    /// Ids whose `saved` entry is confirmed by the server (response or GET).
    private var known: Set<String> = []
    private var epoch = 0

    init(targetType: FeedbackTarget, onState: @escaping (String, SavedFeedback?) -> Void) {
        self.targetType = targetType
        self.onState = onState
    }

    func set(id: String, body: FeedbackBody, token: String) {
        enqueue(id, .set(body), token)
    }

    func clear(id: String, fallback: FeedbackBody?, token: String) {
        enqueue(id, .clear(fallback: fallback), token)
    }

    /// Adopts saved state fetched with GET /feedback for ids with no activity.
    func adopt(ids: [String], items: [FeedbackOut]) {
        let byId = Dictionary(items.map { ($0.targetId, $0) }, uniquingKeysWith: { first, _ in first })
        for id in ids where pending[id] == nil && !running.contains(id) && !known.contains(id) {
            known.insert(id)
            saved[id] = byId[id].map(SavedFeedback.init)
            onState(id, saved[id])
        }
    }

    /// Drops all state (sign-out); in-flight responses are ignored.
    func reset() {
        epoch += 1
        pending = [:]
        running = []
        saved = [:]
        known = []
    }

    private func enqueue(_ id: String, _ intent: Intent, _ token: String) {
        pending[id] = (intent, token)
        guard !running.contains(id) else { return }
        running.insert(id)
        let myEpoch = epoch
        Task {
            while let next = pending.removeValue(forKey: id) {
                let result = await perform(next.intent, id: id, token: next.token)
                guard myEpoch == epoch else { return }
                switch result {
                case .success(let state):
                    saved[id] = state.value
                    known.insert(id)
                    if pending[id] == nil { onState(id, state.value) }
                case .failure:
                    if pending[id] == nil {
                        onState(id, known.contains(id) ? saved[id] : nil)
                    }
                }
            }
            running.remove(id)
        }
    }

    /// Wraps an optional so "skipped" (nil) differs from "server says no rating".
    private struct State { let value: SavedFeedback? }

    private func perform(_ intent: Intent, id: String, token: String) async -> Result<State, Error> {
        do {
            switch intent {
            case .set(let body):
                var result = try await APIClient.shared.submitFeedback(body, token: token)
                if result.removed { result = try await APIClient.shared.submitFeedback(body, token: token) }
                return .success(State(value: result.feedback.map(SavedFeedback.init)))
            case .clear(let fallback):
                let body: FeedbackBody?
                if known.contains(id) {
                    body = saved[id].map { FeedbackBody(targetType: targetType.rawValue, targetId: id, rating: $0.rating, reasons: $0.reasons, suggestion: $0.suggestion) }
                } else {
                    body = fallback
                }
                // Nothing rated on the server: nothing to clear.
                guard let body else { return .success(State(value: nil)) }
                let result = try await APIClient.shared.submitFeedback(body, token: token)
                return .success(State(value: result.removed ? nil : result.feedback.map(SavedFeedback.init)))
            }
        } catch {
            return .failure(error)
        }
    }
}
