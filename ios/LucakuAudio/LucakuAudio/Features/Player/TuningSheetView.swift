import SwiftUI

/// Speed & tuning bottom sheet — player_v3.html's `.sheet`. Reached one tap
/// deeper than primary transport, per DESIGN_SPEC_V3.md's "all tuning
/// controls live behind a secondary affordance" rule.
///
/// WHAT'S REAL VS MOCKED HERE:
/// - Speed stepping updates `PlayerViewModel.speed`, which the (simulated)
///   elapsed-time timer actually reads and applies — real within this
///   scaffold's UI-only transport.
/// - "Clearer voice" / "Skip silence" toggle local `@Published` booleans only.
///   There's no audio-processing pipeline in this app (nor an endpoint for
///   it in backend/app/api/routes/*.py) — flipping them changes no actual
///   audio behavior. Named-by-benefit per spec, not exposed as a raw
///   parameter, but genuinely inert pending a real audio engine.
/// - "Refine this answer" / "Ask a follow-up" / thumbs up-down are UI hooks
///   only (no backend endpoint exists for refine/follow-up/rating today) —
///   intentionally left as TODOs rather than faked network calls.
struct TuningSheetView: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(LucakuColor.border)
                .frame(width: 36, height: 5)
                .padding(.top, LucakuSpacing.sp1)
                .padding(.bottom, LucakuSpacing.sp4)

            Text("Speed & tuning")
                .font(LucakuTypography.title3)
                .foregroundStyle(LucakuColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, LucakuSpacing.sp4)

            speedControl
                .padding(.bottom, LucakuSpacing.sp6)

            toggleRow(
                title: "Clearer voice", detail: "Levels and sharpens speech",
                isOn: $viewModel.clearerVoiceEnabled, isFirst: true
            )
            toggleRow(
                title: "Skip silence", detail: "Trims dead air between sentences",
                isOn: $viewModel.skipSilenceEnabled, isFirst: false
            )

            Divider().overlay(LucakuColor.borderSoft).padding(.vertical, LucakuSpacing.sp4)

            actionRow(icon: "pencil", title: "Refine this answer")
            actionRow(icon: "arrowshape.turn.up.left", title: "Ask a follow-up")

            rateRow
        }
        .padding(.horizontal, LucakuSpacing.sp4)
        .padding(.bottom, LucakuSpacing.sp6)
        .background(LucakuColor.surface)
        .clipShape(RoundedCorner(radius: LucakuRadius.sheet, corners: [.topLeft, .topRight]))
    }

    private var speedControl: some View {
        VStack(spacing: LucakuSpacing.sp3) {
            VStack(spacing: 0) {
                Button {
                    withAnimation(LucakuMotion.house) { viewModel.resetSpeedToOne() }
                } label: {
                    Text(viewModel.speed.label)
                        .font(LucakuTypography.title1)
                        .fontWeight(.bold)
                        .foregroundStyle(LucakuColor.accent)
                        .monospacedDigit()
                        .frame(minHeight: 44)
                }
                Text("Tap to reset to 1\u{00D7}")
                    .font(LucakuTypography.caption1)
                    .foregroundStyle(LucakuColor.textTertiary)
            }

            HStack(spacing: LucakuSpacing.sp2) {
                ForEach(PlaybackSpeed.allCases) { step in
                    Button {
                        withAnimation(LucakuMotion.house) { viewModel.speed = step }
                    } label: {
                        Text(step.label)
                            .font(LucakuTypography.subhead)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(step == viewModel.speed ? LucakuColor.accentOn : LucakuColor.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: LucakuRadius.chip)
                                    .fill(step == viewModel.speed ? LucakuColor.accent : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: LucakuRadius.chip)
                                    .stroke(step == viewModel.speed ? Color.clear : LucakuColor.borderSoft, lineWidth: 1)
                            )
                    }
                }
            }
        }
    }

    private func toggleRow(title: String, detail: String, isOn: Binding<Bool>, isFirst: Bool) -> some View {
        VStack(spacing: 0) {
            if !isFirst {
                Divider().overlay(LucakuColor.borderSoft)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(LucakuTypography.body).foregroundStyle(LucakuColor.textPrimary)
                    Text(detail).font(LucakuTypography.footnote).foregroundStyle(LucakuColor.textSecondary)
                }
                Spacer()
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .tint(LucakuColor.accent)
            }
            .padding(.vertical, LucakuSpacing.sp3)
        }
    }

    private func actionRow(icon: String, title: String) -> some View {
        Button {
            // TODO: wire once a refine/follow-up endpoint exists server-side.
        } label: {
            HStack(spacing: LucakuSpacing.sp3) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .frame(width: 20)
                Text(title)
                    .font(LucakuTypography.body)
                    .foregroundStyle(LucakuColor.textPrimary)
                Spacer()
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    private var rateRow: some View {
        HStack {
            Text("Was this answer useful?")
                .font(LucakuTypography.subhead)
                .foregroundStyle(LucakuColor.textSecondary)
            Spacer()
            HStack(spacing: LucakuSpacing.sp2) {
                rateButton(icon: "hand.thumbsup", rating: .up)
                rateButton(icon: "hand.thumbsdown", rating: .down)
            }
        }
        .padding(.top, LucakuSpacing.sp3)
    }

    private func rateButton(icon: String, rating: AnswerRating) -> some View {
        Button {
            withAnimation(LucakuMotion.house) { viewModel.rating = rating }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(viewModel.rating == rating ? LucakuColor.accent : LucakuColor.textSecondary)
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(viewModel.rating == rating ? LucakuColor.accentTintStrong : Color.clear)
                )
        }
    }
}

/// Rounds only the given corners — SwiftUI has no built-in "top corners
/// only" radius modifier, needed for the sheet's `r-sheet r-sheet 0 0` shape.
struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}
