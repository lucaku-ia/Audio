import SwiftUI

/// Home — dark-first, cover-led, modelled on how music/podcast apps lay out a
/// home screen (greeting, today's hero card, a grid of your topics, shelves of
/// episodes to play) rather than a grey system list.
///
/// Everything shown comes from the real `GET /api/home` response (plus the
/// customer's standing requests for the topics grid) — nothing is invented:
///
/// - Hero: today's episode when the banner is `ready`; otherwise a card that
///   says what's actually happening (nothing started yet → "Generate my
///   episode now"; recording; on its way with an ETA; running long).
/// - "Your topics": the customer's active standing requests, shown by the
///   AI-derived `structured.topic`.
/// - "For you": shared sample episodes matching the interests they follow
///   (real matches only — see home.py's `_derive_shared_inventory`).
/// - "Explore": shared samples for topics they don't follow yet, honestly
///   labelled as exploration (home.py's `_derive_explore`).
/// - "Recent": their own last few days; tapping a day plays it.
///
/// PLAYBACK: every play button here drives the single shared
/// `PlayerViewModel` owned at the app root — this screen never keeps playback
/// state of its own. The floating mini player (mounted once in
/// `MainTabView`) appears as soon as the shared player has an episode loaded,
/// which `refresh()` below makes happen automatically (paused, not
/// autoplaying) the moment today's — or, failing that, the most recent —
/// episode exists.
struct HomeView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var playerViewModel: PlayerViewModel
    @StateObject private var viewModel = HomeViewModel()
    /// Backs "Generate my episode now" (POST /api/generation/run via
    /// LibraryViewModel, unchanged).
    @StateObject private var generationViewModel = LibraryViewModel()

    /// Tapping a block row hands the tapped block up to whoever mounts this
    /// screen (MainTabView), which expands the Now Playing overlay at it.
    var onOpenBlock: (BlockSummaryOut) -> Void = { _ in }
    /// "Manage" / a topic tile — jumps to the Interests tab.
    var onSeeInterests: () -> Void = {}

    var body: some View {
        NavigationStack {
            ZStack {
                LucakuColor.bg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: LucakuSpacing.sp6) {
                        header
                        content
                    }
                    .padding(.horizontal, LucakuSpacing.sp4)
                    .padding(.top, LucakuSpacing.sp2)
                    // Room for the global mini player (mounted once in
                    // MainTabView) so it never covers the last row.
                    .padding(.bottom, playerViewModel.hasEpisode ? 96 : LucakuSpacing.sp8)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await refresh() }
            .task(id: pollingKey) { await pollWhileMaking() }
            .refreshable { await refresh() }
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
        .padding(.top, LucakuSpacing.sp4)
    }

    // MARK: - Content switch

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            loadingView
        case .failed(let message):
            failedView(message)
        case .loaded(let home):
            loadedView(home)
        }
    }

    private var loadingView: some View {
        ProgressView()
            .tint(LucakuColor.accent)
            .frame(maxWidth: .infinity, minHeight: 300)
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
            Button("Retry") { Task { await refresh() } }
                .font(LucakuTypography.callout.weight(.semibold))
                .foregroundStyle(LucakuColor.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding()
    }

    @ViewBuilder
    private func loadedView(_ home: HomeOut) -> some View {
        switch home.banner.state {
        case "empty_day":
            EmptyCaughtUpView(
                recent: home.recent,
                requestText: $viewModel.requestTodayText,
                isSubmitting: viewModel.isSubmittingRequest,
                submitError: viewModel.requestTodayError,
                onCheckNow: { Task { await refresh() } },
                onSubmitRequest: { submitRequest() }
            )
            generateNowSection

        case "making", "late":
            MakingHeroCard(
                isLate: home.banner.state == "late",
                requestsCount: home.banner.requestsCount,
                eta: home.banner.eta,
                isGenerating: isGenerating,
                errorMessage: generationErrorMessage,
                onGenerate: { startGeneration() }
            )

        case "re_entry":
            HeroReEntryView(
                requestText: $viewModel.requestTodayText,
                isSubmitting: viewModel.isSubmittingRequest,
                submitError: viewModel.requestTodayError,
                onSubmit: { submitRequest() }
            )

        default: // "ready"
            readyHero(home.banner)
        }

        topicsSection
        shelves(home)
    }

    // MARK: - "ready" — Today's episode hero + block list

    @ViewBuilder
    private func readyHero(_ banner: BannerOut) -> some View {
        let isToday = isTodayLoaded(banner)
        TodayHeroCard(
            headline: banner.headline ?? "Your daily briefing",
            meta: heroMeta(banner: banner),
            seed: banner.headline ?? "today",
            isPlaying: isToday && playerViewModel.isPlaying,
            onPlay: { playToday(banner) }
        )

        if !banner.blocks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HomeShelfHeader(title: "In this episode")
                blockRows(banner.blocks, isToday: isToday)
            }
        }
    }

    private func blockRows(_ blocks: [BlockSummaryOut], isToday: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                let current = isCurrentBlock(block, isToday: isToday)
                HomeBlockRowView(
                    number: current ? nil : block.sequence + 1,
                    title: block.summary,
                    metaText: metaText(for: block, isCurrent: current),
                    isCurrent: current,
                    isPlaying: playerViewModel.isPlaying,
                    subprogress: current ? playerViewModel.currentBlockProgressFraction : nil,
                    isExpanded: false,
                    isLast: index == blocks.count - 1,
                    onTap: { onOpenBlock(block) }
                )
            }
        }
    }

    /// Whether the shared player currently holds TODAY's episode (as opposed
    /// to a sample or a past day) — so playing something else never lights up
    /// today's block rows.
    private func isTodayLoaded(_ banner: BannerOut) -> Bool {
        guard let id = banner.episodeId else { return false }
        return playerViewModel.hasEpisode && playerViewModel.loadedEpisodeIdentifier == id
    }

    /// Matches by `start_s`/`end_s` rather than `id` — the shared
    /// `PlayerViewModel`'s `BlockOut` model doesn't decode the real backend
    /// block `id` yet, only synthesizing a local one from its start/end
    /// offsets. Both endpoints serialize the same `Block` rows via the
    /// backend's shared `_block_common_fields` helper, so start/end offsets
    /// are a reliable, real join key between the two screens today. A block
    /// only counts as "current" once playback has actually begun — a freshly
    /// loaded, never-played episode has nothing "now playing" yet.
    private func isCurrentBlock(_ block: BlockSummaryOut, isToday: Bool) -> Bool {
        guard isToday, playerViewModel.isPlaying || playerViewModel.currentTime > 0.5,
              let currentBlock = playerViewModel.currentBlock else { return false }
        return currentBlock.startS == block.startS && currentBlock.endS == block.endS
    }

    private func metaText(for block: BlockSummaryOut, isCurrent: Bool) -> String {
        guard isCurrent else { return HomeFormat.clock(block.durationS) }
        let elapsed = max(0, Int(playerViewModel.currentTime) - block.startS)
        let prefix = playerViewModel.isPlaying ? "Now playing" : "Paused"
        return "\(prefix)  ·  \(HomeFormat.clock(elapsed)) of \(HomeFormat.clock(block.durationS))"
    }

    private func heroMeta(banner: BannerOut) -> String {
        var parts: [String] = []
        if let count = banner.requestsCount {
            parts.append("\(count) topic\(count == 1 ? "" : "s")")
        }
        if let minutes = HomeFormat.minutes(banner.durationS) {
            parts.append(minutes)
        }
        return parts.isEmpty ? HomeFormat.todayHeadline : parts.joined(separator: "  ·  ")
    }

    // MARK: - Your topics

    @ViewBuilder
    private var topicsSection: some View {
        if !viewModel.topics.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HomeShelfHeader(
                    title: "Your topics",
                    subtitle: "What Lucaku researches for you every day",
                    actionTitle: "Manage",
                    action: onSeeInterests
                )
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(Array(viewModel.topics.prefix(8)), id: \.id) { topic in
                        TopicTile(
                            title: topic.structured.topic,
                            seed: topic.structured.topic,
                            onTap: onSeeInterests
                        )
                    }
                }
            }
        }
    }

    // MARK: - Shelves

    @ViewBuilder
    private func shelves(_ home: HomeOut) -> some View {
        if !home.sharedInventory.isEmpty {
            episodeShelf(
                title: "For you",
                subtitle: "Picked from what you follow",
                items: home.sharedInventory
            )
        }
        if !home.explore.isEmpty {
            episodeShelf(
                title: "Explore",
                subtitle: "Something new to try",
                items: home.explore
            )
        }
        if !home.recent.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HomeShelfHeader(title: "Recent")
                RecentShelfView(episodes: home.recent) { episode in
                    if let id = episode.episodeId {
                        playEpisode(id, coverSeed: episode.headline ?? episode.date)
                    }
                }
            }
        }
    }

    private func episodeShelf(title: String, subtitle: String, items: [SharedInventoryOut]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeShelfHeader(title: title, subtitle: subtitle)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: LucakuSpacing.sp3) {
                    ForEach(items) { item in
                        let label = viewModel.label(forTag: item.tag)
                        EpisodeShelfCard(
                            title: item.headline ?? label,
                            subtitle: cardSubtitle(label: label, durationS: item.durationS),
                            seed: item.tag ?? item.headline ?? item.episodeId,
                            isPlaying: playerViewModel.loadedEpisodeIdentifier == item.episodeId && playerViewModel.isPlaying,
                            onTap: { playEpisode(item.episodeId, coverSeed: item.tag ?? item.headline) }
                        )
                    }
                }
            }
        }
    }

    private func cardSubtitle(label: String, durationS: Int?) -> String {
        [label, HomeFormat.minutes(durationS)].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Generate episode now (empty_day)

    /// "Generate today's episode now" for the `empty_day` state — the moment
    /// a customer would rather trigger generation on demand than wait for the
    /// scheduled run.
    @ViewBuilder
    private var generateNowSection: some View {
        VStack(alignment: .leading, spacing: LucakuSpacing.sp2) {
            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Recording — about a minute or two.")
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(LucakuColor.textSecondary)
                }
            } else {
                Button { startGeneration() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.badge.plus")
                        Text("Generate today's episode now")
                    }
                    .font(LucakuTypography.callout)
                    .foregroundStyle(LucakuColor.textPrimary)
                    .padding(.horizontal, LucakuSpacing.sp4)
                    .frame(minHeight: 44)
                    .overlay(Capsule().strokeBorder(LucakuColor.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                if let message = generationErrorMessage {
                    Text(message)
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
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

    /// Play/pause today's episode from the hero button. If the shared player
    /// holds a different episode (or none), loads today's first.
    private func playToday(_ banner: BannerOut) {
        guard let token = session.accessToken, let id = banner.episodeId else { return }
        Task {
            if playerViewModel.loadedEpisodeIdentifier == id, playerViewModel.hasEpisode {
                if playerViewModel.isPlaying || playerViewModel.currentTime > 0.5 {
                    playerViewModel.togglePlay()
                } else {
                    playerViewModel.selectBlock(0, autoplay: true)
                }
                return
            }
            await playerViewModel.loadEpisode(id: id, token: token, autoplay: true, coverSeed: banner.headline ?? "today")
        }
    }

    /// Tap on a shelf card: plays that episode (a shared sample or a past
    /// day); tapping the card that's already loaded toggles pause/resume.
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
        Task {
            await generationViewModel.runGeneration(token: token)
            await refresh()
        }
    }

    private func submitRequest() {
        guard let token = session.accessToken else { return }
        Task { await viewModel.submitRequestToday(token: token) }
    }

    /// Reloads Home, then makes sure the shared player has something loaded
    /// (paused) so the floating mini player is present from the moment there's
    /// anything to play: today's episode if it's ready, otherwise the most
    /// recent past episode. Never replaces an episode that's already loaded —
    /// a refresh must not interrupt what the customer is listening to.
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

    // MARK: - Polling while an episode is being made

    /// Restarts (via `.task(id:)`) whenever the banner's state changes; only
    /// does anything while a job is actually running (banner making/late with
    /// an ETA), re-fetching quietly every 10s so the hero flips to "ready" —
    /// and the mini player appears — without the customer having to pull to
    /// refresh. Stops after ~10 minutes.
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
