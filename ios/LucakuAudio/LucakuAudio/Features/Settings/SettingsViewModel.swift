import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    enum LoadState {
        case idle
        case loading
        case loaded
        /// Onboarding never completed a Profile row yet (`GET /api/profile`
        /// returns 404 per the route's own docstring) — nothing to edit.
        case noProfile
        case failed(String)
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var me: MeResponse?

    // Editable fields, seeded from `ProfileOut` on load.
    @Published var voiceId: String = ""
    @Published var narrationStyle: NarrationStyle = .news
    @Published var language: ProfileLanguage = .es
    @Published var deliveryTime: Date = Date()
    @Published var hasDeliveryTime: Bool = false
    @Published var deliveryTimezone: String = TimeZone.current.identifier
    @Published var maxLengthMinutes: Int?

    /// Snapshot of what's currently persisted server-side, to diff against
    /// on save so only changed fields are sent (matches the backend's
    /// partial-update contract instead of re-sending everything every time).
    private var savedVoiceId: String?
    private var savedNarrationStyle: NarrationStyle = .news
    private var savedLanguage: ProfileLanguage = .es
    private var savedDeliveryTime: String?
    private var savedDeliveryTimezone: String = "America/Bogota"
    private var savedMaxLengthMinutes: Int?

    @Published var isSaving = false
    @Published var saveMessages: [String] = []
    @Published var saveError: String?

    @Published var isExporting = false
    @Published var exportedFileURL: URL?
    @Published var exportError: String?

    @Published var isDeletingAccount = false
    @Published var deleteAccountError: String?

    func load(token: String) async {
        loadState = .loading
        async let profileTask: ProfileOut? = try? APIClient.shared.getProfile(token: token)
        async let meTask = try? APIClient.shared.me(token: token)
        me = await meTask

        guard let profile = await profileTask else {
            // Distinguish "no profile yet" from a real transport/server error
            // by trying once more and surfacing the real error if there is one.
            do {
                let profile = try await APIClient.shared.getProfile(token: token)
                apply(profile)
                loadState = .loaded
            } catch APIError.server(let status, _) where status == 404 {
                loadState = .noProfile
            } catch {
                loadState = .failed(error.localizedDescription)
            }
            return
        }
        apply(profile)
        loadState = .loaded
    }

    private func apply(_ profile: ProfileOut) {
        voiceId = profile.voiceId ?? ""
        narrationStyle = profile.narrationStyle
        language = profile.language
        deliveryTimezone = profile.deliveryTimezone
        maxLengthMinutes = profile.maxLengthMinutes
        hasDeliveryTime = profile.deliveryTime != nil
        if let time = profile.deliveryTime, let date = Self.timeFormatter.date(from: time) {
            deliveryTime = date
        }

        savedVoiceId = profile.voiceId
        savedNarrationStyle = profile.narrationStyle
        savedLanguage = profile.language
        savedDeliveryTime = profile.deliveryTime
        savedDeliveryTimezone = profile.deliveryTimezone
        savedMaxLengthMinutes = profile.maxLengthMinutes
    }

    /// Builds a `SettingsBody` containing only the fields the user actually
    /// changed since the last load/save, per the PATCH endpoint's partial-
    /// update contract (unchanged fields shouldn't re-trigger their "applies
    /// from your next episode" message on every save).
    private func pendingChanges() -> SettingsBody? {
        var body = SettingsBody()
        var changed = false

        let trimmedVoice = voiceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let newVoiceId = trimmedVoice.isEmpty ? nil : trimmedVoice
        if newVoiceId != savedVoiceId {
            body.voiceId = newVoiceId
            changed = true
        }
        if narrationStyle != savedNarrationStyle {
            body.narrationStyle = narrationStyle
            changed = true
        }
        if language != savedLanguage {
            body.language = language
            changed = true
        }

        let newDeliveryTime = hasDeliveryTime ? Self.timeFormatter.string(from: deliveryTime) : nil
        if newDeliveryTime != savedDeliveryTime {
            body.deliveryTime = newDeliveryTime
            changed = true
        }
        if deliveryTimezone != savedDeliveryTimezone {
            body.deliveryTimezone = deliveryTimezone
            changed = true
        }
        if maxLengthMinutes != savedMaxLengthMinutes {
            if maxLengthMinutes == nil {
                body.clearMaxLength = true
            } else {
                body.maxLengthMinutes = maxLengthMinutes
            }
            changed = true
        }

        return changed ? body : nil
    }

    func save(token: String) async {
        guard let body = pendingChanges() else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let result = try await APIClient.shared.updateSettings(body, token: token)
            savedVoiceId = result.voiceId
            savedNarrationStyle = result.narrationStyle
            savedLanguage = result.language
            savedDeliveryTime = result.deliveryTime
            savedDeliveryTimezone = result.deliveryTimezone
            savedMaxLengthMinutes = result.maxLengthMinutes
            saveMessages = result.messages
        } catch {
            saveError = error.localizedDescription
        }
    }

    func exportData(token: String) async {
        isExporting = true
        exportError = nil
        defer { isExporting = false }
        do {
            let data = try await APIClient.shared.exportAccountData(token: token)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("lucaku-export-\(Int(Date().timeIntervalSince1970))")
                .appendingPathExtension("json")
            try data.write(to: url, options: .atomic)
            exportedFileURL = url
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Returns `true` on success so the view can navigate back to signed-out
    /// state; the caller is still responsible for clearing the session.
    @discardableResult
    func deleteAccount(token: String) async -> Bool {
        isDeletingAccount = true
        deleteAccountError = nil
        defer { isDeletingAccount = false }
        do {
            _ = try await APIClient.shared.deleteAccount(token: token)
            return true
        } catch {
            deleteAccountError = error.localizedDescription
            return false
        }
    }

    /// Converts between the backend's bare "HH:MM" wall-clock string and a
    /// `Date` for `DatePicker`. Deliberately left on the device's default
    /// time zone (not UTC) and used consistently for both directions, so the
    /// hour/minute the picker shows is exactly the hour/minute round-tripped
    /// to and from the server — the actual UTC offset is irrelevant since
    /// this never represents an instant, only a wall-clock time paired
    /// separately with `deliveryTimezone`.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
