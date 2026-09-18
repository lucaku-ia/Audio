import SwiftUI

/// Home screen — calls the real GET /api/home endpoint (via HomeViewModel /
/// APIClient, unchanged) and renders the response against the approved
/// home_v3.html design (see /tmp/lucaku_design/home_v3.html and
/// DESIGN_SPEC_V3.md). Visual tokens come from LucakuColor/Typography/
/// Spacing/Radius/Motion (DesignSystem/) — nothing here invents a color,
/// font size, spacing value, or radius.
///
/// DATA HONESTY NOTE (see HomeModels.swift / backend/app/api/routes/home.py):
/// `GET /api/home`'s `banner.blocks` (ready state only) now carries a real
/// per-block breakdown — `BlockSummaryOut`'s `id`/`request_id`/`sequence`/
/// `start_s`/`end_s`/`duration_s`/`summary`/`had_more`, one entry per block
/// in playback order. The block list below renders one real row per entry
/// (topic text + duration), replacing the earlier single synthesized "whole
/// episode" row this screen used before that field existed.
///
/// PLAYBACK STATE NOTE: the "currently playing" highlight and its waveform/
/// elapsed-time visuals read from the single shared `PlayerViewModel`
/// injected from the app root (see ContentView.swift / LucakuAudioApp.swift)
/// — there is still no server-side playback-position concept (home.py's own
/// docstring is explicit about this). When the shared player has an episode
/// loaded and playing, its `currentBlock` (matched by `start_s`/`end_s`,
/// since the Player's `BlockOut` model doesn't decode the real block `id`
/// yet) tells Home which row, if any, is actually playing. Previously this
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
    /// Reused as-is from the old Library tab (see LibraryViewModel.swift) —
    /// backs the "Generate episode now" affordance restored below. Library's
    /// own on-demand generation button had nowhere to live once the Library
    /// tab was removed (see ContentView.swift's file doc); Home's
    /// empty/no-episode state is the natural home for it.
    @StateObject private var generationViewModel = LibraryViewModel()

    /// Tapping a block row hands the tapped block up to whoever mounts this
    /// screen (MainTabView), which owns the shared `PlayerViewModel` — same
    /// "open Player at this block" responsibility the mini player's row-tap
    /// already has, just entering from Home instead. There's no Player tab
    /// any more, so this actually expands the Now Playing overlay.
    var onOpenBlock: (BlockSummaryOut) -> Void = { _ in }

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
            generateNowSection
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
    /// hero play/pause button and block rows show "playing" visuals.
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

            blockListSection(banner.blocks)
        }
        .padding(.top, LucakuSpacing.sp2)
        .padding(.bottom, LucakuSpacing.sp8)
    }

    // MARK: - Block list (real per-block rows — see file-level doc)

    @ViewBuilder
    private func blockListSection(_ blocks: [BlockSummaryOut]) -> some View {
        if blocks.isEmpty {
            // Defensive only — the backend always sends `blocks` for a
            // "ready" banner. Nothing fabricated if it ever doesn't.
            EmptyView()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    let current = isCurrentBlock(block)
                    HomeBlockRowView(
                        number: current ? nil : block.sequence + 1,
                        title: block.summary,
                        metaText: metaText(for: block, isCurrent: current),
                        isCurrent: current,
                        isPlaying: current,
                        subprogress: current ? playerViewModel.currentBlockProgressFraction : nil,
                        isExpanded: false,
                        isLast: index == blocks.count - 1,
                        onTap: { onOpenBlock(block) }
                    )
                }
            }
        }
    }

    /// Matches by `start_s`/`end_s` rather than `id` — the shared
    /// `PlayerViewModel`'s `BlockOut` model (Networking/Models/
    /// GenerationModels.swift, owned by the Player feature) doesn't decode
    /// the real backend block `id` yet, only synthesizing a local one from
    /// its start/end offsets. Both endpoints serialize the same `Block` rows
    /// via the backend's shared `_block_common_fields` helper, so start/end
    /// offsets are a reliable, real join key between the two screens today.
    private func isCurrentBlock(_ block: BlockSummaryOut) -> Bool {
        guard playerViewModel.hasEpisode, playerViewModel.isPlaying,
              let currentBlock = playerViewModel.currentBlock else { return false }
        return currentBlock.startS == block.startS && currentBlock.endS == block.endS
    }

    private func metaText(for block: BlockSummaryOut, isCurrent: Bool) -> String {
        guard isCurrent else { return HomeFormat.clock(block.durationS) }
        // No dedicated "elapsed within this block" property exists on
        // PlayerViewModel — derive it the same honest way, from the real
        // engine's currentTime minus this block's own real start_s offset
        // (never fabricated).
        let elapsed = max(0, Int(playerViewModel.currentTime) - block.startS)
        return "Now playing  ·  \(HomeFormat.clock(elapsed)) of \(HomeFormat.clock(block.durationS))"
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

    // MARK: - Generate episode now (restored from the removed Library tab)

    /// Library's "Generate today's episode now" button (POST
    /// /api/generation/run via LibraryViewModel.runGeneration, unchanged —
    /// see LibraryViewModel.swift) had nowhere left to live once the Library
    /// tab was removed (ContentView.swift's tab bar is now Home/Search/
    /// Interests/Settings only). Home's "you're caught up, nothing new yet"
    /// empty state is the most natural place for it: it's exactly the
    /// moment a customer would want to trigger generation on demand instead
    /// of waiting for the scheduled run.
    @ViewBuilder
    private var generateNowSection: some View {
        VStack(alignment: .leading, spacing: LucakuSpacing.sp2) {
            switch generationViewModel.generationState {
            case .idle, .failed:
                Button {
                    guard let token = session.accessToken else { return }
                    Task {
                        await generationViewModel.runGeneration(token: token)
                        await refresh()
                    }
                } label: {
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
                if case .failed(let message) = generationViewModel.generationState {
                    Text(message)
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(.red)
                }
            case .running:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Generating — this runs the real research → write → voice pipeline and can take a while.")
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(LucakuColor.textSecondary)
                }
            case .finished:
                EmptyView()
            }
        }
        .padding(.top, LucakuSpacing.sp2)
        .padding(.bottom, LucakuSpacing.sp6)
    }

    // MARK: - Actions

    /// Ensures the shared player has today's episode loaded, then starts
    /// playback from the top — the same `PlayerViewModel` the mini player /
    /// Now Playing overlay reads, so Home's "Play from the top" button
    /// drives the one real source of truth instead of a local/static toggle.
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
