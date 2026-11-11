import SwiftUI

/// Home (screens spec section 3): greeting and date, a top card that follows
/// the episode state (3.1 - 3.2, 3.10 - 3.16), the "Your Lucaku" card, the
/// previous episodes shelf, and "Your news" grouped by day (3.3 - 3.9).
///
/// Episode data comes from the real `GET /api/home` response. News has no
/// backend yet, so it comes from `NewsStore` (see `NewsRepository`).
///
/// PLAYBACK: every play button here drives the single shared
/// `PlayerViewModel` owned at the app root; this screen keeps no playback
/// state of its own. `refresh()` loads today's (or the latest) episode into
/// the player, paused, so the mini player appears as soon as there is
/// something to play.
struct HomeView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var playerViewModel: PlayerViewModel
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var news = NewsStore()
    /// Backs "Generate my episode now" (POST /api/generation/run).
    @StateObject private var generationViewModel = LibraryViewModel()

    /// "Edit" / "+" on the Your Lucaku card: jumps to the Interests tab.
    var onSeeInterests: () -> Void = {}

    @State private var generatingSince: Date?
    /// The episode the listener has actually started. Home's "currently
    /// playing" strip is about where the playhead is sitting, not about
    /// whether audio is moving, so pausing must not clear this.
    @State private var startedEpisodeId: String?
    /// Stories push onto this path, so one story can open another.
    @State private var storyPath = NavigationPath()
    /// DEBUG only: forces a top-card state so every 3.x state is reproducible.
    /// Always nil in release builds (the menu that sets it is #if DEBUG).
    @State private var debugState: HomeTopState?
    @State private var debugStamp = Date()

    var body: some View {
        NavigationStack(path: $storyPath) {
            ZStack {
                LucakuColor.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        StatusBarFadeAnchor()
                        VStack(alignment: .leading, spacing: LucakuSpacing.sp6) {
                            header
                            content
                        }
                        .padding(.horizontal, LucakuSpacing.sp4)
                        .padding(.top, LucakuSpacing.sp2)
                        // No mini-player allowance here: MainTabView mounts
                        // it as a bottom safe-area inset, so this scroll view
                        // is already inset by its real height.
                        .padding(.bottom, LucakuSpacing.sp8)
                    }
                }
                .statusBarFade()
            }
            .navigationTitle("Home")
            .toolbar(.hidden, for: .navigationBar)
            // Value-based rather than `item:` so a story opened from another
            // story's "More from today" pushes onto the stack instead of
            // replacing the one you are reading.
            .navigationDestination(for: NewsStory.self) { story in
                NewsDetailView(story: story, store: news)
            }
            .task { await refresh() }
            .task { await news.load(token: session.accessToken) }
            .task(id: viewModel.topics.count) {
                news.setFollowedTopics(viewModel.topics.map { $0.structured.topic })
            }
            .task(id: pollingKey) { await pollWhileMaking() }
            .refreshable { await refresh() }
            // Playback can be started from the mini player, the Now Playing
            // screen or the lock screen, so record the episode the moment it
            // starts rather than only in `playToday`.
            .onChange(of: playerViewModel.isPlaying) { _, playing in
                if playing { startedEpisodeId = playerViewModel.loadedEpisodeIdentifier }
            }
            .animation(LucakuMotion.house, value: playerViewModel.hasEpisode)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(HomeFormat.greeting)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(LucakuColor.textPrimary)
            Text(HomeFormat.todayHeadline)
                .font(LucakuTypography.subhead)
                .foregroundStyle(LucakuColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, LucakuSpacing.sp4)
        #if DEBUG
        // Long-press the greeting to force any top-card state (3.1 - 3.16).
        .contextMenu {
            Button("Live data") { debugState = nil }
            ForEach(HomeTopState.allCases) { state in
                Button(state.debugTitle) {
                    debugStamp = Date()
                    debugState = state
                }
            }
        }
        #endif
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if debugState == nil, isLoadingHome {
            ProgressView()
                .tint(LucakuColor.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if debugState == nil, let message = failureMessage {
            failedView(message)
        } else {
            loadedContent(home: loadedHome)
        }
    }

    private var loadedHome: HomeOut? {
        if case .loaded(let home) = viewModel.state { return home }
        return nil
    }

    private var isLoadingHome: Bool {
        switch viewModel.state {
        case .idle, .loading: return true
        default: return false
        }
    }

    private var failureMessage: String? {
        if case .failed(let message) = viewModel.state { return message }
        return nil
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: LucakuSpacing.sp3) {
            Text("Couldn't load Home")
                .font(LucakuTypography.headline)
                .foregroundStyle(LucakuColor.textPrimary)
            Text(message)
                .font(LucakuTypography.footnote)
                .foregroundStyle(LucakuColor.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Button("Retry") { Task { await refresh() } }
                .font(LucakuTypography.callout.weight(.semibold))
                .foregroundStyle(LucakuColor.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding()
    }

    @ViewBuilder
    private func loadedContent(home: HomeOut?) -> some View {
        let state = topState(home)
        HomeTopCard(
            state: state,
            headline: debugState != nil ? Self.debugHeadline : (home?.banner.headline ?? "Your daily briefing"),
            storyCount: debugState != nil ? 4 : (home?.banner.blocks.count ?? home?.banner.requestsCount ?? 0),
            durationS: debugState != nil ? 17 * 60 : home?.banner.durationS,
            topicsCount: max(viewModel.topics.count, home?.banner.requestsCount ?? 0, debugState != nil ? 4 : 0),
            deliveryClock: viewModel.deliveryClock,
            eta: debugState != nil ? debugStamp.addingTimeInterval(25 * 60) : home?.banner.eta,
            generatingSince: debugState == .generating ? debugStamp : generatingSince,
            playbackFraction: playbackFraction(home),
            playbackStatus: playbackStatus(home),
            isPlayingNow: isTodayLoaded(home?.banner) && playerViewModel.isPlaying,
            errorMessage: generationErrorMessage,
            requestText: $viewModel.requestTodayText,
            isSubmitting: viewModel.isSubmittingRequest,
            submitError: viewModel.requestTodayError,
            actions: HomeTopActions(
                onPlay: { if let banner = home?.banner { playToday(banner) } },
                onOpenPlayer: { withAnimation(LucakuMotion.house) { playerViewModel.expandNowPlaying() } },
                onGenerate: { startGeneration() },
                onCheckNow: { Task { await refresh() } },
                onSubmitRequest: { submitRequest() },
                onAddTopic: { addTopic() }
            )
        )

        // The prototype's Home is exactly three things: the greeting, one
        // state card, and the news by day. Two sections that used to sit
        // between the card and the news are gone with it:
        //
        // - "Your Lucaku" (delivery time + the topics you follow). Interests
        //   is a tab of its own now, so this was a second, lesser copy of it
        //   on the screen you see most.
        // - "Previous episodes". History moved to Profile, where it is a full
        //   list rather than a shelf you scroll sideways past the news.
        //
        // Both still exist as components; nothing on Home mounts them.
        NewsSectionView(store: news, onOpen: { story in
            news.markRead(story)
            storyPath.append(story)
        })
    }

    // MARK: - State mapping

    private static let debugHeadline = "Rates hold, AI moves fast, and Arsenal's weekend"

    /// Maps the backend banner (`ready | making | late | empty_day | re_entry`)
    /// plus local playback / generation state onto a top-card state.
    private func topState(_ home: HomeOut?) -> HomeTopState {
        if let debugState { return debugState }
        guard let banner = home?.banner else { return .notStarted }
        switch banner.state {
        case "ready":
            return isTodayLoaded(banner) && playbackHasStarted ? .playing : .ready
        case "late":
            return .late
        case "making":
            if isGenerating { return .generating }
            if banner.eta != nil { return (home?.recent.isEmpty ?? true) ? .firstDay : .onItsWay }
            return .notStarted
        case "re_entry":
            return .noTopics
        case "empty_day":
            return .caughtUp
        default:
            return .ready
        }
    }

    private var topicLabels: [String] {
        var seen = Set<String>()
        var labels = viewModel.topics.map { $0.structured.topic }.filter { seen.insert($0).inserted }
        if labels.isEmpty, debugState != nil {
            labels = ["Interest rates & savings", "Artificial intelligence", "Arsenal FC", "Space exploration"]
        }
        return Array(labels.prefix(5))
    }

    private func playbackFraction(_ home: HomeOut?) -> Double {
        if debugState != nil, !isTodayLoaded(home?.banner) { return 0.35 }
        guard let total = playerViewModel.episode?.durationS, total > 0 else { return 0 }
        return playerViewModel.currentTime / Double(total)
    }

    private func playbackStatus(_ home: HomeOut?) -> String {
        if debugState != nil, !isTodayLoaded(home?.banner) { return "Now playing · Story 2 of 4 · 6:12 left" }
        let count = playerViewModel.blocks.count
        let total = playerViewModel.episode?.durationS ?? 0
        let left = max(0, total - Int(playerViewModel.currentTime))
        let prefix = playerViewModel.isPlaying ? "Now playing" : "Paused"
        return "\(prefix) · Story \(playerViewModel.currentBlockIndex + 1) of \(count) · \(HomeFormat.clock(left)) left"
    }

    /// Whether the listener is somewhere inside the loaded episode, as
    /// opposed to standing at its start having never played it. Home loads
    /// an episode paused at 0:00 just so the mini player exists, so "loaded"
    /// alone is not enough — but once playback has begun, pausing and
    /// seeking are both just ways of moving the playhead, and neither means
    /// the listener has left the episode.
    ///
    /// This used to be `isPlaying || currentTime > 0.5`, which read the
    /// transport instead of the playhead. Pausing in the opening seconds, or
    /// skipping back to the first block, put the playhead at or near 0:00
    /// with nothing playing, and Home concluded the episode had never been
    /// started: the progress strip vanished and "Resume" turned back into
    /// "Play". The `currentTime` test survives as a fallback for playback
    /// that began while this screen was not around to see it.
    private var playbackHasStarted: Bool {
        guard playerViewModel.hasEpisode else { return false }
        if playerViewModel.isPlaying { return true }
        if let loaded = playerViewModel.loadedEpisodeIdentifier, loaded == startedEpisodeId { return true }
        return playerViewModel.currentTime > 0.5
    }

    /// Whether the shared player currently holds TODAY's episode (as opposed
    /// to a sample or a past day).
    private func isTodayLoaded(_ banner: BannerOut?) -> Bool {
        guard let id = banner?.episodeId else { return false }
        return playerViewModel.hasEpisode && playerViewModel.loadedEpisodeIdentifier == id
    }

    // MARK: - Generation state

    private var isGenerating: Bool {
        if case .running = generationViewModel.generationState { return true }
        return false
    }

    private var generationErrorMessage: String? {
        if case .failed(let message) = generationViewModel.generationState { return message }
        return nil
    }

    // MARK: - Actions

    /// Play/pause today's episode from the top card. If the shared player
    /// holds a different episode (or none), loads today's first.
    private func playToday(_ banner: BannerOut) {
        guard let token = session.accessToken, let id = banner.episodeId else { return }
        Task {
            if playerViewModel.loadedEpisodeIdentifier == id, playerViewModel.hasEpisode {
                if playbackHasStarted {
                    playerViewModel.togglePlay()
                } else {
                    playerViewModel.selectBlock(0, autoplay: true)
                }
                startedEpisodeId = id
                return
            }
            // Nothing to record here: if the load succeeds and audio starts,
            // the `isPlaying` observer above records it; if it fails, the
            // card should keep saying "Play".
            await playerViewModel.loadEpisode(id: id, token: token, autoplay: true, coverSeed: banner.headline ?? "today")
        }
    }

    /// Tap on a previous episode: plays it; tapping the one already loaded
    /// toggles pause/resume.
    private func playEpisode(_ id: String, coverSeed: String?) {
        guard let token = session.accessToken else { return }
        Task {
            if playerViewModel.loadedEpisodeIdentifier == id, playerViewModel.hasEpisode {
                playerViewModel.togglePlay()
                return
            }
            await playerViewModel.loadEpisode(id: id, token: token, autoplay: true, coverSeed: coverSeed)
        }
    }

    private func startGeneration() {
        guard let token = session.accessToken else { return }
        generatingSince = Date()
        Task {
            await generationViewModel.runGeneration(token: token)
            generatingSince = nil
            await refresh()
        }
    }

    private func submitRequest() {
        guard let token = session.accessToken else { return }
        Task { await viewModel.submitRequestToday(token: token) }
    }

    private func addTopic() {
        guard let token = session.accessToken else { return }
        Task { await viewModel.addFirstTopic(token: token) }
    }

    /// Reloads Home, then makes sure the shared player has something loaded
    /// (paused) so the mini player is present from the moment there's
    /// anything to play: today's episode if it's ready, otherwise the most
    /// recent past episode. Never replaces an episode that's already loaded.
    private func refresh(showSpinner: Bool = true) async {
        guard let token = session.accessToken else { return }
        await viewModel.load(token: token, showSpinner: showSpinner)

        guard !playerViewModel.hasEpisode, case .loaded(let home) = viewModel.state else { return }
        let episodeId: String?
        let seed: String?
        if home.banner.state == "ready", let todaysId = home.banner.episodeId {
            episodeId = todaysId
            seed = home.banner.headline ?? "today"
        } else if let recent = home.recent.first(where: { $0.episodeId != nil }) {
            episodeId = recent.episodeId
            seed = recent.headline ?? recent.date
        } else {
            episodeId = nil
            seed = nil
        }
        if let episodeId {
            await playerViewModel.loadEpisode(id: episodeId, token: token, autoplay: false, coverSeed: seed)
        }
    }

    // MARK: - Polling while an episode is being made (3.10, 3.13, 3.14)

    /// Restarts (via `.task(id:)`) whenever the banner's state changes; only
    /// does anything while a job is actually running (banner making/late with
    /// an ETA), re-fetching quietly every 10 s so the top card flips to
    /// "ready", and the mini player appears, without a pull to refresh.
    /// Stops after ~10 minutes.
    private var pollingKey: String {
        guard case .loaded(let home) = viewModel.state else { return "idle" }
        return "\(home.banner.state)-\(home.banner.eta != nil)"
    }

    private func pollWhileMaking() async {
        guard case .loaded(let home) = viewModel.state,
              home.banner.state == "making" || home.banner.state == "late",
              home.banner.eta != nil else { return }
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if Task.isCancelled { return }
            await refresh(showSpinner: false)
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(SessionStore())
        .environmentObject(PlayerViewModel())
}
