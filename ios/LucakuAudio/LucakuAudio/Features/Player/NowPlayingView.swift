import SwiftUI

/// Full "Now Playing" screen (screens spec 4.1-4.11). Presented as an
/// expansion of the mini player from the app root.
///
/// Top to bottom: collapse chevron (there is no ⋯ menu), cover art, big story
/// title, scrubber, controls (speed, -15 s, play/pause, +15 s, share) with
/// download, Useful / Not quite chips, then the tabs "In this episode"
/// (default) and "Transcript".
///
/// Theme: light stays white with a soft wash of the current story's colour;
/// dark is a deep background lit by it (see `PlayerTheme`).
struct NowPlayingView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @EnvironmentObject private var session: SessionStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var firstName = ""
    @State private var showReportedAlert = false
    /// Scrubber position while dragging (nil = follow playback).
    @State private var scrubFraction: Double?

    /// Drag-to-dismiss offset, so collapsing reads as sliding back down into
    /// the mini player rather than a hard cut.
    @GestureState private var dragOffset: CGFloat = 0

    private var theme: PlayerTheme {
        PlayerTheme(colorScheme: colorScheme, story: viewModel.currentBlock?.summary ?? "lucaku")
    }

    var body: some View {
        let theme = self.theme
        ZStack {
            theme.base.ignoresSafeArea()
            theme.wash.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    StatusBarFadeAnchor()
                    topBar(theme)
                    art(theme)
                    titleRow(theme)
                    scrubber(theme)
                    if let message = viewModel.displayedErrorMessage {
                        errorBanner(message, theme)
                    }
                    transport(theme)
                    feedbackChips(theme)
                    tabs(theme)
                    switch viewModel.nowPlayingTab {
                    case .episode: episodeList(theme)
                    case .transcript: TranscriptPanelView(viewModel: viewModel, theme: theme).padding(.horizontal, 16).padding(.top, 12)
                    }
                    Color.clear.frame(height: 48)
                }
            }
            .scrollIndicators(.hidden)
            .statusBarFade(background: theme.topFade)
        }
        .foregroundStyle(theme.fg)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 28, bottomTrailingRadius: 28, style: .continuous))
        .offset(y: max(0, dragOffset))
        .sheet(isPresented: $viewModel.isFeedbackSheetOpen) {
            FeedbackSheet(
                subject: viewModel.currentBlock?.summary ?? "this story",
                onSend: { options, text in viewModel.submitFeedback(options: options, text: text) },
                onReport: {
                    viewModel.reportProblem()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showReportedAlert = true }
                }
            )
        }
        .sheet(isPresented: $viewModel.isShareSheetOpen) {
            ShareSheetView(
                storyTitle: viewModel.currentBlock?.summary ?? viewModel.episode?.headline ?? "",
                listenLength: "\(max(1, Int((Double(viewModel.currentBlock?.durationS ?? 0) / 60).rounded()))) min",
                firstName: firstName
            )
        }
        .alert("Problem reported", isPresented: $showReportedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("We opened a ticket for this story. Thanks for helping us get it right.")
        }
        .task(id: viewModel.isShareSheetOpen) {
            // First name for the share message ("{first} thinks you'll like...").
            guard viewModel.isShareSheetOpen, firstName.isEmpty, let token = session.accessToken else { return }
            if let me = try? await APIClient.shared.me(token: token) {
                firstName = me.nombre.split(separator: " ").first.map(String.init) ?? ""
            }
        }
    }

    // MARK: Top bar

    private func topBar(_ theme: PlayerTheme) -> some View {
        HStack {
            Button {
                withAnimation(LucakuMotion.house) { viewModel.collapseNowPlaying() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.fg)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Minimize player")

            VStack(spacing: 1) {
                Text("PLAYING YOUR BRIEFING")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(theme.fg2)
                Text(episodeSubtitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .updating($dragOffset) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                    if value.translation.height > 120 {
                        withAnimation(LucakuMotion.house) { viewModel.collapseNowPlaying() }
                    }
                }
        )
    }

    private var episodeSubtitle: String {
        let count = viewModel.blocks.count
        let stories = "\(count) \(count == 1 ? "story" : "stories")"
        guard let fecha = viewModel.episode?.fecha else { return stories }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(fecha.prefix(10))) else { return stories }
        if Calendar.current.isDateInToday(date) { return "Today \u{00B7} \(stories)" }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US")
        out.setLocalizedDateFormatFromTemplate("EEEE MMM d")
        return "\(out.string(from: date)) \u{00B7} \(stories)"
    }

    // MARK: Art

    private func art(_ theme: PlayerTheme) -> some View {
        Color.clear
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay {
                PlayerArt(seed: viewModel.currentBlock?.summary ?? "lucaku", cornerRadius: 12)
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 6) {
                            Circle().fill(.white).frame(width: 6, height: 6)
                            Text("STORY \(viewModel.currentBlockIndex + 1) OF \(viewModel.blocks.count)")
                                .font(.system(size: 12, weight: .bold))
                                .tracking(0.3)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.black.opacity(0.42)))
                        .padding(12)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Text("lucaku.")
                            .font(.system(size: 15, weight: .heavy))
                            .tracking(-0.2)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.trailing, 12)
                            .padding(.bottom, 10)
                    }
                    .shadow(color: theme.artShadow, radius: 20, y: 10)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
    }

    // MARK: Title + download

    private func titleRow(_ theme: PlayerTheme) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.currentBlock?.summary ?? "")
                    .font(.system(size: 24, weight: .heavy))
                    .tracking(-0.2)
                    .lineSpacing(2)
                    .foregroundStyle(theme.fg)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(viewModel.episode?.headline ?? "Lucaku Audio")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.fg2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            let downloaded = viewModel.isCurrentEpisodeDownloaded
            Button { viewModel.toggleDownload() } label: {
                Image(systemName: downloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(downloaded ? theme.ok : theme.fg)
                    .frame(width: 44, height: 44)
            }
            .padding(.trailing, -8)
            .accessibilityLabel(downloaded ? "Downloaded, tap to remove" : "Download episode")
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    // MARK: Scrubber

    private func scrubber(_ theme: PlayerTheme) -> some View {
        let fraction = scrubFraction ?? viewModel.episodeProgressFraction
        let duration = viewModel.episodeDurationS
        return VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track).frame(height: 4)
                    Capsule().fill(theme.fill).frame(width: width * fraction, height: 4)
                    if duration > 0 {
                        ForEach(viewModel.blocks.dropFirst()) { block in
                            Rectangle()
                                .fill(theme.tick)
                                .frame(width: 3, height: 6)
                                .offset(x: width * Double(block.startS) / duration - 1)
                        }
                    }
                    Circle()
                        .fill(theme.fill)
                        .frame(width: 13, height: 13)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: width * fraction - 6.5)
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            scrubFraction = min(1, max(0, value.location.x / max(1, width)))
                        }
                        .onEnded { value in
                            let f = min(1, max(0, value.location.x / max(1, width)))
                            viewModel.seekEpisode(fraction: f)
                            scrubFraction = nil
                        }
                )
            }
            .frame(height: 28)
            .accessibilityElement()
            .accessibilityLabel("Episode position")
            .accessibilityValue("\(Int(fraction * 100)) percent")
            .accessibilityAdjustableAction { direction in
                let step = 0.05
                viewModel.seekEpisode(fraction: viewModel.episodeProgressFraction + (direction == .increment ? step : -step))
            }

            HStack {
                Text((fraction * duration).asMinutesSeconds)
                Spacer()
                Text("-" + max(0, duration - fraction * duration).asMinutesSeconds)
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(theme.fg2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    /// Real error surfaced by the audio engine (or "no audio yet for this
    /// episode") — a visible banner with a retry action instead of a silent hang.
    private func errorBanner(_ message: String, _ theme: PlayerTheme) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.fg)
                    .lineLimit(2)
                Button("Retry") { viewModel.retryPlayback() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.fg)
                    .underline()
            }
            Spacer()
        }
        .padding(12)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    // MARK: Controls

    private func transport(_ theme: PlayerTheme) -> some View {
        HStack {
            Button { viewModel.cycleSpeed() } label: {
                Text(viewModel.speed.label)
                    .font(.system(size: 16, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.fg)
                    .frame(minWidth: 56, minHeight: 44)
            }
            .accessibilityLabel("Playback speed \(viewModel.speed.label)")

            Spacer(minLength: 0)
            Button { viewModel.skip(by: -15) } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(theme.fg)
                    .frame(width: 60, height: 60)
            }
            .accessibilityLabel("Back 15 seconds")

            Spacer(minLength: 0)
            Button { viewModel.togglePlay() } label: {
                ZStack {
                    Circle().fill(theme.buttonBg)
                    if viewModel.isBuffering {
                        ProgressView().progressViewStyle(.circular).tint(theme.buttonFg)
                    } else {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(theme.buttonFg)
                    }
                }
                .frame(width: 76, height: 76)
                .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.18), radius: 10, y: 5)
            }
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            Spacer(minLength: 0)
            Button { viewModel.skip(by: 15) } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(theme.fg)
                    .frame(width: 60, height: 60)
            }
            .accessibilityLabel("Forward 15 seconds")

            Spacer(minLength: 0)
            Button { viewModel.isShareSheetOpen = true } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.fg)
                    .frame(minWidth: 56, minHeight: 44)
            }
            .accessibilityLabel("Share this story")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    // MARK: Feedback chips

    private func feedbackChips(_ theme: PlayerTheme) -> some View {
        HStack(spacing: 0) {
            FeedbackChips(
                rating: viewModel.currentRating.map { $0 == .up ? StoryRating.up : StoryRating.down },
                onUseful: { viewModel.toggleUseful() },
                onNotQuite: { viewModel.tapNotQuite() },
                text: theme.fg,
                fill: theme.chip,
                selectedFill: theme.fg,
                selectedText: theme.base
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    // MARK: Tabs

    private func tabs(_ theme: PlayerTheme) -> some View {
        HStack(spacing: 2) {
            tab("In this episode", .episode, theme)
            tab("Transcript", .transcript, theme)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.chip))
        .padding(.horizontal, 16)
        .padding(.top, 22)
    }

    private func tab(_ title: String, _ value: NowPlayingTab, _ theme: PlayerTheme) -> some View {
        let on = viewModel.nowPlayingTab == value
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { viewModel.nowPlayingTab = value }
        } label: {
            Text(title)
                .font(.system(size: 15, weight: on ? .bold : .medium))
                .foregroundStyle(theme.fg)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(on ? theme.base : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: In this episode (4.5)

    private func episodeList(_ theme: PlayerTheme) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(viewModel.blocks.enumerated()), id: \.element.id) { index, block in
                let current = index == viewModel.currentBlockIndex
                Button {
                    viewModel.selectBlock(index, autoplay: true)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        storyTile(block, current: current, theme)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(block.summary)
                                    .font(.system(size: 15, weight: current ? .heavy : .semibold))
                                    .foregroundStyle(current ? theme.fg : theme.fgBody)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(block.durationS.asMinutesSeconds)
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.fg3)
                            }
                            Text(block.gist)
                                .font(.system(size: 13))
                                .foregroundStyle(theme.fg2)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) {
                    if index > 0 { Rectangle().fill(theme.separator).frame(height: 0.5) }
                }
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func storyTile(_ block: BlockOut, current: Bool, _ theme: PlayerTheme) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(current ? AnyShapeStyle(theme.chip) : AnyShapeStyle(StoryPalette.gradient(for: block.summary)))
            Image(systemName: current ? (viewModel.isPlaying ? "waveform" : "pause.fill") : LucakuCover.symbol(for: block.summary))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(current ? theme.fg : Color.white.opacity(0.85))
        }
        .frame(width: 40, height: 40)
    }
}
