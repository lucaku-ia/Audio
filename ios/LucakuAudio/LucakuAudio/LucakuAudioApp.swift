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
                // Dark-first: a listening app used at night and in the car,
                // and the generated cover art only reads as rich against
                // near-black. LucakuColor's tokens already carry a full dark
                // palette; this pins the app to it.
                .preferredColorScheme(.dark)
        }
    }
}
