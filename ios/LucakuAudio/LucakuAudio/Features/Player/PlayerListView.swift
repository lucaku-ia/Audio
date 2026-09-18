import SwiftUI

/// The Player tab's root screen — player_v3.html's list screen ("Today").
/// Loads the real latest episode (`GET /api/generation/episodes/latest`) and
/// renders its blocks as a flat, tappable list per DESIGN_SPEC_V3.md's core
/// pattern. The persistent mini player itself is NOT rendered here — it's
/// mounted once above the tab bar in ContentView.swift's `MainTabView` so it
/// survives navigation across tabs, per the spec's "single global overlay"
/// rule.
struct PlayerListView: View {
    @EnvironmentObject private var session: SessionStore
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    switch viewModel.loadState {
                    case .idle, .loading:
                        ProgressView("Loading…")
                            .frame(maxWidth: .infinity, minHeight: 200)
                    case .failed(let message):
                        errorState(message)
                    case .loaded:
                        loadedContent
                    }
                }
                .padding(.bottom, 110) // clears the mini player, matching player_v3.html's .list-scroll
            }
            .background(LucakuColor.bg)
            .navigationBarHidden(true)
            .task { await refresh() }
            .refreshable { await refresh() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(LucakuTypography.subhead)
                .foregroundStyle(LucakuColor.textSecondary)
            Text("Today")
                .font(LucakuTypography.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(LucakuColor.textPrimary)
        }
        .padding(.horizontal, LucakuSpacing.sp4)
        .padding(.top, LucakuSpacing.sp2)
        .padding(.bottom, LucakuSpacing.sp3)
    }

    @ViewBuilder
    private var loadedContent: some View {
        if viewModel.hasEpisode {
            sectionLabel("Your research, queued")
            blockList

            if !viewModel.earlier.isEmpty {
                sectionLabel("Earlier")
                earlierList
            }

            caughtUpCard
        } else {
            caughtUpCard
        }
    }

    private var blockList: some View {
        VStack(spacing: 2) {
            ForEach(Array(viewModel.blocks.enumerated()), id: \.offset) { index, block in
                VStack(spacing: 0) {
                    BlockRowView(
                        index: index,
                        block: block,
                        isCurrent: index == viewModel.currentBlockIndex,
                        isPlaying: viewModel.isPlaying && index == viewModel.currentBlockIndex,
                        progressFraction: index == viewModel.currentBlockIndex
                            ? viewModel.currentBlockProgressFraction : 0,
                        isNextUp: index == viewModel.currentBlockIndex + 1,
                        action: {
                            withAnimation(LucakuMotion.house) {
                                viewModel.selectBlock(index)
                                viewModel.expandNowPlaying()
                            }
                        }
                    )
                    if index != viewModel.blocks.count - 1, index != viewModel.currentBlockIndex {
                        Divider()
                            .overlay(LucakuColor.borderSoft)
                            .padding(.leading, 44)
                    }
                }
            }
        }
        .padding(.horizontal, LucakuSpacing.sp3)
    }

    /// Earlier/previously-played EPISODES (not blocks) — `GET
    /// /api/search/history` has no per-block breakdown for past episodes, so
    /// these rows are display-only and not wired to open a block player.
    /// Styled to match `.block-row` for visual consistency with the mockup's
    /// single "Earlier" row, but intentionally inert on tap.
    private var earlierList: some View {
        VStack(spacing: 2) {
            ForEach(viewModel.earlier) { item in
                HStack(alignment: .top, spacing: LucakuSpacing.sp3) {
                    Text("").frame(width: 28, height: 44) // aligns with block-lead column
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.headline)
                            .font(LucakuTypography.body)
                            .foregroundStyle(LucakuColor.textPrimary)
                        HStack(spacing: 6) {
                            Text("Played · \(item.fecha)")
                            if let duration = item.durationS {
                                Circle().fill(LucakuColor.textTertiary).frame(width: 3, height: 3)
                                Text(duration.asMinutesSeconds)
                            }
                        }
                        .font(LucakuTypography.footnote)
                        .foregroundStyle(LucakuColor.textSecondary)
                    }
                }
                .padding(LucakuSpacing.sp3)
            }
        }
        .padding(.horizontal, LucakuSpacing.sp3)
    }

    /// Calm, non-apologetic empty state per DESIGN_SPEC_V3.md's "Empty state"
    /// section — matches player_v3.html's `.caught-up` card exactly, shown
    /// underneath the queue (or alone, when there's no episode at all yet).
    private var caughtUpCard: some View {
        VStack(alignment: .leading, spacing: LucakuSpacing.sp2) {
            Text("You're caught up.")
                .font(LucakuTypography.headline)
                .foregroundStyle(LucakuColor.textPrimary)
            Text("New answers land as your standing interests update — nothing pending right now.")
                .font(LucakuTypography.subhead)
                .foregroundStyle(LucakuColor.textSecondary)

            Button {
                Task { await refresh() }
            } label: {
                Label("Check for updates", systemImage: "arrow.clockwise")
                    .font(LucakuTypography.subhead)
                    .fontWeight(.semibold)
                    .foregroundStyle(LucakuColor.accent)
            }
            .frame(minHeight: 44, alignment: .leading)
        }
        .padding(LucakuSpacing.sp4)
        .background(LucakuColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: LucakuRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: LucakuRadius.card)
                .stroke(LucakuColor.borderSoft, lineWidth: 1)
        )
        .padding(.horizontal, LucakuSpacing.sp4)
        .padding(.top, LucakuSpacing.sp6)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(LucakuTypography.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(LucakuColor.textTertiary)
            .padding(.horizontal, LucakuSpacing.sp4)
            .padding(.top, LucakuSpacing.sp4)
            .padding(.bottom, LucakuSpacing.sp2)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text("Couldn't load your player").font(LucakuTypography.headline)
            Text(message)
                .font(LucakuTypography.footnote)
                .foregroundStyle(LucakuColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await refresh() } }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func refresh() async {
        guard let token = session.accessToken else { return }
        await viewModel.load(token: token)
    }
}

#Preview {
    PlayerListView(viewModel: PlayerViewModel())
        .environmentObject(SessionStore())
}
