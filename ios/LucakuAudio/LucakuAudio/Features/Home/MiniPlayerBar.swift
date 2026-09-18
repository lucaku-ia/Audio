import SwiftUI

/// The persistent mini-player bar — DESIGN_SPEC_V3.md's "Mini-player /
/// persistent playback" section: a single global overlay, mounted once above
/// the tab bar, surviving navigation across all tabs. Opaque surface (never
/// translucent/glass — that treatment is reserved for the Now Playing
/// ambient backdrop only, per the spec's Materials section).
///
/// TODO(app-shell): this component is fully styled and ready, but today's
/// scope is the Home screen only — there is no shared PlayerStore /
/// app-wide playback engine yet. When the Player epic lands, this view
/// should be hoisted out of HomeView and mounted exactly once, likely as a
/// `.safeAreaInset(edge: .bottom)` (or a ZStack overlay) on `MainTabView`
/// in ContentView.swift, driven by a shared `@EnvironmentObject` player
/// state so it survives tab switches instead of being re-created per screen.
/// Wiring it there instead of here is a small, mechanical follow-up once
/// that shared state exists — the visual/behavioral contract below is the
/// real deliverable for now.
struct MiniPlayerBar: View {
    /// What the bar is currently showing. Real data flows in from whatever
    /// screen mounts it (today: HomeView's current block); there is no
    /// fabricated placeholder content.
    struct Content {
        let kicker: String
        let title: String
        /// 0...1. There is no playback-position API yet (see home.py's
        /// module docstring: "no Player epic and no playback-position field
        /// anywhere in this codebase") — until that exists this is either
        /// omitted (nil) or a caller-supplied estimate, never invented.
        let progress: Double?
    }

    let content: Content
    @Binding var isPlaying: Bool
    var onSkipBack: () -> Void = {}
    var onTogglePlay: () -> Void = {}
    var onNext: () -> Void = {}

    var body: some View {
        HStack(spacing: LucakuSpacing.sp3) {
            AnimatedWaveform(size: .small, isAnimating: isPlaying)

            VStack(alignment: .leading, spacing: 1) {
                Text(content.kicker)
                    .font(LucakuTypography.caption1)
                    .foregroundStyle(LucakuColor.textSecondary)
                Text(content.title)
                    .font(LucakuTypography.callout)
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: LucakuSpacing.sp2)

            HStack(spacing: 0) {
                Button(action: onSkipBack) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Skip back 15 seconds")

                Button(action: onTogglePlay) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                Button(action: onNext) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Next block")
            }
        }
        .padding(.leading, LucakuSpacing.sp3)
        .padding(.trailing, LucakuSpacing.sp2)
        .frame(height: 64)
        .background(
            // Opaque surface per spec, not .ultraThinMaterial/.regularMaterial glass.
            RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous)
                .fill(LucakuColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous)
                        .strokeBorder(LucakuColor.borderSoft, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.14), radius: 12, x: 0, y: 6)
        )
        .overlay(alignment: .top) {
            if let progress = content.progress {
                GeometryReader { proxy in
                    Capsule()
                        .fill(LucakuColor.accent)
                        .frame(width: max(0, proxy.size.width * progress), height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, LucakuSpacing.sp3)
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, LucakuSpacing.sp2)
    }
}

/// Small animated waveform glyph — the "unambiguous, distinct visual state"
/// indicator DESIGN_SPEC_V3.md calls for on the currently-playing block, and
/// reused at a smaller size on the mini-player. Respects Reduce Motion.
struct AnimatedWaveform: View {
    enum Size {
        case small, regular
        var barWidth: CGFloat { 2.5 }
        var height: CGFloat { self == .small ? 14 : 16 }
        var heights: [CGFloat] {
            switch self {
            case .small: return [5, 13, 8]
            case .regular: return [6, 14, 9, 12]
            }
        }
    }

    let size: Size
    var isAnimating: Bool = true

    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(size.heights.enumerated()), id: \.offset) { index, barHeight in
                Capsule()
                    .fill(LucakuColor.accent)
                    .frame(width: size.barWidth, height: barHeight)
                    .scaleEffect(y: animate && isAnimating && !reduceMotion ? 1.0 : 0.55, anchor: .bottom)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.9)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.12),
                        value: animate
                    )
            }
        }
        .frame(height: size.height)
        .onAppear { animate = isAnimating }
        .onChange(of: isAnimating) { _, newValue in animate = newValue }
    }
}
