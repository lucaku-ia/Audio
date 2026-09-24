import SwiftUI

/// The persistent mini player bar — player_v3.html's `.miniplayer`. Per
/// DESIGN_SPEC_V3.md's "Mini-player / persistent playback" section this is a
/// SINGLE global overlay mounted once above the tab bar (in
/// ContentView.swift's `MainTabView`), surviving navigation across every tab,
/// never re-instantiated per screen.
///
/// This is the ONE shared mini-player instance every tab renders against,
/// backed by the single `PlayerViewModel` owned at the app root
/// (`LucakuAudioApp`) and injected via `.environmentObject()`. Home has no
/// player of its own — it reads this same `viewModel` for its "currently
/// playing" highlight.
///
/// Look: a floating rounded card tinted with the same colour as the cover of
/// whatever's loaded (generated cover art, see `LucakuCover`), a cover
/// thumbnail, the episode title over the current topic, and play/pause +
/// next. It's shown whenever an episode is loaded — paused or playing — the
/// way music apps keep the last-played item docked, not only mid-playback.
struct MiniPlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        if let block = viewModel.currentBlock {
            card(block)
        }
    }

    private func card(_ block: BlockOut) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CoverArt(seed: viewModel.coverSeed, cornerRadius: 6)
                    .frame(width: 44, height: 44)

                Button {
                    withAnimation(LucakuMotion.house) { viewModel.expandNowPlaying() }
                } label: {
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
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)

                controls
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 60)

            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.white.opacity(0.18))
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
        // Solid surface with a hairline, not a tinted wash. It used to lay the
        // cover's colour over the surface at 55% — which worked against the
        // old saturated cover palette on a dark-only app, but now reads as
        // muddy grey-green on a light background. The cover art itself is
        // right there in the bar, so the bar doesn't need to repeat its colour.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LucakuColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(LucakuColor.borderSoft, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 4)
        .padding(.horizontal, LucakuSpacing.sp2)
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
                        .font(.system(size: 20))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .frame(width: 44, height: 44)
                }
            }

            Button {
                viewModel.skipToNextBlock()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .disabled(viewModel.currentBlockIndex >= viewModel.blocks.count - 1)
        }
    }
}
