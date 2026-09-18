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

// MARK: - Transcript (real timestamp highlight, with mocked fallback)

/// A single displayable transcript line, derived client-side either from
/// real per-word timing (`realLines`, backed by `BlockOut.wordTimestamps`)
/// or — when a block has no timing data yet — from a proportional mock over
/// `BlockOut.script` (`mockLines`).
struct TranscriptLine: Identifiable {
    enum State {
        case played, active, upcoming
    }

    let id: Int
    let text: String
    let state: State
    /// Only set when `state == .active` — the currently-spoken word to bold
    /// within `text`. Real when built via `realLines`; a same-shaped
    /// approximation (the sentence's first word) when built via `mockLines`.
    let activeWord: String?
    /// Individual word tokens making up `text`, in order — only populated by
    /// `realLines`. Lets the view bold the exact active word wherever it
    /// falls in the sentence (`activeWordIndex`), rather than `mockLines`'
    /// simpler "active word is always the first word" shape, for which a
    /// prefix check on `text` is enough.
    let words: [String]?
    /// Index into `words` of the currently-spoken word, only set alongside
    /// `words` when `state == .active`.
    let activeWordIndex: Int?
    /// Block-relative seconds at which this line starts, when known from
    /// real word timestamps — lets tap-to-seek land exactly on the line
    /// instead of the coarse `id / count` fraction `mockLines` requires.
    let blockRelativeStartS: Double?

    /// Real, timestamp-based lines from `BlockOut.wordTimestamps` (see that
    /// property's doc and PR #15's integration note). `currentTime` is the
    /// ABSOLUTE playback position in seconds — i.e. into the whole episode's
    /// `audio_url`, matching `AudioPlayerService.currentTime` — since each
    /// word's own `startS`/`endS` is block-relative, `blockStartS` recovers
    /// the absolute window: `blockStartS + word.startS ..< blockStartS + word.endS`.
    ///
    /// Sentences are grouped the same way `mockLines` splits `script` (on
    /// ".", "!", "?") so switching between the real and mock path doesn't
    /// visibly reflow the transcript.
    static func realLines(wordTimestamps: [WordTimestamp], blockStartS: Int, currentTime: Double) -> [TranscriptLine] {
        guard !wordTimestamps.isEmpty else { return [] }

        var sentenceRanges: [Range<Int>] = []
        var start = 0
        for (index, word) in wordTimestamps.enumerated() {
            if let last = word.word.last, ".!?".contains(last) {
                sentenceRanges.append(start..<(index + 1))
                start = index + 1
            }
        }
        if start < wordTimestamps.count {
            sentenceRanges.append(start..<wordTimestamps.count)
        }
        guard !sentenceRanges.isEmpty else { return [] }

        func absoluteWindow(_ word: WordTimestamp) -> (start: Double, end: Double) {
            (Double(blockStartS) + word.startS, Double(blockStartS) + word.endS)
        }

        let activeWordIndex = wordTimestamps.firstIndex { word in
            let window = absoluteWindow(word)
            return currentTime >= window.start && currentTime < window.end
        }

        return sentenceRanges.enumerated().map { lineIndex, range in
            let words = wordTimestamps[range]
            let text = words.map(\.word).joined(separator: " ")
            let sentenceStart = absoluteWindow(words[range.lowerBound]).start
            let sentenceEnd = absoluteWindow(words[range.upperBound - 1]).end

            let state: State
            if currentTime < sentenceStart {
                state = .upcoming
            } else if currentTime >= sentenceEnd {
                state = .played
            } else {
                state = .active
            }

            var activeWord: String?
            var localActiveWordIndex: Int?
            if state == .active, let activeWordIndex, range.contains(activeWordIndex) {
                activeWord = wordTimestamps[activeWordIndex].word
                localActiveWordIndex = activeWordIndex - range.lowerBound
            }

            return TranscriptLine(
                id: lineIndex, text: text, state: state, activeWord: activeWord,
                words: words.map(\.word), activeWordIndex: localActiveWordIndex,
                blockRelativeStartS: words[range.lowerBound].startS
            )
        }
    }

    /// PROPORTIONAL MOCK, kept as the fallback for blocks whose
    /// `wordTimestamps` is `null` (not synthesized with ElevenLabs
    /// timestamps yet — see `BlockOut.wordTimestamps`'s doc). Sentences are
    /// marked played/active/upcoming based on what fraction of the block's
    /// declared duration has elapsed; there is no real per-word timing to
    /// derive `activeWord` from, so it's approximated as the active
    /// sentence's first word.
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
            return TranscriptLine(
                id: index, text: sentence, state: state, activeWord: firstWord,
                words: nil, activeWordIndex: nil, blockRelativeStartS: nil
            )
        }
    }
}
