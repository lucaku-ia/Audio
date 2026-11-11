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

    /// GET /api/home already returns the last two weeks of episodes in `recent`,
    /// so History reuses it instead of a dedicated endpoint.
    /// TODO(backend): a dedicated paginated GET /api/episodes/history if History
    /// should ever go beyond the Home window.
    func loadHistory(token: String) async {
        if let home = try? await APIClient.shared.home(token: token) {
            history = home.recent
        }
        historyLoaded = true
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
