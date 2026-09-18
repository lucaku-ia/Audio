import SwiftUI

/// Transcript panel — player_v3.html's `.np-transcript-card`. Word/phrase
/// highlight state here is a PROPORTIONAL MOCK (see `TranscriptLine`'s doc
/// comment for why: the backend's `BlockOut.script` has no timing data at
/// all). Auto-scroll follows the active line; a manual scroll pauses
/// auto-scroll and reveals a "Resume" pill, per DESIGN_SPEC_V3.md's
/// "Transcript" section. Every line is independently tappable to seek —
/// implemented here as a seek within the simulated block progress (see
/// PlayerViewModel's class doc on the UI-only transport).
struct TranscriptPanelView: View {
    @ObservedObject var viewModel: PlayerViewModel

    @State private var autoScrollPaused = false

    private var lines: [TranscriptLine] {
        guard let block = viewModel.currentBlock else { return [] }
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
            let fraction = Double(line.id) / Double(max(1, lines.count - 1))
            viewModel.seekWithinBlock(fraction: fraction)
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

        guard line.state == .active, let word = line.mockCurrentWord, line.text.hasPrefix(word) else {
            return Text(line.text).foregroundColor(color)
        }

        // A true pill-shaped background swatch (matching player_v3.html's
        // `.w-current`) isn't achievable per-run inside a concatenated
        // `Text`; bold + accent color communicates the same "currently
        // spoken word" emphasis.
        let remainder = String(line.text.dropFirst(word.count))
        return Text(word).fontWeight(.semibold).foregroundColor(LucakuColor.accent)
            + Text(remainder).foregroundColor(color)
    }
}
