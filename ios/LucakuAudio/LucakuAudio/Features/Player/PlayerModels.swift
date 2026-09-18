import Foundation

// MARK: - Playback speed

/// Stepped speed selector per DESIGN_SPEC_V3.md ("Speed / tuning controls") —
/// a fixed set of steps, never a continuous slider.
enum PlaybackSpeed: Double, CaseIterable, Identifiable {
    case oneX = 1.0
    case onePoint25 = 1.25
    case onePoint5 = 1.5
    case onePoint75 = 1.75
    case twoX = 2.0

    var id: Double { rawValue }

    /// e.g. "1×", "1.25×" — matches player_v3.html's `speed-step` labels.
    var label: String {
        if rawValue == rawValue.rounded() {
            return "\(Int(rawValue))\u{00D7}"
        }
        return "\(rawValue)\u{00D7}"
    }
}

// MARK: - Answer rating (thumbs up/down)

/// Local-only UI state for the "Was this answer useful?" control in the
/// tuning sheet. NOTE: the backend has no feedback/rating endpoint yet
/// (nothing in backend/app/api/routes/generation.py or search.py persists
/// this), so this is intentionally not wired to the network — it only
/// reflects a picked state in this session, matching the mockup's cosmetic
/// behavior. Flag for a follow-up once a rating endpoint exists.
enum AnswerRating: Equatable {
    case up
    case down
}

// MARK: - Duration formatting

extension Int {
    /// Formats a second count as "m:ss" (e.g. 98 -> "1:38"), matching the
    /// mockup's `block-meta` / `np-times` time strings.
    var asMinutesSeconds: String {
        let minutes = self / 60
        let seconds = self % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension Double {
    var asMinutesSeconds: String { Int(self.rounded()).asMinutesSeconds }
}

// MARK: - Transcript (mocked highlight state)

/// A single displayable transcript line, derived client-side from
/// `BlockOut.script` by splitting on sentence boundaries.
///
/// IMPORTANT GAP: the backend (backend/app/api/routes/generation.py's
/// `BlockOut`) exposes only a flat `script: String` per block — there is no
/// word-level or sentence-level timing/timestamp data anywhere in the API.
/// True karaoke-style word highlighting synced to audio is therefore not
/// possible against the real backend today. What follows is a clearly-marked
/// PROPORTIONAL MOCK: sentences are marked played/active/upcoming based on
/// what fraction of the block's declared duration has elapsed, purely for
/// visual demonstration of the pattern described in DESIGN_SPEC_V3.md's
/// "Transcript" section. This should be replaced once (if) the backend adds
/// per-word or per-sentence timestamps.
struct TranscriptLine: Identifiable {
    enum State {
        case played, active, upcoming
    }

    let id: Int
    let text: String
    let state: State
    /// Only set when `state == .active` — the mock "currently spoken word",
    /// which is just the first word of the active sentence (see gap note
    /// above; there is no real per-word timing to derive this from).
    let mockCurrentWord: String?

    static func mockLines(script: String, progressFraction: Double) -> [TranscriptLine] {
        guard !script.isEmpty else { return [] }

        // Naive sentence split — good enough for a client-side visual mock,
        // not a real NLP boundary detector.
        let sentences = script
            .components(separatedBy: CharacterSet(charactersIn: "."))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0 + "." }

        guard !sentences.isEmpty else { return [] }

        let clamped = min(max(progressFraction, 0), 1)
        let activeIndex = min(sentences.count - 1, Int(clamped * Double(sentences.count)))

        return sentences.enumerated().map { index, sentence in
            let state: State = index < activeIndex ? .played : (index == activeIndex ? .active : .upcoming)
            let firstWord = state == .active ? sentence.split(separator: " ").first.map(String.init) : nil
            return TranscriptLine(id: index, text: sentence, state: state, mockCurrentWord: firstWord)
        }
    }
}
