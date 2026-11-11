import SwiftUI

/// Karaoke-style transcript (screens spec 4.4). Highlight state is REAL,
/// word-timestamp-based (`TranscriptLine.realLines`) when the current block's
/// `BlockOut.wordTimestamps` is present, and falls back to the proportional
/// mock (`TranscriptLine.mockLines`) otherwise — that fallback is required.
///
/// The line being read is highlighted and followed; the spoken word is the
/// accent colour. Tapping a line seeks to it. If the user scrolls, auto-follow
/// stops and "Resume auto-scroll" appears (4.6).
struct TranscriptPanelView: View {
    @ObservedObject var viewModel: PlayerViewModel
    let theme: PlayerTheme

    @State private var autoScrollPaused = false

    private var lines: [TranscriptLine] {
        guard let block = viewModel.currentBlock else { return [] }
        if let wordTimestamps = block.wordTimestamps, !wordTimestamps.isEmpty {
            return TranscriptLine.realLines(
                wordTimestamps: wordTimestamps, blockStartS: block.startS,
                currentTime: viewModel.currentTime
            )
        }
        return TranscriptLine.mockLines(script: block.script, progressFraction: viewModel.currentBlockProgressFraction)
    }

    var body: some View {
        VStack(spacing: 0) {
            if autoScrollPaused {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(LucakuMotion.house) { autoScrollPaused = false }
                    } label: {
                        Text("Resume auto-scroll")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.buttonFg)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(Capsule().fill(theme.buttonBg))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            if lines.isEmpty {
                Text("No transcript available for this story yet.")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.fg3)
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(lines) { line in
                                transcriptLine(line)
                                    .id(line.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 20)
                    }
                    .frame(height: 360)
                    .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in autoScrollPaused = true })
                    .onChange(of: lines.first(where: { $0.state == .active })?.id) { _, activeId in
                        guard !autoScrollPaused, let activeId else { return }
                        withAnimation(LucakuMotion.house) { proxy.scrollTo(activeId, anchor: .center) }
                    }
                    .onChange(of: autoScrollPaused) { _, paused in
                        guard !paused, let active = lines.first(where: { $0.state == .active }) else { return }
                        withAnimation(LucakuMotion.house) { proxy.scrollTo(active.id, anchor: .center) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(theme.transcriptCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func transcriptLine(_ line: TranscriptLine) -> some View {
        Button {
            guard !lines.isEmpty else { return }
            autoScrollPaused = false
            if let startS = line.blockRelativeStartS, viewModel.currentBlockDurationS > 0 {
                // Real timestamps: seek exactly to this line's first word.
                viewModel.seekWithinBlock(fraction: startS / Double(viewModel.currentBlockDurationS))
            } else {
                // Mock fallback: no per-line timing, split the block evenly.
                viewModel.seekWithinBlock(fraction: Double(line.id) / Double(max(1, lines.count - 1)))
            }
        } label: {
            lineText(line)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.2)
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func lineText(_ line: TranscriptLine) -> Text {
        let color: Color = {
            switch line.state {
            case .played: return theme.playedLine
            case .active: return theme.fg
            case .upcoming: return theme.upcomingLine
            }
        }()

        // Real per-word timestamps: the spoken word can be anywhere in the
        // sentence, so build the line word-by-word.
        if let words = line.words {
            return words.enumerated().map { index, word -> Text in
                let isActive = line.state == .active && index == line.activeWordIndex
                let run = Text(word).foregroundColor(isActive ? LucakuColor.accent : color)
                return index == 0 ? run : Text(" ") + run
            }.reduce(Text(""), +)
        }

        // Mock fallback: the spoken word is always the sentence's first word.
        guard line.state == .active, let word = line.activeWord, line.text.hasPrefix(word) else {
            return Text(line.text).foregroundColor(color)
        }
        return Text(word).foregroundColor(LucakuColor.accent)
            + Text(String(line.text.dropFirst(word.count))).foregroundColor(color)
    }
}
