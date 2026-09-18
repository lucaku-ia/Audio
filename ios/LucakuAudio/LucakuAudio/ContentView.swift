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

/// Tab icons follow the standard SF Symbols convention: filled variant for
/// the active tab, outline for inactive ones. SwiftUI's `TabView` doesn't do
/// this swap automatically for arbitrary symbol names, so each tab picks its
/// own icon based on the current selection.
struct MainTabView: View {
    // ---- Player screen integration hook (iOS Player screen work) --------
    // Small, self-contained addition: a `.player` tab plus one shared
    // `PlayerViewModel` so the mini player / Now Playing overlay can be
    // mounted ONCE here, above the TabView, and survive tab navigation per
    // DESIGN_SPEC_V3.md's "single global overlay" rule. Nothing above this
    // block (HomeView, HomeViewModel) was touched. If HomeView later grows
    // its own mini-player, this is the seam to unify at.
    private enum Tab: Hashable {
        case home, library, player, settings
    }

    @State private var selection: Tab = .home
    @StateObject private var playerViewModel = PlayerViewModel()
    // -----------------------------------------------------------------------

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                HomeView()
                    .tabItem { Label("Home", systemImage: selection == .home ? "house.fill" : "house") }
                    .tag(Tab.home)

                LibraryView()
                    .tabItem {
                        Label(
                            "Library",
                            systemImage: selection == .library ? "square.stack.3d.up.fill" : "square.stack.3d.up"
                        )
                    }
                    .tag(Tab.library)

                // ---- Player tab (integration hook, see comment above) ----
                PlayerListView(viewModel: playerViewModel)
                    .tabItem {
                        Label("Player", systemImage: selection == .player ? "waveform.circle.fill" : "waveform.circle")
                    }
                    .tag(Tab.player)
                // ------------------------------------------------------------

                SettingsView()
                    .tabItem { Label("Settings", systemImage: selection == .settings ? "gearshape.fill" : "gearshape") }
                    .tag(Tab.settings)
            }

            // ---- Persistent mini player overlay (integration hook) ----
            // Mounted once above the TabView so it survives tab switches,
            // per DESIGN_SPEC_V3.md. Sits just above the tab bar.
            if playerViewModel.hasEpisode && !playerViewModel.isNowPlayingExpanded {
                MiniPlayerView(viewModel: playerViewModel)
                    .padding(.bottom, 50) // clears the system tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // ---------------------------------------------------------------
        }
        .animation(LucakuMotion.house, value: playerViewModel.isNowPlayingExpanded)
        .overlay {
            // ---- Now Playing full-screen expansion (integration hook) ----
            if playerViewModel.isNowPlayingExpanded {
                NowPlayingView(viewModel: playerViewModel)
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
            // -----------------------------------------------------------------
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SessionStore())
}
