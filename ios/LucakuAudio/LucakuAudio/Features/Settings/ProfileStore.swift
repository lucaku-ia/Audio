import SwiftUI
import UserNotifications

/// Data behind the Profile tab that is not part of `SettingsViewModel`:
/// the History carousel and the OS push-permission state.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var history: [RecentEpisodeOut] = []
    @Published private(set) var historyLoaded = false
    @Published private(set) var pushStatus: UNAuthorizationStatus = .notDetermined

    /// Playable previous episodes (synthesised "no news" days have no id).
    var playableHistory: [RecentEpisodeOut] {
        history.filter { $0.episodeId != nil && $0.state == "completed" }
    }

    /// Cursor for the next History page; nil when there is no more.
    private var historyCursor: String?
    private var isLoadingMoreHistory = false

    /// GET /api/episodes (cursor-paginated). Falls back to the Home `recent`
    /// window when the endpoint is unavailable (older backend / offline).
    func loadHistory(token: String) async {
        if let page = try? await APIClient.shared.episodeHistory(token: token) {
            history = page.items.map(Self.row(from:))
            historyCursor = page.nextCursor
        } else if let home = try? await APIClient.shared.home(token: token) {
            history = home.recent
            historyCursor = nil
        }
        historyLoaded = true
    }

    /// Loads the next page when `episode` is the last row shown.
    func loadMoreHistoryIfNeeded(after episode: RecentEpisodeOut, token: String) async {
        guard let cursor = historyCursor, !isLoadingMoreHistory,
              history.last?.id == episode.id else { return }
        isLoadingMoreHistory = true
        defer { isLoadingMoreHistory = false }
        guard let page = try? await APIClient.shared.episodeHistory(before: cursor, token: token) else { return }
        let known = Set(history.map(\.id))
        history += page.items.map(Self.row(from:)).filter { !known.contains($0.id) }
        historyCursor = page.nextCursor
    }

    private static func row(from item: EpisodeHistoryItem) -> RecentEpisodeOut {
        RecentEpisodeOut(
            date: item.date, headline: item.headline, durationS: item.durationS,
            style: item.style, state: item.state, episodeId: item.id
        )
    }

    func refreshPushStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        pushStatus = settings.authorizationStatus
    }

    /// Turning push on: ask the OS the first time, otherwise send the customer
    /// to the system Settings page (the OS only prompts once).
    func requestPush() async {
        if pushStatus == .notDetermined {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshPushStatus()
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            await UIApplication.shared.open(url)
        }
    }

    var isPushOn: Bool {
        pushStatus == .authorized || pushStatus == .provisional || pushStatus == .ephemeral
    }
}

/// Local notification preferences (screens spec 8.7).
/// TODO(backend): persist `remind` / `ready` / lead time on the Profile row and
/// have the scheduler honour them; until then they are device-local.
enum ProfilePrefs {
    static let remindOn = "profile.remindOn"
    static let remindLead = "profile.remindLead"
    static let readyOn = "profile.readyOn"
    static let notifRead = "profile.notifRead"
    static let downloadWifiOnly = "profile.downloadWifiOnly"

    static let leadOptions: [(minutes: Int, label: String)] = [
        (15, "15 min"), (30, "30 min"), (60, "1 h"), (120, "2 h"),
    ]
}
