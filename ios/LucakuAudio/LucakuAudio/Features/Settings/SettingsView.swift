import SwiftUI

/// Profile tab, option A "YouTube style" (screens spec 7-8, demo 8.1-8.3, 9.x):
///
///  1. You (identity)
///  2. History carousel of previous episodes, each playable
///  3. Downloads card
///  4. Three rows, each opening its own page: Appearance & notifications,
///     Account & privacy, Help & feedback
///  5. A quiet Sign out, reachable in every load state
///
/// The struct keeps its historical name (`SettingsView`) so `ContentView` does
/// not change. Data comes from GET /api/profile + GET /api/auth/me
/// (`SettingsViewModel`) and GET /api/home (`ProfileStore`, History).
///
/// Sign out must never depend on a Profile loading: an account without one
/// would otherwise have no way out (the session survives reinstall via the
/// Keychain). It lives on the root page, outside any load-state switch.
struct SettingsView: View {
    /// Switches to the Interests tab (used by the "Edit topics" notice action).
    /// TODO: wire from `ContentView` (`SettingsView(onSeeInterests: { selection = .interests })`).
    var onSeeInterests: (() -> Void)?

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerViewModel
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var store = ProfileStore()
    @AppStorage(ProfilePrefs.notifRead) private var readRaw = ""
    @AppStorage(ProfilePrefs.remindOn) private var remindOn = true
    @AppStorage(ProfilePrefs.readyOn) private var readyOn = true
    @AppStorage("appearancePreference") private var appearanceRaw = AppearancePreference.system.rawValue

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    StatusBarFadeAnchor()
                    topBar
                    identity
                    if !store.playableHistory.isEmpty { historySection }
                    downloadsCard
                    rows
                    signOutButton
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24) // mini player + tab bar come from the safe area
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(LucakuColor.bg.ignoresSafeArea())
            .statusBarFade()
            .refreshable { await load() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ProfileRoute.self) { route in
                destination(for: route)
            }
            .task { await load() }
        }
        .tint(LucakuColor.textPrimary)
    }

    // MARK: - Pieces

    /// Bell with an unread badge, top right (opens Notifications).
    private var topBar: some View {
        HStack {
            Spacer()
            NavigationLink(value: ProfileRoute.notifications) {
                Image(systemName: "bell")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {
                        if unreadCount > 0 {
                            Text("\(unreadCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Capsule().fill(LucakuColor.destructive))
                                .overlay(Capsule().stroke(LucakuColor.bg, lineWidth: 2))
                                .offset(x: -2, y: 4)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(unreadCount > 0 ? "Notifications, \(unreadCount) new" : "Notifications")
        }
        .frame(height: 44)
    }

    private var identity: some View {
        HStack(spacing: 16) {
            Text(initials)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(LucakuColor.textPrimary)
                .frame(width: 72, height: 72)
                .background(Circle().fill(LucakuColor.fill))
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 26, weight: .bold))
                    .tracking(0.2)
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(1)
                Text(viewModel.me?.email ?? " ")
                    .font(.system(size: 15))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: ProfileRoute.history) {
                HStack(spacing: 2) {
                    Text("History")
                        .font(.system(size: 22, weight: .bold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Last 2 weeks")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LucakuColor.textSecondary)
                        .padding(.leading, 6)
                }
                .foregroundStyle(LucakuColor.textPrimary)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .padding(.top, 22)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(store.playableHistory) { episode in
                        historyTile(episode)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
        }
    }

    private func historyTile(_ episode: RecentEpisodeOut) -> some View {
        Button {
            guard let id = episode.episodeId else { return }
            profilePlayEpisode(id: id, coverSeed: episode.headline, session: session, player: player)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverArt(seed: episode.headline ?? "episode", cornerRadius: 8)
                    .frame(width: 128, height: 128)
                    .overlay(alignment: .bottomTrailing) {
                        Text(ProfileFormat.minutesLabel(episode.durationS))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                Text(episode.headline ?? "Your episode")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 128, alignment: .leading)
                Text(ProfileFormat.dayLabel(episode.date))
                    .font(.system(size: 12))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private var downloadsCard: some View {
        NavigationLink(value: ProfileRoute.downloads) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(LucakuColor.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloads")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(LucakuColor.textPrimary)
                    // TODO(backend): offline downloads are not implemented yet, so the
                    // count is always zero.
                    Text("Listen without data")
                        .font(.system(size: 13))
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(LucakuColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 22)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            NavigationLink(value: ProfileRoute.appearance) {
                ProfileRow(
                    symbol: "circle.lefthalf.filled",
                    title: "Appearance & notifications",
                    subtitle: "\(AppearancePreference(rawValue: appearanceRaw)?.displayName ?? "System") mode · notifications \(remindOn || readyOn ? "on" : "off") · \(viewModel.language.displayName)",
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
            NavigationLink(value: ProfileRoute.account) {
                ProfileRow(
                    symbol: "person.badge.shield.checkmark",
                    title: "Account & privacy",
                    subtitle: "\(viewModel.me?.email ?? "Your account") · password, terms, your data",
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
            NavigationLink(value: ProfileRoute.help) {
                ProfileRow(
                    symbol: "questionmark.circle",
                    title: "Help & feedback",
                    subtitle: "Report a problem or send us feedback",
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { ProfileSeparator().padding(.top, 6) }
    }

    private var signOutButton: some View {
        Button {
            Task { await signOut() }
        } label: {
            Text("Sign out")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LucakuColor.textSecondary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destination(for route: ProfileRoute) -> some View {
        switch route {
        case .history: ProfileHistoryPage(store: store)
        case .downloads: ProfileDownloadsPage()
        case .notifications:
            ProfileNotificationsPage(viewModel: viewModel, store: store, onSeeInterests: onSeeInterests)
        case .notificationSettings:
            ProfileNotificationSettingsPage(viewModel: viewModel, store: store)
        case .appearance: ProfileAppearancePage(viewModel: viewModel)
        case .account: ProfileAccountPage(viewModel: viewModel)
        case .help: ProfileHelpPage()
        case .delivery: DeliverySettingsPage(viewModel: viewModel)
        case .timezone: ProfileTimezonePage(viewModel: viewModel)
        case .maxLength: ProfileMaxLengthPage(viewModel: viewModel)
        }
    }

    // MARK: - Derived

    private var displayName: String {
        let name = viewModel.me?.nombre.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "You" : name
    }

    private var initials: String {
        let letters = displayName.split(separator: " ").prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }

    private var unreadCount: Int {
        let read = Set(readRaw.split(separator: ",").map(String.init))
        var count = 0
        if remindOn && viewModel.hasDeliveryTime && !read.contains("remind") { count += 1 }
        if readyOn && !store.playableHistory.isEmpty && !read.contains("ready") { count += 1 }
        return count
    }

    // MARK: - Actions

    private func load() async {
        guard let token = session.accessToken else { return }
        async let settings: Void = viewModel.load(token: token)
        async let history: Void = store.loadHistory(token: token)
        _ = await (settings, history)
    }

    private func signOut() async {
        if let token = session.accessToken {
            try? await APIClient.shared.logout(token: token)
        }
        session.clear()
    }
}

#Preview {
    SettingsView()
        .environmentObject(SessionStore())
        .environmentObject(PlayerViewModel())
}
