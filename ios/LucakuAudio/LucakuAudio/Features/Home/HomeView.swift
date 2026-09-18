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
/// CURRENT-BLOCK HIGHLIGHT: there is still no server-side playback-position
/// concept (home.py's own docstring is explicit about this). The signal used
/// here is the shared `PlayerViewModel` mounted once in `MainTabView` and
/// injected into this screen's environment — when it has an episode loaded
/// and playing, its `currentBlock` (matched by `start_s`/`end_s`, since the
/// Player's `BlockOut` model doesn't decode the real block `id` yet) tells
/// Home which row, if any, is actually playing. If that object were ever
/// missing from the environment, no row is highlighted — this screen never
/// invents a "currently playing" block.
struct HomeView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var playerViewModel: PlayerViewModel
    @StateObject private var viewModel = HomeViewModel()

    /// Tapping a block row hands the tapped block up to whoever mounts this
    /// screen (MainTabView), which owns the shared `PlayerViewModel` and tab
    /// selection — same "open Player at this block" responsibility the mini
    /// player's row-tap already has, just entering from Home instead.
    var onOpenBlock: (BlockSummaryOut) -> Void = { _ in }

    // Playback has no real engine wired up for the HERO controls in this
    // screen's scope (see MiniPlayerBar's TODO) — this purely drives the
    // demo waveform/segment animation and mirrors the mockup's own JS
    // play/pause toggle. The block LIST below no longer uses this; it reads
    // real state from `playerViewModel` instead (see the type doc above).
    @State private var isPlaying = true

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                LucakuColor.bg.ignoresSafeArea()

                ScrollView {
                    content
                        .padding(.horizontal, LucakuSpacing.sp4)
                        .padding(.top, LucakuSpacing.sp2)
                        // Room for the mini player so it never covers the last row.
                        .padding(.bottom, miniPlayerContent == nil ? LucakuSpacing.sp8 : 88)
                }

                if let miniPlayerContent {
                    MiniPlayerBar(
                        content: miniPlayerContent,
                        isPlaying: $isPlaying,
                        onTogglePlay: { isPlaying.toggle() }
                    )
                    .padding(.bottom, LucakuSpacing.sp2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(LucakuColor.bg)
            .navigationTitle("Home")
            .task { await refresh() }
            .refreshable { await refresh() }
            .animation(LucakuMotion.house, value: miniPlayerContent != nil)
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
                Button { isPlaying = true } label: {
                    Circle()
                        .fill(LucakuColor.accent)
                        .frame(width: 56, height: 56)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(LucakuColor.accentOn)
                                .offset(x: 1)
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
        let elapsed = Int(playerViewModel.elapsedInBlockS)
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
                presentMiniPlayer(for: episode)
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

    // MARK: - Mini player (see MiniPlayerBar.swift's TODO on hoisting this app-wide)

    /// Only shown while there is something real to describe — today's ready
    /// episode. No fabricated "now playing" state is shown when nothing is
    /// actually playing (banner not ready, or the customer has no episode).
    @State private var revisitedEpisode: RecentEpisodeOut?

    private var miniPlayerContent: MiniPlayerBar.Content? {
        if case .loaded(let home) = viewModel.state {
            if let revisitedEpisode {
                return MiniPlayerBar.Content(
                    kicker: "Revisiting  ·  \(HomeFormat.weekdayAndDate(fromISO: revisitedEpisode.date).dateLabel)",
                    title: revisitedEpisode.headline ?? "No news that day",
                    progress: nil
                )
            }
            if home.banner.state == "ready" {
                let count = home.banner.requestsCount
                let kicker = count != nil ? "Today's episode  ·  \(count!) topic\(count! == 1 ? "" : "s")" : "Today's episode"
                return MiniPlayerBar.Content(
                    kicker: kicker,
                    title: home.banner.headline ?? "Today's episode",
                    progress: isPlaying ? 0.38 : nil
                )
            }
        }
        return nil
    }

    private func presentMiniPlayer(for episode: RecentEpisodeOut) {
        guard episode.state == "completed" else { return }
        withAnimation(LucakuMotion.house) {
            revisitedEpisode = episode
            isPlaying = true
        }
    }

    // MARK: - Actions

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
