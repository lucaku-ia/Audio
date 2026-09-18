import SwiftUI

/// A flat, tappable list row for one "answer block" — the core, most
/// load-bearing pattern in DESIGN_SPEC_V3.md: a list row, never a point on a
/// scrub bar. Mirrors player_v3.html's `.block-row` / `.block-row.playing`
/// exactly: the currently-playing row gets a tinted background, a leading
/// accent bar, an animated waveform glyph instead of an index number, a
/// semibold/upsized question, and its own sub-progress bar.
struct BlockRowView: View {
    let index: Int
    let block: BlockOut
    let isCurrent: Bool
    let isPlaying: Bool
    let progressFraction: Double
    let isNextUp: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: LucakuSpacing.sp3) {
                leading
                content
            }
            .padding(LucakuSpacing.sp3)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: LucakuRadius.row)
                    .fill(isCurrent ? LucakuColor.accentTint : Color.clear)
            )
            .overlay(alignment: .leading) {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(LucakuColor.accent)
                        .frame(width: 3)
                        .padding(.vertical, 2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var leading: some View {
        ZStack {
            if isCurrent {
                WaveformGlyph(isAnimating: isPlaying)
            } else {
                Text("\(index + 1)")
                    .font(LucakuTypography.subhead)
                    .foregroundStyle(LucakuColor.textTertiary)
                    .monospacedDigit()
            }
        }
        .frame(width: 28, height: 44)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(block.summary)
                .font(isCurrent ? LucakuTypography.headline : LucakuTypography.body)
                .foregroundStyle(LucakuColor.textPrimary)
                .multilineTextAlignment(.leading)

            HStack(spacing: 6) {
                if isCurrent {
                    Text(isPlaying ? "Playing" : "Paused")
                    Circle().fill(LucakuColor.textTertiary).frame(width: 3, height: 3)
                    Text("\(Int(progressFraction * Double(duration)).asMinutesSeconds) of \(duration.asMinutesSeconds)")
                } else if isNextUp {
                    Text("Up next")
                    Circle().fill(LucakuColor.textTertiary).frame(width: 3, height: 3)
                    Text(duration.asMinutesSeconds)
                } else {
                    Text(duration.asMinutesSeconds)
                }
            }
            .font(LucakuTypography.footnote)
            .foregroundStyle(LucakuColor.textSecondary)

            if isCurrent {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(LucakuColor.borderSoft)
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(LucakuColor.accent)
                                .frame(width: proxy.size.width * progressFraction, height: 3)
                        }
                }
                .frame(height: 3)
                .padding(.top, LucakuSpacing.sp2)
            }
        }
    }

    private var duration: Int { max(0, block.endS - block.startS) }
}

#Preview {
    VStack(spacing: 2) {
        BlockRowView(
            index: 0,
            block: BlockOut(
                requestId: nil, startS: 0, endS: 252,
                summary: "What's happening with the Fed's rate decision this week?",
                script: "", sources: [], hadMore: false
            ),
            isCurrent: true, isPlaying: true, progressFraction: 0.38, isNextUp: false, action: {}
        )
        BlockRowView(
            index: 1,
            block: BlockOut(
                requestId: nil, startS: 0, endS: 347,
                summary: "Catch me up on the OpenAI–Microsoft news",
                script: "", sources: [], hadMore: false
            ),
            isCurrent: false, isPlaying: false, progressFraction: 0, isNextUp: true, action: {}
        )
    }
    .padding()
    .background(LucakuColor.bg)
}
