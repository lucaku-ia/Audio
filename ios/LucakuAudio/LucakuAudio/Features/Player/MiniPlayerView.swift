import SwiftUI

/// The persistent mini player bar — player_v3.html's `.miniplayer`. Per
/// DESIGN_SPEC_V3.md's "Mini-player / persistent playback" section this is a
/// SINGLE global overlay mounted once above the tab bar (in
/// ContentView.swift's `MainTabView`), surviving navigation across every tab,
/// never re-instantiated per screen.
///
/// This is now the ONE shared mini-player instance every tab renders
/// against, backed by the single `PlayerViewModel` owned at the app root
/// (`LucakuAudioApp`) and injected via `.environmentObject()`. Home no
/// longer has its own separate mini player (`MiniPlayerBar` was deleted) —
/// it reads this same `viewModel` for its "currently playing" highlight.
struct MiniPlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        guard let block = viewModel.currentBlock else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(spacing: 0) {
                HStack(spacing: LucakuSpacing.sp2) {
                    glyph

                    Button {
                        withAnimation(LucakuMotion.house) { viewModel.expandNowPlaying() }
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Playing · Block \(viewModel.currentBlockIndex + 1) of \(viewModel.blocks.count)")
                                .font(LucakuTypography.caption1)
                                .foregroundStyle(LucakuColor.textSecondary)
                                .lineLimit(1)
                            Text(block.summary)
                                .font(LucakuTypography.subhead)
                                .fontWeight(.semibold)
                                .foregroundStyle(LucakuColor.textPrimary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    controls
                }
                .padding(.leading, LucakuSpacing.sp3)
                .padding(.trailing, LucakuSpacing.sp2)
                .frame(height: 64)

                GeometryReader { proxy in
                    Rectangle()
                        .fill(LucakuColor.borderSoft)
                        .frame(height: 2)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(LucakuColor.accent)
                                .frame(width: proxy.size.width * viewModel.currentBlockProgressFraction, height: 2)
                        }
                }
                .frame(height: 2)
            }
            .background(LucakuColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: LucakuRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: LucakuRadius.card)
                    .stroke(LucakuColor.borderSoft, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 8)
            .padding(.horizontal, LucakuSpacing.sp3)
        )
    }

    private var glyph: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(LucakuColor.accentTintStrong)
            .frame(width: 34, height: 34)
            .overlay {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LucakuColor.accent)
            }
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
                viewModel.skipToPreviousBlock()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .disabled(viewModel.currentBlockIndex == 0)

            Button {
                viewModel.togglePlay()
            } label: {
                if viewModel.isBuffering {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .frame(width: 44, height: 44)
                }
            }

            Button {
                viewModel.skipToNextBlock()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .disabled(viewModel.currentBlockIndex >= viewModel.blocks.count - 1)
        }
    }
}
