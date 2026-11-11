import SwiftUI

/// The persistent mini player (screens spec 4, "Mini player"). A SINGLE global
/// overlay mounted once above the tab bar in `MainTabView`, backed by the one
/// shared `PlayerViewModel`.
///
/// Rules: cover, episode title, current story summary, play and next.
/// Tapping anywhere on the card, cover included, opens the full player; the
/// play and next buttons do not. It stays docked whenever an episode is
/// loaded, paused or playing.
struct MiniPlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel

    /// False when the mini player is hosted by something that already draws a
    /// background for it (iOS 26's `tabViewBottomAccessory`).
    var drawsOwnChrome: Bool = true

    var body: some View {
        if let block = viewModel.currentBlock {
            card(block)
        }
    }

    private func open() {
        withAnimation(LucakuMotion.house) { viewModel.expandNowPlaying() }
    }

    private func card(_ block: BlockOut) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PlayerArt(seed: block.summary, cornerRadius: 6)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.episode?.headline ?? "Lucaku Audio")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .lineLimit(1)
                    Text(block.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                controls
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 60)

            GeometryReader { proxy in
                Rectangle()
                    .fill(LucakuColor.fill)
                    .frame(height: 2)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(LucakuColor.textPrimary)
                            .frame(width: proxy.size.width * viewModel.currentBlockProgressFraction, height: 2)
                    }
            }
            .frame(height: 2)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        // `drawsOwnChrome == false` when the system is already providing a
        // background — as a `tabViewBottomAccessory` the platform draws the
        // glass surface and positions the bar, and painting our own card on
        // top of it gives a panel inside a panel.
        .background {
            if drawsOwnChrome {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LucakuColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(LucakuColor.borderSoft, lineWidth: 1)
                    )
            }
        }
        .modifier(MiniPlayerCardChrome(enabled: drawsOwnChrome))
        // Whole card opens the player; the control buttons below take their
        // own taps first and never open it.
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open player", open)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            if viewModel.displayedErrorMessage != nil {
                // Visible error affordance instead of a silently-hanging
                // transport — tapping retries the real audio engine.
                Button {
                    viewModel.retryPlayback()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.orange)
                        .frame(width: 44, height: 44)
                }
            }

            Button {
                viewModel.togglePlay()
            } label: {
                if viewModel.isBuffering {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(LucakuColor.textPrimary)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .frame(width: 44, height: 44)
                }
            }
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            Button {
                viewModel.skipToNextBlock()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .disabled(viewModel.currentBlockIndex >= viewModel.blocks.count - 1)
            .opacity(viewModel.currentBlockIndex >= viewModel.blocks.count - 1 ? 0.4 : 1)
            .accessibilityLabel("Next story")
        }
    }
}


/// The floating-card treatment the mini player wears only when it is NOT
/// hosted inside a system-provided bar.
private struct MiniPlayerCardChrome: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 4)
                .padding(.horizontal, LucakuSpacing.sp2)
                .padding(.bottom, 8)
        } else {
            content
        }
    }
}
