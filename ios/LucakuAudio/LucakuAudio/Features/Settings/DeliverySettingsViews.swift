import SwiftUI

// MARK: - 7.1-7.6 Delivery & voice settings
//
// Backed by GET/PATCH /api/profile through `SettingsViewModel` (voice,
// narration style, language, delivery time / timezone, max length).

struct DeliverySettingsPage: View {
    @ObservedObject var viewModel: SettingsViewModel
    @EnvironmentObject private var session: SessionStore
    @State private var showTimeWheel = false

    var body: some View {
        ProfilePage(title: "Delivery & voice", backTitle: "Back") {
            if case .loaded = viewModel.loadState {
                settingsBody
                saveBar
                    .padding(.top, 24)
                    .padding(.bottom, 96) // keeps Save clear of the mini player
            } else {
                unavailable
            }
        }
    }

    // MARK: Loaded

    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfileSectionLabel(text: "Delivery")
            ProfileCard {
                ProfileCardRow(title: "Daily delivery time", symbol: "clock") {
                    ProfileSwitch(isOn: $viewModel.hasDeliveryTime.animation())
                }
                if viewModel.hasDeliveryTime {
                    ProfileCardDivider(inset: 52)
                    ProfileCardRow(title: "Time") {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showTimeWheel.toggle() }
                        } label: {
                            Text(ProfileFormat.time12(viewModel.deliveryTime))
                                .font(.system(size: 17))
                                .foregroundStyle(LucakuColor.textPrimary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(LucakuColor.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    if showTimeWheel {
                        DatePicker("Time", selection: $viewModel.deliveryTime, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .frame(height: 160)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                }
                ProfileCardDivider(inset: 52)
                NavigationLink(value: ProfileRoute.timezone) {
                    ProfileCardRow(title: "Time zone", symbol: "globe") {
                        valueWithChevron(Self.friendly(viewModel.deliveryTimezone))
                    }
                }
                .buttonStyle(.plain)
                ProfileCardDivider(inset: 52)
                NavigationLink(value: ProfileRoute.maxLength) {
                    ProfileCardRow(title: "Max episode length", symbol: "timer") {
                        valueWithChevron(Self.lengthLabel(viewModel.maxLengthMinutes))
                    }
                }
                .buttonStyle(.plain)
            }
            ProfileNote(text: "Changing your delivery time reschedules your next episode; other changes apply from your next episode.")

            ProfileSectionLabel(text: "Voice")
            ProfileCard {
                ProfileCardRow(title: "Narration style", symbol: "bubble.left") {
                    Menu {
                        Picker("Narration style", selection: $viewModel.narrationStyle) {
                            ForEach(NarrationStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                    } label: {
                        menuLabel(viewModel.narrationStyle.displayName)
                    }
                }
                ProfileCardDivider(inset: 52)
                ProfileCardRow(title: "Voice ID", symbol: "waveform") {
                    TextField("Not set", text: $viewModel.voiceId)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(size: 17))
                        .foregroundStyle(LucakuColor.textSecondary)
                        .frame(maxWidth: 170)
                }
            }
            ProfileNote(text: "There's no voice catalogue yet. Enter a voice ID directly if you have one.")

            ProfileSectionLabel(text: "Language")
            ProfileCard {
                ProfileCardRow(title: "Language", symbol: "globe") {
                    Menu {
                        Picker("Language", selection: $viewModel.language) {
                            ForEach(ProfileLanguage.allCases) { lang in
                                Text(lang.displayName).tag(lang)
                            }
                        }
                    } label: {
                        menuLabel(viewModel.language.displayName)
                    }
                }
            }
            ProfileNote(text: "Applies from your next episode.")
        }
    }

    private func valueWithChevron(_ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 17))
                .foregroundStyle(LucakuColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LucakuColor.textTertiary)
        }
    }

    private func menuLabel(_ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 17))
                .foregroundStyle(LucakuColor.textSecondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LucakuColor.textSecondary)
        }
    }

    // MARK: Not loaded

    private var unavailable: some View {
        VStack(spacing: 8) {
            Text(unavailableTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(LucakuColor.textPrimary)
            Text(unavailableDetail)
                .font(.system(size: 15))
                .foregroundStyle(LucakuColor.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var unavailableTitle: String {
        switch viewModel.loadState {
        case .noProfile: return "Finish setup first"
        case .failed: return "Couldn't load your settings"
        default: return "Loading your settings..."
        }
    }

    private var unavailableDetail: String {
        switch viewModel.loadState {
        case .noProfile: return "Your profile hasn't been created yet. Complete onboarding first."
        case .failed(let message): return message
        default: return ""
        }
    }

    // MARK: Save bar (7.6 shows the confirmation messages)

    private var saveBar: some View {
        VStack(spacing: 8) {
            if let saveError = viewModel.saveError {
                Text(saveError)
                    .font(.system(size: 13))
                    .foregroundStyle(LucakuColor.destructive)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !viewModel.saveMessages.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.saveMessages.prefix(2), id: \.self) { message in
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(LucakuColor.textSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ProfilePrimaryButton(
                title: "Save changes",
                isLoading: viewModel.isSaving,
                isEnabled: viewModel.hasPendingChanges
            ) {
                guard let token = session.accessToken else { return }
                Task { await viewModel.save(token: token) }
            }
        }
    }

    static func friendly(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    static func lengthLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "No limit" }
        return "\(minutes) min"
    }
}

// MARK: - 7.4 Time zone

/// Real IANA identifiers (`TimeZone.knownTimeZoneIdentifiers`), searchable.
/// `delivery_timezone` accepts any valid IANA name server-side.
struct ProfileTimezonePage: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var identifiers: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers.sorted()
        guard !query.isEmpty else { return all }
        return all.filter { DeliverySettingsPage.friendly($0).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ProfilePage(title: "Time zone", backTitle: "Back") {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LucakuColor.textSecondary)
                TextField("Search", text: $query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 16))
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(LucakuColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 12)

            LazyVStack(spacing: 0) {
                ForEach(identifiers, id: \.self) { identifier in
                    Button {
                        viewModel.deliveryTimezone = identifier
                        dismiss()
                    } label: {
                        HStack {
                            Text(DeliverySettingsPage.friendly(identifier))
                                .font(.system(size: 16))
                                .foregroundStyle(LucakuColor.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            if identifier == viewModel.deliveryTimezone {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(LucakuColor.textPrimary)
                            }
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    ProfileSeparator()
                }
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - 7.5 Max episode length

struct ProfileMaxLengthPage: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    /// Convenient stops along `max_length_minutes` (plain `int | None` server-side);
    /// "No limit" maps to `nil`, which the view model sends as `clear_max_length`.
    private let presets: [Int?] = [nil, 5, 10, 15, 20, 30, 45, 60]

    var body: some View {
        ProfilePage(
            title: "Max episode length",
            subtitle: "A ceiling, never a target. Lucaku stops sooner when there's less to say.",
            backTitle: "Back"
        ) {
            VStack(spacing: 0) {
                ForEach(presets, id: \.self) { preset in
                    Button {
                        viewModel.maxLengthMinutes = preset
                        dismiss()
                    } label: {
                        HStack {
                            Text(preset.map { "\($0) minutes" } ?? "No limit")
                                .font(.system(size: 16))
                                .foregroundStyle(LucakuColor.textPrimary)
                            Spacer()
                            if preset == viewModel.maxLengthMinutes {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(LucakuColor.textPrimary)
                            }
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    ProfileSeparator()
                }
            }
            .padding(.top, 8)
        }
    }
}
