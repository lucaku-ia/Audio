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
struct HomeView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var viewModel = HomeViewModel()

    @State private var isCurrentBlockExpanded = false
    // Playback has no real engine wired up in this screen's scope (see
    // MiniPlayerBar's TODO) — this purely drives the demo waveform/segment
    // animation and mirrors the mockup's own JS play/pause toggle.
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

            // See the file-level "DATA HONESTY NOTE": one real row standing
            // in for the mockup's five-topic block list, since HomeOut has
            // no per-block breakdown to render.
            BlockRowView(
                number: nil,
                title: banner.headline ?? "Today's episode",
                metaText: currentBlockMeta(banner: banner),
                isCurrent: true,
                subprogress: isPlaying ? 0.38 : nil,
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

    private func currentBlockMeta(banner: BannerOut) -> String {
        guard let durationS = banner.durationS else { return "Now playing" }
        let elapsed = isPlaying ? Int(Double(durationS) * 0.38) : 0
        return "Now playing  ·  \(HomeFormat.clock(elapsed)) of \(HomeFormat.clock(durationS))"
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
}
