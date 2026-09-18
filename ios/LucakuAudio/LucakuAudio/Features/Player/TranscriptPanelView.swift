import SwiftUI

/// Transcript panel — player_v3.html's `.np-transcript-card`. Highlight
/// state is REAL, word-timestamp-based (`TranscriptLine.realLines`) when the
/// current block's `BlockOut.wordTimestamps` is present; it falls back to
/// the PROPORTIONAL MOCK (`TranscriptLine.mockLines`) for blocks that
/// weren't synthesized with ElevenLabs timestamps — see `wordTimestamps`'s
/// doc and PR #15's integration note (this fallback is required, not
/// optional). Auto-scroll follows the active line; a manual scroll pauses
/// auto-scroll and reveals a "Resume" pill, per DESIGN_SPEC_V3.md's
/// "Transcript" section. Every line is independently tappable to seek —
/// exact (to the line's first word) when real timestamps are available,
/// otherwise an even split across lines within the current block's real
/// progress (see PlayerViewModel's class doc — `currentTime` reads straight
/// off the real `AudioPlayerService`, no fake timer involved).
struct TranscriptPanelView: View {
    @ObservedObject var viewModel: PlayerViewModel

    @State private var autoScrollPaused = false

    private var lines: [TranscriptLine] {
        guard let block = viewModel.currentBlock else { return [] }
        if let wordTimestamps = block.wordTimestamps, !wordTimestamps.isEmpty {
            // `viewModel.currentTime` is the real, absolute (episode-wide)
            // playback position straight off `AudioPlayerService.currentTime`
            // — exactly the frame `realLines`/`WordTimestamp` expect, now
            // that the audio engine (PR #20) and transcript sync (PR #21)
            // are wired together instead of #21's placeholder derivation
            // from the old fake per-block timer.
            return TranscriptLine.realLines(
                wordTimestamps: wordTimestamps, blockStartS: block.startS,
                currentTime: viewModel.currentTime
            )
        }
        return TranscriptLine.mockLines(script: block.script, progressFraction: viewModel.currentBlockProgressFraction)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TRANSCRIPT")
                    .font(LucakuTypography.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(LucakuColor.textTertiary)
                    .tracking(0.4)

                Spacer()

                if autoScrollPaused {
                    Button {
                        withAnimation(LucakuMotion.house) { autoScrollPaused = false }
                    } label: {
                        Text("Auto-scroll paused · Resume")
                            .font(LucakuTypography.caption1)
                            .fontWeight(.semibold)
                            .foregroundStyle(LucakuColor.accentOn)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(LucakuColor.accent, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, LucakuSpacing.sp4)
            .padding(.top, LucakuSpacing.sp3)
            .padding(.bottom, LucakuSpacing.sp2)

            if lines.isEmpty {
                Spacer()
                Text("No transcript available for this answer yet.")
                    .font(LucakuTypography.subhead)
                    .foregroundStyle(LucakuColor.textTertiary)
                    .padding()
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(lines) { line in
                                transcriptLine(line)
                                    .id(line.id)
                            }
                        }
                        .padding(.horizontal, LucakuSpacing.sp4)
                        .padding(.bottom, LucakuSpacing.sp6)
                    }
                    .simultaneousGesture(DragGesture().onChanged { _ in autoScrollPaused = true })
                    .onChange(of: viewModel.currentBlockProgressFraction) { _, _ in
                        guard !autoScrollPaused, let active = lines.first(where: { $0.state == .active }) else { return }
                        withAnimation(LucakuMotion.house) { proxy.scrollTo(active.id, anchor: .center) }
                    }
                    .onChange(of: autoScrollPaused) { _, paused in
                        guard !paused, let active = lines.first(where: { $0.state == .active }) else { return }
                        withAnimation(LucakuMotion.house) { proxy.scrollTo(active.id, anchor: .center) }
                    }
                }
            }
        }
        .background(LucakuColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: LucakuRadius.sheet))
    }

    @ViewBuilder
    private func transcriptLine(_ line: TranscriptLine) -> some View {
        Button {
            guard !lines.isEmpty else { return }
            if let startS = line.blockRelativeStartS, viewModel.currentBlockDurationS > 0 {
                // Real timestamps: seek exactly to this line's first word.
                viewModel.seekWithinBlock(fraction: startS / Double(viewModel.currentBlockDurationS))
            } else {
                // Mock fallback: no per-line timing, split the block evenly.
                let fraction = Double(line.id) / Double(max(1, lines.count - 1))
                viewModel.seekWithinBlock(fraction: fraction)
            }
        } label: {
            lineText(line)
                .font(LucakuTypography.body)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, LucakuSpacing.sp2)
                .padding(.horizontal, LucakuSpacing.sp2)
                .background(
                    RoundedRectangle(cornerRadius: LucakuRadius.row)
                        .fill(line.state == .active ? Color.gray.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func lineText(_ line: TranscriptLine) -> Text {
        let color: Color = {
            switch line.state {
            case .played: return LucakuColor.textSecondary
            case .active: return LucakuColor.textPrimary
            case .upcoming: return LucakuColor.textTertiary
            }
        }()

        // A true pill-shaped background swatch (matching player_v3.html's
        // `.w-current`) isn't achievable per-run inside a concatenated
        // `Text`; bold + accent color communicates the same "currently
        // spoken word" emphasis.

        // Real per-word timestamps: the active word can be anywhere in the
        // sentence, so build the line word-by-word rather than relying on a
        // prefix match.
        if let words = line.words {
            return words.enumerated().map { index, word -> Text in
                let isActive = line.state == .active && index == line.activeWordIndex
                var run = Text(word).foregroundColor(isActive ? LucakuColor.accent : color)
                if isActive { run = run.fontWeight(.semibold) }
                return index == 0 ? run : Text(" ") + run
            }.reduce(Text(""), +)
        }

        // Mock fallback: the active word is always the sentence's first
        // word, so a prefix check is enough.
        guard line.state == .active, let word = line.activeWord, line.text.hasPrefix(word) else {
            return Text(line.text).foregroundColor(color)
        }
        let remainder = String(line.text.dropFirst(word.count))
        return Text(word).fontWeight(.semibold).foregroundColor(LucakuColor.accent)
            + Text(remainder).foregroundColor(color)
    }
}
