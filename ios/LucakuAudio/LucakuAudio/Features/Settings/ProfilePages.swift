import SwiftUI

// MARK: - Play helper

/// Opens an episode in the shared player (History rows and notices).
@MainActor
func profilePlayEpisode(
    id: String,
    coverSeed: String?,
    session: SessionStore,
    player: PlayerViewModel
) {
    guard let token = session.accessToken else { return }
    Task {
        if player.loadedEpisodeIdentifier == id, player.hasEpisode {
            withAnimation(LucakuMotion.house) { player.expandNowPlaying() }
            return
        }
        if await player.loadEpisode(id: id, token: token, autoplay: true, coverSeed: coverSeed) {
            withAnimation(LucakuMotion.house) { player.expandNowPlaying() }
        }
    }
}

// MARK: - 8.3 History

struct ProfileHistoryPage: View {
    @ObservedObject var store: ProfileStore
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        ProfilePage(title: "History", subtitle: "Kept for 2 weeks, your last 14 episodes.") {
            if store.history.isEmpty {
                Text(store.historyLoaded
                     ? "Your previous episodes will show up here."
                     : "Loading your episodes...")
                    .font(.system(size: 15))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.history.enumerated()), id: \.element.id) { index, episode in
                        if index > 0 { ProfileSeparator() }
                        historyRow(episode)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ episode: RecentEpisodeOut) -> some View {
        let playable = episode.episodeId != nil && episode.state == "completed"
        let caption = playable
            ? "\(ProfileFormat.dayLabel(episode.date)) · \(ProfileFormat.minutesLabel(episode.durationS))"
            : "\(ProfileFormat.dayLabel(episode.date)) · nothing new that day"
        Button {
            guard playable, let id = episode.episodeId else { return }
            profilePlayEpisode(id: id, coverSeed: episode.headline, session: session, player: player)
        } label: {
            HStack(spacing: 12) {
                if playable {
                    CoverArt(seed: episode.headline ?? "episode", cornerRadius: 6)
                        .frame(width: 48, height: 48)
                } else {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(LucakuColor.textTertiary)
                        .frame(width: 48, height: 48)
                        .background(LucakuColor.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(playable ? (episode.headline ?? "Your episode") : "No news")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(playable ? LucakuColor.textPrimary : LucakuColor.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundStyle(LucakuColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!playable)
    }
}

// MARK: - 8.2 Downloads

/// TODO(backend): offline downloads need a signed-audio download flow plus
/// local storage; there is no such endpoint or on-device cache yet, so this
/// page shows the empty state and keeps the Wi-Fi-only preference locally.
struct ProfileDownloadsPage: View {
    @AppStorage(ProfilePrefs.downloadWifiOnly) private var wifiOnly = true

    var body: some View {
        ProfilePage(title: "Downloads") {
            Text("Nothing downloaded yet. Tap the download icon on any episode.")
                .font(.system(size: 15))
                .foregroundStyle(LucakuColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)

            ProfileSeparator()
            HStack(spacing: 14) {
                ProfileIconTile(symbol: "wifi")
                Text("Download on Wi-Fi only")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                ProfileSwitch(isOn: $wifiOnly)
            }
            .frame(minHeight: 56)
            .padding(.vertical, 6)
            ProfileNote(text: "Nothing downloads on its own. Tap download on any episode to save it.")
                .padding(.leading, 54)
        }
    }
}

// MARK: - 9.7 Notifications

struct ProfileNotificationsPage: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var store: ProfileStore
    var onSeeInterests: (() -> Void)?

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var player: PlayerViewModel
    @AppStorage(ProfilePrefs.remindOn) private var remindOn = true
    @AppStorage(ProfilePrefs.remindLead) private var remindLead = 30
    @AppStorage(ProfilePrefs.readyOn) private var readyOn = true
    @AppStorage(ProfilePrefs.notifRead) private var readRaw = ""

    var body: some View {
        ProfilePage(title: "Notifications") {
            VStack(spacing: 12) {
                ProfileToggleRow(
                    title: "Remind me before research starts",
                    detail: "Coming soon. Reminders arrive once push is live for the app.",
                    isOn: .constant(false)
                )
                .disabled(true)
                .opacity(0.5)
                ProfileSeparator()
                ProfileToggleRow(
                    title: "When my episode is ready",
                    detail: "Coming soon. Reminders arrive once push is live for the app.",
                    isOn: .constant(false)
                )
                .disabled(true)
                .opacity(0.5)
                ProfileSeparator()
                ProfileToggleRow(
                    title: "Push notifications",
                    detail: pushDetail,
                    isOn: Binding(
                        get: { store.isPushOn },
                        set: { _ in Task { await store.requestPush() } }
                    )
                )
            }
            .padding(16)
            .background(LucakuColor.surface, in: RoundedRectangle(cornerRadius: LucakuRadius.card, style: .continuous))
            .padding(.top, 12)

            ProfileSectionLabel(text: "Recent")
            VStack(spacing: 0) {
                ForEach(Array(notices.enumerated()), id: \.element.id) { index, notice in
                    if index > 0 { ProfileSeparator() }
                    noticeRow(notice)
                }
                if notices.isEmpty {
                    Text("Nothing yet. Notices about your episodes will show up here.")
                        .font(.system(size: 14))
                        .foregroundStyle(LucakuColor.textSecondary)
                        .padding(.vertical, 14)
                }
            }
        }
        .task { await store.refreshPushStatus() }
    }

    // MARK: Derived copy

    private var researchStart: String? {
        ProfileFormat.shifted(viewModel.hasDeliveryTime ? Self.hhmm(viewModel.deliveryTime) : nil, byMinutes: -60)
    }

    private var remindAt: String? {
        ProfileFormat.shifted(researchStart, byMinutes: -remindLead)
    }

    private var pushDetail: String {
        switch store.pushStatus {
        case .denied: return "Off in iOS Settings. Tap to open them."
        case .notDetermined: return "Allow Lucaku to send these as push notifications."
        default: return "On. Manage sounds and banners in iOS Settings."
        }
    }

    private static func hhmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    // MARK: Recent notices

    private struct Notice: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let time: String
        let body: String
        let unreadEligible: Bool
    }

    /// TODO(backend): GET /api/notifications for the real notice feed (quiet days,
    /// late episodes). Until then only the two notices derivable from the
    /// customer's own settings are listed.
    private var notices: [Notice] {
        var list: [Notice] = []
        let deliveryHHmm = viewModel.hasDeliveryTime ? Self.hhmm(viewModel.deliveryTime) : nil
        if remindOn, let researchStart, let remindAt {
            list.append(Notice(
                id: "remind", symbol: "square.and.pencil",
                title: "Research starts at \(ProfileFormat.time12(researchStart))",
                time: ProfileFormat.time12(remindAt),
                body: "Your \(ProfileFormat.time12(deliveryHHmm)) episode is about to be researched. Want to change anything?",
                unreadEligible: true
            ))
        }
        if readyOn, let latest = store.playableHistory.first {
            list.append(Notice(
                id: "ready", symbol: "waveform",
                title: "Your episode is ready",
                time: ProfileFormat.time12(deliveryHHmm),
                body: latest.headline ?? "Your daily episode",
                unreadEligible: true
            ))
        }
        return list
    }

    private var readIds: Set<String> {
        Set(readRaw.split(separator: ",").map(String.init))
    }

    private func markRead(_ id: String) {
        var ids = readIds
        ids.insert(id)
        readRaw = ids.sorted().joined(separator: ",")
    }

    @ViewBuilder
    private func noticeRow(_ notice: Notice) -> some View {
        let unread = notice.unreadEligible && !readIds.contains(notice.id)
        HStack(alignment: .top, spacing: 12) {
            ProfileIconTile(symbol: notice.symbol)
                .overlay(alignment: .topTrailing) {
                    if unread {
                        Circle()
                            .fill(LucakuColor.destructive)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(LucakuColor.bg, lineWidth: 2))
                            .offset(x: 3, y: -3)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(notice.title)
                        .font(.system(size: 15, weight: unread ? .bold : .semibold))
                        .foregroundStyle(LucakuColor.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Text(notice.time)
                        .font(.system(size: 12))
                        .foregroundStyle(LucakuColor.textTertiary)
                        .lineLimit(1)
                }
                Text(notice.body)
                    .font(.system(size: 14))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .lineLimit(2)
                actions(for: notice)
            }
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { markRead(notice.id) }
    }

    @ViewBuilder
    private func actions(for notice: Notice) -> some View {
        HStack(spacing: 8) {
            if notice.id == "remind" {
                if let onSeeInterests {
                    noticeButton("Edit topics", symbol: "slider.horizontal.3", primary: true) {
                        markRead(notice.id)
                        onSeeInterests()
                    }
                }
                noticeButton("Looks good", symbol: "checkmark", primary: onSeeInterests == nil) {
                    markRead(notice.id)
                }
            } else if notice.id == "ready", let latest = store.playableHistory.first, let id = latest.episodeId {
                noticeButton("Play", symbol: "play.fill", primary: true) {
                    markRead(notice.id)
                    profilePlayEpisode(id: id, coverSeed: latest.headline, session: session, player: player)
                }
            }
        }
        .padding(.top, 8)
    }

    private func noticeButton(_ title: String, symbol: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13, weight: .bold))
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(primary ? LucakuColor.bg : LucakuColor.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Capsule().fill(primary ? LucakuColor.textPrimary : Color.clear))
            .overlay(Capsule().stroke(primary ? Color.clear : LucakuColor.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 9.1 Appearance & notifications

struct ProfileAppearancePage: View {
    @ObservedObject var viewModel: SettingsViewModel
    @EnvironmentObject private var session: SessionStore
    @AppStorage("appearancePreference") private var appearanceRaw = AppearancePreference.system.rawValue
    @AppStorage(ProfilePrefs.remindOn) private var remindOn = true
    @AppStorage(ProfilePrefs.remindLead) private var remindLead = 30
    @AppStorage(ProfilePrefs.readyOn) private var readyOn = true

    var body: some View {
        ProfilePage(title: "Appearance & notifications") {
            HStack(spacing: 10) {
                ForEach(AppearancePreference.allCases.sorted { Self.order($0) < Self.order($1) }) { option in
                    appearanceTile(option)
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 10)

            VStack(spacing: 0) {
                NavigationLink(value: ProfileRoute.notifications) {
                    ProfileRow(symbol: "bell", title: "Notifications", value: notificationsValue, showsChevron: true)
                }
                .buttonStyle(.plain)
                ProfileSeparator()
                // Language saves with the Save control on Delivery & voice.
                NavigationLink(value: ProfileRoute.delivery) {
                    ProfileRow(symbol: "globe", title: "Language", value: viewModel.language.displayName, showsChevron: true)
                }
                .buttonStyle(.plain)
                ProfileSeparator()
                NavigationLink(value: ProfileRoute.delivery) {
                    ProfileRow(
                        symbol: "clock", title: "Delivery & voice",
                        subtitle: "Time, time zone, length, narration, language",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private static func order(_ option: AppearancePreference) -> Int {
        switch option {
        case .light: return 0
        case .dark: return 1
        case .system: return 2
        }
    }

    private var notificationsValue: String { "Push" }

    private func appearanceTile(_ option: AppearancePreference) -> some View {
        let selected = appearanceRaw == option.rawValue
        return Button {
            appearanceRaw = option.rawValue
        } label: {
            VStack(spacing: 8) {
                AppearanceThumbnail(option: option)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .padding(6)
                    .background(LucakuColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(selected ? LucakuColor.textPrimary : LucakuColor.borderSoft, lineWidth: selected ? 2 : 1)
                    )
                HStack(spacing: 4) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(LucakuColor.textPrimary)
                    }
                    Text(option.displayName)
                        .font(.system(size: 14, weight: selected ? .bold : .medium))
                        .foregroundStyle(LucakuColor.textPrimary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Tiny mock of a screen in light, dark or half/half (system).
private struct AppearanceThumbnail: View {
    let option: AppearancePreference

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(background)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 4).fill(LucakuColor.episodeArt)
                        .frame(height: 28)
                    RoundedRectangle(cornerRadius: 3).fill(ink).frame(height: 6).padding(.trailing, 14)
                    RoundedRectangle(cornerRadius: 3).fill(ink.opacity(0.55)).frame(height: 6).padding(.trailing, 32)
                }
                .padding(9)
            }
    }

    private var ink: Color {
        switch option {
        case .light: return Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.85)
        case .dark: return Color.white.opacity(0.9)
        case .system: return Color.gray.opacity(0.9)
        }
    }

    private var background: AnyShapeStyle {
        switch option {
        case .light: return AnyShapeStyle(Color.white)
        case .dark: return AnyShapeStyle(Color(red: 17 / 255, green: 17 / 255, blue: 19 / 255))
        case .system:
            return AnyShapeStyle(LinearGradient(
                stops: [.init(color: .white, location: 0.5),
                        .init(color: Color(red: 17 / 255, green: 17 / 255, blue: 19 / 255), location: 0.5)],
                startPoint: .leading, endPoint: .trailing))
        }
    }
}

// MARK: - 9.2 Account & privacy (7.7 export, 7.8 delete)

struct ProfileAccountPage: View {
    @ObservedObject var viewModel: SettingsViewModel
    @EnvironmentObject private var session: SessionStore

    @State private var showDeleteConfirmation = false
    @State private var showExportShareSheet = false
    @State private var showPasswordAlert = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ProfilePage(title: "Account & privacy", backTitle: "Profile") {
            ProfileSectionLabel(text: "Account")
            VStack(spacing: 0) {
                ProfileRow(symbol: "person.text.rectangle", title: "Name", value: viewModel.me?.nombre ?? "Unavailable")
                ProfileSeparator()
                ProfileRow(symbol: "envelope", title: "Email", value: viewModel.me?.email ?? "Unavailable")
                ProfileSeparator()
                ProfileRow(
                    symbol: "arrow.right.circle", title: "Sign-in method",
                    value: viewModel.me?.authProvider.capitalized ?? "Unavailable"
                )
                ProfileSeparator()
                // TODO(backend): password change endpoint; local stub with the demo's chevron row.
                Button { showPasswordAlert = true } label: {
                    ProfileRow(symbol: "key", title: "Change password", showsChevron: true)
                }
                .buttonStyle(.plain)
            }

            ProfileSectionLabel(text: "Privacy")
            VStack(spacing: 0) {
                // TODO(backend): confirm the public terms / privacy URLs.
                Button { open("https://lucaku.app/terms") } label: {
                    ProfileRow(symbol: "doc.text", title: "Terms of service", showsChevron: true)
                }
                .buttonStyle(.plain)
                ProfileSeparator()
                Button { open("https://lucaku.app/privacy") } label: {
                    ProfileRow(symbol: "hand.raised", title: "Privacy policy", showsChevron: true)
                }
                .buttonStyle(.plain)
                ProfileSeparator()
                Button {
                    Task { await exportData() }
                } label: {
                    ProfileRow(
                        symbol: "square.and.arrow.up", title: "Export my data",
                        subtitle: "A JSON file with everything we hold about you.",
                        showsSpinner: viewModel.isExporting
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isExporting)
                ProfileSeparator()
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    ProfileRow(
                        symbol: "trash", title: "Delete account", destructive: true,
                        showsSpinner: viewModel.isDeletingAccount
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isDeletingAccount)
            }
        }
        .alert("Delete account?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { Task { await deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account, requests, and episodes. This can't be undone.")
        }
        .alert("Change password", isPresented: $showPasswordAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Password changes aren't available in the app yet.")
        }
        .alert("Couldn't delete account", isPresented: errorBinding($viewModel.deleteAccountError)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.deleteAccountError ?? "")
        }
        .alert("Couldn't export your data", isPresented: errorBinding($viewModel.exportError)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.exportError ?? "")
        }
        .sheet(isPresented: $showExportShareSheet, onDismiss: { viewModel.exportedFileURL = nil }) {
            if let url = viewModel.exportedFileURL {
                ProfileShareSheet(activityItems: [url])
            }
        }
        .onChange(of: viewModel.exportedFileURL) { _, newValue in
            showExportShareSheet = newValue != nil
        }
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { openURL(url) }
    }

    private func exportData() async {
        guard let token = session.accessToken else { return }
        await viewModel.exportData(token: token)
    }

    private func deleteAccount() async {
        guard let token = session.accessToken else { return }
        if await viewModel.deleteAccount(token: token) {
            session.clear()
        }
    }

    private func errorBinding(_ message: Binding<String?>) -> Binding<Bool> {
        Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )
    }
}

// MARK: - 9.3 Help & feedback

struct ProfileHelpPage: View {
    @State private var showTicketAlert = false
    @State private var showThanks = false

    var body: some View {
        ProfilePage(title: "Help & feedback") {
            VStack(spacing: 0) {
                Button { showTicketAlert = true } label: {
                    ProfileRow(symbol: "lifepreserver", title: "Help & report a problem", showsChevron: true)
                }
                .buttonStyle(.plain)
                ProfileSeparator()
                // TODO(backend): support ticket + feedback endpoints; both are local stubs.
                Button { showThanks = true } label: {
                    ProfileRow(symbol: "text.bubble", title: "Send feedback", showsChevron: true)
                }
                .buttonStyle(.plain)
            }
            ProfileNote(text: "Feedback on a specific story lives in the player (Useful / Not quite).")
                .padding(.leading, 54)
        }
        .alert("Tell us what happened", isPresented: $showTicketAlert) {
            Button("Create ticket") {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We'll open a support ticket and reply by email.")
        }
        .alert("Thanks", isPresented: $showThanks) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Lucaku will use this to improve.")
        }
    }
}

// MARK: - Share sheet (UIActivityViewController bridge, for data export)

struct ProfileShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
