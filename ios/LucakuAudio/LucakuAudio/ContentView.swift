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
    private enum Tab: Hashable {
        case home, library, settings
    }

    @State private var selection: Tab = .home

    var body: some View {
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

            SettingsView()
                .tabItem { Label("Settings", systemImage: selection == .settings ? "gearshape.fill" : "gearshape") }
                .tag(Tab.settings)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SessionStore())
}
