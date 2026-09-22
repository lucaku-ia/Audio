import SwiftUI

/// App shell — routes between Login, Onboarding, and the main TabView.
///
/// A signed-in customer with `onboardingComplete == false` sees
/// `OnboardingView`, never the tab bar directly — matching the backend's own
/// routing rule (`TokenResponse`/`MeResponse.onboardingComplete`: "false ->
/// Onboarding, true -> Home", stated in both auth.py and this app's own
/// `TokenResponse` doc comment). A restored session (token read from the
/// Keychain on launch) doesn't know this flag yet, so it's confirmed once via
/// `GET /auth/me` before routing — see `SessionStore.refreshOnboardingStatus`.
struct ContentView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        if session.isAuthenticated {
            switch session.onboardingComplete {
            case true:
                MainTabView()
            case false:
                OnboardingView(onFinished: { session.markOnboardingComplete() })
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LucakuColor.bg)
                    .task { await session.refreshOnboardingStatus() }
            }
        } else {
            LoginView()
        }
    }
}

/// The main app shell once authenticated: Home / Search / Interests /
/// Settings, matching the approved design (see /tmp/lucaku_design/home_v3.html,
/// player_v3.html, search_interests_v3.html and DESIGN_SPEC_V3.md).
///
/// Per the design spec, the Player screen is NEVER its own tab. Instead a
/// single, persistent mini player (`MiniPlayerView`, player_v3.html's
/// `.miniplayer`) is mounted exactly ONCE here, above the tab bar, visible on
/// every tab, and tapping it expands into the full "Now Playing" overlay
/// (`NowPlayingView`) — an expansion of the mini player, not a navigation
/// push and not a separate tab.
///
/// Both the mini player and the Now Playing overlay are driven by the ONE
/// `PlayerViewModel` instance owned at the app root (`LucakuAudioApp`) and
/// injected via `.environmentObject()`. This replaces the previous
/// architecture, where the Player tab created its own private
/// `PlayerViewModel` and Home rendered a separate, static mini player
/// (`MiniPlayerBar`, now deleted) backed by local/hardcoded state — the two
/// disagreed about what was actually playing (Home said "Playing", the real
/// Player tab correctly said "Paused"). There is now exactly one source of
/// truth for playback state, and every screen (including Home's real
/// per-block list and its "currently playing" highlight) reads from it.
struct MainTabView: View {
    private enum Tab: Hashable {
        case home, search, interests, settings
    }

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var playerViewModel: PlayerViewModel
    @State private var selection: Tab = .home

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                // Home reads the shared `playerViewModel` via
                // `@EnvironmentObject` (inherited automatically from this
                // view's own environment — no explicit `.environmentObject()`
                // needed here) for its per-block "currently playing"
                // highlight, and hands tapped blocks back up to
                // `openInPlayer` below so tapping a row opens that exact
                // block in the shared player, mirroring the mini player's
                // own tap-to-open behavior. There's no Player tab to switch
                // to any more (see the type doc above), so this expands the
                // Now Playing overlay instead.
                HomeView(
                    onOpenBlock: { block in openInPlayer(block) },
                    onSeeInterests: { selection = .interests }
                )
                    .tabItem { Label("Home", systemImage: selection == .home ? "house.fill" : "house") }
                    .tag(Tab.home)

                SearchView()
                    .tabItem {
                        Label("Search", systemImage: selection == .search ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    }
                    .tag(Tab.search)

                InterestsView()
                    .tabItem {
                        Label("Interests", systemImage: selection == .interests ? "star.fill" : "star")
                    }
                    .tag(Tab.interests)

                SettingsView()
                    .tabItem { Label("Settings", systemImage: selection == .settings ? "gearshape.fill" : "gearshape") }
                    .tag(Tab.settings)
            }

            // Persistent mini player — mounted ONCE here, above the tab bar,
            // visible on every tab (Home, Search, Interests, Settings). Not
            // re-created per screen.
            if playerViewModel.hasEpisode && !playerViewModel.isNowPlayingExpanded {
                MiniPlayerView(viewModel: playerViewModel)
                    .padding(.bottom, 50) // clears the system tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(LucakuMotion.house, value: playerViewModel.isNowPlayingExpanded)
        .overlay {
            // Tapping the mini player expands into the full "Now Playing"
            // view — presented as an expansion of the mini player from the
            // app root, not a tab / navigation push.
            if playerViewModel.isNowPlayingExpanded {
                NowPlayingView(viewModel: playerViewModel)
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .task {
            // Load the shared player once at the app root so its state
            // (and Home's "currently playing" highlight, which reads the
            // same object) is correct no matter which tab the user opens
            // first, without depending on the Player tab having existed.
            guard !playerViewModel.hasEpisode, let token = session.accessToken else { return }
            await playerViewModel.load(token: token)
        }
    }

    /// Home tapped a real block row — load the shared `PlayerViewModel`'s
    /// episode if it isn't already, select the matching block (matched by
    /// start/end offset; see HomeView.swift's doc on why not `id`), and
    /// expand the Now Playing overlay so the tap actually lands on that
    /// block. There's no separate Player tab any more (see this type's file
    /// doc) — the mini player / Now Playing overlay mounted here is the one
    /// place playback is ever shown, so "open Player at this block" means
    /// "expand the overlay", not "switch tabs".
    private func openInPlayer(_ block: BlockSummaryOut) {
        Task {
            if !playerViewModel.hasEpisode, let token = session.accessToken {
                await playerViewModel.load(token: token)
            }
            if let index = playerViewModel.blocks.firstIndex(where: {
                $0.startS == block.startS && $0.endS == block.endS
            }) {
                playerViewModel.selectBlock(index)
            }
            withAnimation(LucakuMotion.house) {
                playerViewModel.isNowPlayingExpanded = true
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SessionStore())
        .environmentObject(PlayerViewModel())
}
