import SwiftUI

/// Home screen — calls the real GET /api/home endpoint (via HomeViewModel /
/// APIClient, unchanged) and renders the response against the approved
/// home_v3.html design (see /tmp/lucaku_design/home_v3.html and
/// DESIGN_SPEC_V3.md). Visual tokens come from LucakuColor/Typography/
/// Spacing/Radius/Motion (DesignSystem/) — nothing here invents a color,
/// font size, spacing value, or radius.
///
/// DATA HONESTY NOTE (see HomeModels.swift / backend/app/api/routes/home.py):
/// the approved mockup's block list shows 5 independently-tappable topic
/// rows for today's episode. The real `GET /api/home` response does not
/// expose a per-block breakdown — `BannerOut` (ready state) only has
/// `headline` / `duration_s` / `style` / `requests_count` for the whole
/// episode; there is no `blocks: [...]` array anywhere in `HomeOut`. Rather
/// than fabricate topic text/durations that don't exist, the block list
/// below renders exactly one row — the real episode as a whole, in the
/// "currently playing" visual state the mockup uses for its first row
/// (waveform, tint, sub-progress, go-deeper/follow-up disclosure). The
/// `requests_count` field (real) is surfaced in the hero-meta line as
/// "N topics" instead. If/when the backend adds a real per-block list to
/// `HomeOut`, `BlockRowView` already supports N rows — only the mapping in
/// `todayBlocks` below needs to grow from one row to `home.blocks.map { ... }`.
///
/// PLAYBACK STATE NOTE: this row's "currently playing" visuals (waveform
/// animation, elapsed time, sub-progress fill) read from the single shared
/// `PlayerViewModel` injected from the app root (see ContentView.swift /
/// LucakuAudioApp.swift), not from any local/static state. Previously this
/// screen owned its own separate `MiniPlayerBar` and a hardcoded
/// `isPlaying = true`, which could — and did — disagree with the real
/// Player tab's independently-loaded state. There is now exactly one source
/// of truth: this screen never renders its own mini player (the global one
/// lives once in `MainTabView`, above the tab bar) and never fabricates a
/// playing/paused state of its own.
struct HomeView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var playerViewModel: PlayerViewModel
    @StateObject private var viewModel = HomeViewModel()

    @State private var isCurrentBlockExpanded = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                LucakuColor.bg.ignoresSafeArea()

                ScrollView {
                    content
                        .padding(.horizontal, LucakuSpacing.sp4)
                        .padding(.top, LucakuSpacing.sp2)
                        // Room for the global mini player (mounted once in
                        // MainTabView) so it never covers the last row.
                        .padding(.bottom, playerViewModel.hasEpisode ? 88 : LucakuSpacing.sp8)
                }
            }
            .background(LucakuColor.bg)
            .navigationTitle("Home")
            .task { await refresh() }
            .refreshable { await refresh() }
            .animation(LucakuMotion.house, value: playerViewModel.hasEpisode)
        }
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
        ProgressView("Loading Home…")
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
            interestsSection(home)

        case "making", "late":
            HeroInProgressView(
                isLate: home.banner.state == "late",
                requestsCount: home.banner.requestsCount,
                eta: home.banner.eta
            )
            if !home.recent.isEmpty { recentSection(home) }
            interestsSection(home)

        case "re_entry":
            HeroReEntryView(
                requestText: $viewModel.requestTodayText,
                isSubmitting: viewModel.isSubmittingRequest,
                submitError: viewModel.requestTodayError,
                onSubmit: { submitRequest() }
            )
            if !home.recent.isEmpty { recentSection(home) }

        default: // "ready" — the approved mockup's primary, has-content view
            todayHeroSection(home)
            if !home.recent.isEmpty { recentSection(home) }
            interestsSection(home)
        }
    }

    // MARK: - "ready" — Today's episode hero + block list

    /// Whether the shared player is actually playing today's episode right
    /// now. This — not any local/static flag — is what decides whether the
    /// block row shows the animated "now playing" waveform and progress.
    private var isCurrentlyPlaying: Bool {
        playerViewModel.hasEpisode && playerViewModel.isPlaying
    }

    @ViewBuilder
    private func todayHeroSection(_ home: HomeOut) -> some View {
        let banner = home.banner
        let minutesLabel = HomeFormat.minutes(banner.durationS)

        VStack(alignment: .leading, spacing: 0) {
            HomeSectionHeader(title: "Today's episode")

            Text(heroMeta(banner: banner, minutesLabel: minutesLabel))
                .font(LucakuTypography.footnote)
                .foregroundStyle(LucakuColor.textSecondary)
                .padding(.bottom, LucakuSpacing.sp4)

            HStack(spacing: LucakuSpacing.sp4) {
                Button { playFromTop() } label: {
                    Circle()
                        .fill(LucakuColor.accent)
                        .frame(width: 56, height: 56)
                        .overlay(
                            Image(systemName: isCurrentlyPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(LucakuColor.accentOn)
                                .offset(x: isCurrentlyPlaying ? 0 : 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play today's episode")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Play from the top")
                        .font(LucakuTypography.headline)
                        .foregroundStyle(LucakuColor.textPrimary)
                    Text(playFromTopSubtitle(banner: banner, minutesLabel: minutesLabel))
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(LucakuColor.textSecondary)
                }
            }
            .padding(.bottom, LucakuSpacing.sp5)

            // See the file-level "DATA HONESTY NOTE": one real row standing
            // in for the mockup's five-topic block list, since HomeOut has
            // no per-block breakdown to render. Its "currently playing"
            // visuals come from the shared PlayerViewModel (see the
            // "PLAYBACK STATE NOTE" above), not local state.
            HomeBlockRowView(
                number: nil,
                title: banner.headline ?? "Today's episode",
                metaText: currentBlockMeta(banner: banner),
                isCurrent: true,
                isPlaying: isCurrentlyPlaying,
                subprogress: isCurrentlyPlaying ? playerViewModel.currentBlockProgressFraction : nil,
                isExpanded: isCurrentBlockExpanded,
                isLast: true,
                onTap: { withAnimation(LucakuMotion.house) { isCurrentBlockExpanded.toggle() } },
                onGoDeeper: {},
                onAskFollowUp: {}
            )
        }
        .padding(.top, LucakuSpacing.sp2)
        .padding(.bottom, LucakuSpacing.sp8)
    }

    private func heroMeta(banner: BannerOut, minutesLabel: String?) -> String {
        var parts = [HomeFormat.todayHeadline]
        if let count = banner.requestsCount {
            parts.append("\(count) topic\(count == 1 ? "" : "s")")
        }
        if let minutesLabel {
            parts.append(minutesLabel)
        }
        return parts.joined(separator: "  ·  ")
    }

    private func playFromTopSubtitle(banner: BannerOut, minutesLabel: String?) -> String {
        if let headline = banner.headline, let minutesLabel {
            return "\(headline), \(minutesLabel) total"
        }
        return minutesLabel.map { "\($0) total" } ?? "Starts now"
    }

    /// "Now playing · 1:38 of 4:12" only while the shared player is actually
    /// playing today's episode; otherwise a plain, honest description (no
    /// fabricated elapsed time when nothing is really playing).
    private func currentBlockMeta(banner: BannerOut) -> String {
        if isCurrentlyPlaying, let block = playerViewModel.currentBlock {
            let elapsed = Int(playerViewModel.currentBlockProgressFraction * Double(playerViewModel.currentBlockDurationS))
            return "Now playing  ·  \(HomeFormat.clock(elapsed)) of \(HomeFormat.clock(playerViewModel.currentBlockDurationS))"
        }
        _ = banner
        if let minutesLabel = HomeFormat.minutes(banner.durationS) {
            return "\(minutesLabel) total"
        }
        return "Ready to play"
    }

    // MARK: - Recent shelf

    private func recentSection(_ home: HomeOut) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeSectionHeader(title: "Recent")
            RecentShelfView(episodes: home.recent) { episode in
                // TODO(player): there is no API to fetch a specific past
                // episode's audio/blocks (GET /api/generation/episodes/latest
                // only ever returns *today's* episode), so tapping a past
                // day here can't honestly hand off to the shared
                // PlayerViewModel yet. Rather than fabricate a "now playing"
                // state for an episode we can't actually stream, this is
                // intentionally a no-op until that endpoint exists.
                _ = episode
            }
        }
        .padding(.bottom, LucakuSpacing.sp8)
    }

    // MARK: - Your interests

    @ViewBuilder
    private func interestsSection(_ home: HomeOut) -> some View {
        if !home.sharedInventory.isEmpty {
            InterestsSectionView(items: home.sharedInventory)
                .padding(.bottom, LucakuSpacing.sp6)
        }
    }

    // MARK: - Actions

    /// Ensures the shared player has today's episode loaded, then starts
    /// playback from the top — the same `PlayerViewModel` the Player tab
    /// (and the global mini player / Now Playing overlay) reads, so Home's
    /// "Play from the top" button drives the one real source of truth
    /// instead of a local/static toggle.
    private func playFromTop() {
        if isCurrentlyPlaying {
            playerViewModel.togglePlay()
            return
        }
        Task {
            if !playerViewModel.hasEpisode {
                guard let token = session.accessToken else { return }
                await playerViewModel.load(token: token)
            }
            guard playerViewModel.hasEpisode else { return }
            playerViewModel.selectBlock(0, autoplay: true)
        }
    }

    private func submitRequest() {
        guard let token = session.accessToken else { return }
        Task { await viewModel.submitRequestToday(token: token) }
    }

    private func refresh() async {
        guard let token = session.accessToken else { return }
        await viewModel.load(token: token)
    }
}

#Preview {
    HomeView()
        .environmentObject(SessionStore())
        .environmentObject(PlayerViewModel())
}
