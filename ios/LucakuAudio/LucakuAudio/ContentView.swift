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
            // `if/else` rather than `switch` over `Bool?` — the compiler
            // doesn't accept bare `true`/`false`/`nil` case patterns as
            // provably exhaustive over an Optional<Bool> ("switch must be
            // exhaustive"), even though they cover every case in practice.
            if session.onboardingComplete == true {
                MainTabView()
            } else if session.onboardingComplete == false {
                OnboardingView(onFinished: { session.markOnboardingComplete() })
            } else {
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

/// The main app shell once authenticated: Home / Interests / Profile,
/// matching the approved design (see /tmp/lucaku_design/home_v3.html,
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
        case home, interests, profile
    }

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var playerViewModel: PlayerViewModel
    @State private var selection: Tab = .home

    var body: some View {
        TabView(selection: $selection) {
                // Home reads the shared `playerViewModel` via
                // `@EnvironmentObject` (inherited from this view's own
                // environment). "Edit" on its "Your Lucaku" card switches to
                // the Interests tab.
                HomeView(onSeeInterests: { selection = .interests })
                    .tabItem { Label("Home", systemImage: selection == .home ? "house.fill" : "house") }
                    .tag(Tab.home)

                InterestsView()
                    .tabItem {
                        Label("Interests", systemImage: selection == .interests ? "star.fill" : "star")
                    }
                    .tag(Tab.interests)

                // Profile, option A (screens spec 7-8): the existing settings
                // content under the "Profile" title for now.
                SettingsView(onSeeInterests: { selection = .interests })
                    .tabItem { Label("Profile", systemImage: selection == .profile ? "person.fill" : "person") }
                    .tag(Tab.profile)
        }
        // The brand accent, not the system blue. Without this the selected
        // tab, and every other control that inherits the tint, renders in
        // iOS's default accent and the app stops looking like itself.
        .tint(LucakuColor.accent)
        // Persistent mini player — mounted ONCE here, above the tab bar,
        // visible on every tab (Home, Interests, Profile), never re-created
        // per screen.
        //
        // It used to be a ZStack overlay with `.padding(.bottom, 50)`. An
        // overlay floats over the content *and* over the tab bar's own hit
        // area, so the bar's top edge stopped responding to taps, and every
        // screen had to guess the bar's height to keep its last rows clear —
        // ContentView 50, HomeView 96, PlayerListView 110, SettingsView 140:
        // four different guesses at one layout, none of them right.
        .modifier(MiniPlayerHost(viewModel: playerViewModel))
        .animation(LucakuMotion.house, value: playerViewModel.isNowPlayingExpanded)
        .animation(LucakuMotion.house, value: playerViewModel.hasEpisode)
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

/// Mounts the persistent mini player above the tab bar.
///
/// On iOS 26 and later the system owns this slot: `tabViewBottomAccessory`
/// is the platform's own mini-player API (it is what Music and Podcasts sit
/// in), so the accessory gets the floating bar's glass material, the correct
/// placement above the bar, the morph into and out of the bar as it shows and
/// hides, and — the part we cannot reproduce by hand — the tab bar's hit area
/// stays the tab bar's. The content it inserts is also removed from each
/// tab's safe area automatically, so no screen has to know the bar's height.
///
/// Before iOS 26 the tab bar is the classic opaque strip and there is no
/// accessory slot, so a bottom `safeAreaInset` gives the same result: laid
/// out above the bar rather than over it, and propagated into every tab's
/// scroll view as an inset.
struct MiniPlayerHost: ViewModifier {
    @ObservedObject var viewModel: PlayerViewModel

    private var isVisible: Bool {
        viewModel.hasEpisode && !viewModel.isNowPlayingExpanded
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabViewBottomAccessory {
                if isVisible {
                    // The system draws the glass behind it, so the card's own
                    // surface and shadow are switched off.
                    MiniPlayerView(viewModel: viewModel, drawsOwnChrome: false)
                }
            }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if isVisible {
                    MiniPlayerView(viewModel: viewModel)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SessionStore())
        .environmentObject(PlayerViewModel())
}
