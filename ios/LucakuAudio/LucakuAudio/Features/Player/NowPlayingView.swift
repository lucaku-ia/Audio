import SwiftUI

/// Full "Now Playing" screen — player_v3.html's `.nowplaying`. Presented as
/// an expansion of the mini player (a `.move(edge: .bottom)` transition
/// layered above it, not a disconnected modal), per DESIGN_SPEC_V3.md's
/// "Mini-player / persistent playback" section.
///
/// The blurred ambient backdrop is VISUAL-ONLY (muted/desaturated gradient
/// built from `LucakuColor.ambient1`/`ambient2`) — it does not derive from
/// any real audio analysis or artwork; per the task brief this is
/// intentional (a real audio engine is out of scope for this pass).
struct NowPlayingView: View {
    @ObservedObject var viewModel: PlayerViewModel

    /// Drag-to-dismiss offset, so collapsing reads as sliding back down into
    /// the mini player rather than a hard cut.
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ambientBackdrop

                VStack(spacing: 0) {
                    topBar
                    hero
                    progress
                    transport
                    secondaryRow
                    TranscriptPanelView(viewModel: viewModel)
                        .padding(.horizontal, LucakuSpacing.sp3)
                        .padding(.bottom, LucakuSpacing.sp3)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(LucakuColor.bg)
            .clipShape(RoundedCorner(radius: 28, corners: [.bottomLeft, .bottomRight]))
            .offset(y: max(0, dragOffset))
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation.height
                    }
                    .onEnded { value in
                        if value.translation.height > 120 {
                            withAnimation(LucakuMotion.house) { viewModel.collapseNowPlaying() }
                        }
                    }
            )
        }
        .overlay(alignment: .bottom) {
            if viewModel.isTuningSheetOpen {
                tuningSheetOverlay
            }
        }
    }

    // MARK: Ambient backdrop

    private var ambientBackdrop: some View {
        ZStack {
            LucakuColor.bg
            RadialGradient(
                colors: [LucakuColor.ambient1, .clear],
                center: UnitPoint(x: 0.15, y: 0), startRadius: 10, endRadius: 420
            )
            RadialGradient(
                colors: [LucakuColor.ambient2, .clear],
                center: UnitPoint(x: 1.0, y: 0.3), startRadius: 10, endRadius: 460
            )
        }
        .blur(radius: 38)
        .saturation(0.9)
        .overlay(LucakuColor.scrim)
        .ignoresSafeArea()
    }

    // MARK: Sections

    private var topBar: some View {
        HStack {
            Button {
                withAnimation(LucakuMotion.house) { viewModel.collapseNowPlaying() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .frame(width: 44, height: 44)
            }

            Spacer()
            Text("Block \(viewModel.currentBlockIndex + 1) of \(viewModel.blocks.count)")
                .font(LucakuTypography.caption1)
                .foregroundStyle(LucakuColor.textSecondary)
            Spacer()

            Button {
                withAnimation(LucakuMotion.house) { viewModel.isTuningSheetOpen = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, LucakuSpacing.sp2)
        .padding(.top, LucakuSpacing.sp4)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Today's research", systemImage: "clock")
                .font(LucakuTypography.subhead)
                .foregroundStyle(LucakuColor.textSecondary)

            Text(viewModel.currentBlock?.summary ?? "")
                .font(LucakuTypography.title2)
                .fontWeight(.bold)
                .foregroundStyle(LucakuColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LucakuSpacing.sp6)
        .padding(.top, LucakuSpacing.sp4)
    }

    private var progress: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.28))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LucakuColor.textPrimary.opacity(0.9))
                            .frame(width: proxy.size.width * viewModel.currentBlockProgressFraction, height: 4)
                    }
            }
            .frame(height: 4)

            HStack {
                Text(Int(viewModel.currentBlockProgressFraction * Double(viewModel.currentBlockDurationS)).asMinutesSeconds)
                Spacer()
                Text(viewModel.currentBlockDurationS.asMinutesSeconds)
            }
            .font(LucakuTypography.caption1)
            .foregroundStyle(LucakuColor.textSecondary)
            .monospacedDigit()
        }
        .padding(.horizontal, LucakuSpacing.sp6)
        .padding(.top, LucakuSpacing.sp4)
    }

    private var transport: some View {
        HStack(spacing: LucakuSpacing.sp8) {
            Button { viewModel.skipToPreviousBlock() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .frame(width: 52, height: 52)
            }
            .disabled(viewModel.currentBlockIndex == 0)

            Button { viewModel.togglePlay() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(LucakuColor.bg)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(LucakuColor.textPrimary))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            }

            Button { viewModel.skipToNextBlock() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .frame(width: 52, height: 52)
            }
            .disabled(viewModel.currentBlockIndex >= viewModel.blocks.count - 1)
        }
        .padding(.top, LucakuSpacing.sp4)
        .padding(.bottom, LucakuSpacing.sp2)
    }

    private var secondaryRow: some View {
        HStack {
            Button {
                withAnimation(LucakuMotion.house) { viewModel.isTuningSheetOpen = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 13))
                    Text("\(viewModel.speed.label) speed & tuning")
                        .font(LucakuTypography.footnote)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(LucakuColor.textPrimary)
                .padding(.horizontal, LucakuSpacing.sp3)
                .frame(height: 36)
                .background(Capsule().fill(Color.gray.opacity(0.14)))
            }
        }
        .padding(.top, LucakuSpacing.sp1)
        .padding(.bottom, LucakuSpacing.sp3)
    }

    // MARK: Tuning sheet overlay

    private var tuningSheetOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(LucakuMotion.house) { viewModel.isTuningSheetOpen = false }
                }

            TuningSheetView(viewModel: viewModel)
                .transition(.move(edge: .bottom))
        }
        .transition(.opacity)
    }
}
