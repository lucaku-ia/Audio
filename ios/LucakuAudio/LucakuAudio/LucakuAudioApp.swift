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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .environmentObject(playerViewModel)
                // Deliberately NOT pinned to a colour scheme: the app follows
                // the phone's own light/dark setting. LucakuColor carries a
                // full palette for both, and the approved mockups were signed
                // off in light. An earlier `.preferredColorScheme(.dark)` here
                // forced dark on everyone regardless of their system setting —
                // removed after the founder saw it on a light-mode device.
        }
    }
}
