import SwiftUI

/// App shell — routes between the login screen and the main TabView based on
/// whether a bearer token is stored.
struct ContentView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        if session.isAuthenticated {
            MainTabView()
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
/// truth for playback state, and every screen (including Home's block-list
/// "currently playing" highlight) reads from it.
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
                HomeView()
                    .tabItem { Label("Home", systemImage: selection == .home ? "house.fill" : "house") }
                    .tag(Tab.home)

                // TODO: replace with real Search screen (see PR from concurrent work).
                // search_interests_v3.html's Search tab (recent searches, suggested
                // topics, episode-history search, "add as new interest") has no real
                // SwiftUI implementation yet anywhere in this codebase — that is
                // separate, concurrent work. This placeholder exists only so the tab
                // bar structure matches the approved design and the app doesn't crash.
                SearchPlaceholderView()
                    .tabItem {
                        Label("Search", systemImage: selection == .search ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    }
                    .tag(Tab.search)

                // TODO: replace with real Interests screen (see PR from concurrent work).
                // Same situation as Search above — no real SwiftUI implementation yet.
                InterestsPlaceholderView()
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
}

/// Minimal stand-in for the Search tab. search_interests_v3.html has no real
/// SwiftUI implementation yet — that's separate, concurrent work — so this
/// exists purely to keep the tab bar structure correct.
private struct SearchPlaceholderView: View {
    var body: some View {
        NavigationStack {
            Text("Search")
                .foregroundStyle(LucakuColor.textSecondary)
                .navigationTitle("Search")
        }
    }
}

/// Minimal stand-in for the Interests tab. Same situation as Search above.
private struct InterestsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            Text("Interests")
                .foregroundStyle(LucakuColor.textSecondary)
                .navigationTitle("Interests")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SessionStore())
        .environmentObject(PlayerViewModel())
}
