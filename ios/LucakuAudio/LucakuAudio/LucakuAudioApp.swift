import SwiftUI

@main
struct LucakuAudioApp: App {
    @StateObject private var session = SessionStore()

    // Single source of truth for playback state, owned here at the app
    // root and injected via `.environmentObject()`. Previously the Player
    // tab created its own `PlayerViewModel` inside `MainTabView` while
    // Home rendered a separate, static mini player backed by local state —
    // the two disagreed about what was actually playing. Owning the one
    // instance here (outliving auth-state changes and tab switches) is the
    // fix: every screen that needs playback state reads/writes this same
    // object via `@EnvironmentObject`.
    @StateObject private var playerViewModel = PlayerViewModel()

    /// Per-device light/dark override; `.system` means "follow the phone".
    @AppStorage("appearancePreference") private var appearanceRaw = AppearancePreference.system.rawValue

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .environmentObject(playerViewModel)
                // Follows the phone's own setting by default (.system → nil),
                // overridable per device from Settings → Appearance. An earlier
                // build hardcoded `.preferredColorScheme(.dark)` here, which
                // forced dark even on a phone set to light.
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
