import SwiftUI

/// Settings tab. Native iOS grouped-list convention throughout
/// (`.insetGrouped`, standard disclosure/toggle/value row patterns) per
/// DESIGN_SPEC_V3.md's List/Table guidance — most rows are plain leading-icon
/// system rows on purpose (the spec's fill-for-active/outline-elsewhere icon
/// rule is for tab bars and filter chips, not a settings list). Lucaku's
/// design tokens (`LucakuColor`, `LucakuTypography`) are used only where this
/// screen actually diverges from the system default: the accent tint and the
/// section-scoped copy that isn't a stock `LabeledContent`/row style.
///
/// Every field here is backed by a real endpoint:
/// - GET/PATCH /api/profile (backend/app/api/routes/profile.py) — voice,
///   narration style, language, delivery time/timezone, max length.
/// - GET /api/auth/me — account identity.
/// - GET /api/account/export, DELETE /api/account
///   (backend/app/api/routes/account.py).
///
/// Deliberately NOT built, because the backend has nothing to back them
/// (see profile.py's own module docstring, "Deferred, and why"):
/// - Membership: PRD says "visible, disabled, labelled Coming soon" — a
///   pure client-side stub, shown below as a disabled row.
/// - Biometric unlock toggle: per-device Face ID/Touch ID state, not a
///   server preference — omitted entirely.
/// - Push notification permission: the PRD explicitly says this must be
///   read from OS state on open and never persisted/cached — there's no
///   server column for it by design, so it isn't shown here as a toggle.
/// - Voice picker as a catalogue/preview list: `voice_id` is a real,
///   free-form string field with no `GET /api/voices`-style catalogue
///   endpoint anywhere in the backend, so it's edited as a plain text field
///   rather than a fabricated picker of invented voice names.
struct SettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var viewModel = SettingsViewModel()
    @AppStorage("appearancePreference") private var appearanceRaw = AppearancePreference.system.rawValue

    @State private var showDeleteConfirmation = false
    @State private var showExportShareSheet = false

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.loadState {
                case .idle, .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .noProfile:
                    unavailableFallback(
                        title: "Finish setup to see Settings",
                        systemImage: "gearshape",
                        description: "Your profile hasn't been created yet — complete onboarding first."
                    )
                case .failed(let message):
                    unavailableFallback(
                        title: "Couldn't load Settings",
                        systemImage: "exclamationmark.triangle",
                        description: message
                    )
                case .loaded:
                    settingsList
                }
            }
            .navigationTitle("Settings")
            .task { await load() }
            .tint(LucakuColor.accent)
        }
    }

    // MARK: - Non-loaded states

    /// Settings' non-loaded states still have to offer the two things that
    /// don't depend on a Profile: Appearance (a purely local device
    /// preference) and Sign Out.
    ///
    /// Sign Out especially: without it, an account with no Profile had no way
    /// out of the app at all — no settings, no account switch, and not even a
    /// reinstall escape, since the session survives app deletion via the
    /// Keychain. It is the one control that must never be gated behind the
    /// very thing the customer is stuck on.
    ///
    /// Laid out by hand rather than putting a `ContentUnavailableView` in a
    /// VStack: that view expands to fill all available height, which pushes
    /// anything below it to the bottom of the screen, where the floating mini
    /// player covers it.
    private func unavailableFallback(
        title: String,
        systemImage: String,
        description: String
    ) -> some View {
        VStack(spacing: LucakuSpacing.sp4) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(LucakuColor.textTertiary)
            VStack(spacing: LucakuSpacing.sp2) {
                Text(title)
                    .font(LucakuTypography.title3)
                    .foregroundStyle(LucakuColor.textPrimary)
                Text(description)
                    .font(LucakuTypography.subhead)
                    .foregroundStyle(LucakuColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Picker("Appearance", selection: $appearanceRaw) {
                ForEach(AppearancePreference.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            .padding(.top, LucakuSpacing.sp2)
            Button("Sign Out", role: .destructive) {
                Task { await signOut() }
            }
            .font(LucakuTypography.body)
            .frame(minHeight: 44)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, LucakuSpacing.sp6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var settingsList: some View {
        List {
            accountSection
            deliverySection
            voiceSection
            appearanceSection
            languageSection
            membershipSection
            dataSection
            signOutSection
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .safeAreaInset(edge: .bottom) { saveBar }
        .alert("Delete account?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account, requests, and episodes. This can't be undone.")
        }
        .alert("Couldn't delete account", isPresented: errorAlertBinding(for: $viewModel.deleteAccountError)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.deleteAccountError ?? "")
        }
        .alert("Couldn't export your data", isPresented: errorAlertBinding(for: $viewModel.exportError)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.exportError ?? "")
        }
        .sheet(isPresented: $showExportShareSheet) {
            if let url = viewModel.exportedFileURL {
                ShareSheet(activityItems: [url])
            }
        }
        .onChange(of: viewModel.exportedFileURL) { _, newValue in
            showExportShareSheet = newValue != nil
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
            if let me = viewModel.me {
                LabeledContent("Name", value: me.nombre)
                LabeledContent("Email", value: me.email)
                LabeledContent("Sign-in method", value: me.authProvider.capitalized)
            } else {
                HStack {
                    Label("Account details unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Delivery (Profile.delivery_time / delivery_timezone / max_length_minutes)

    private var deliverySection: some View {
        Section {
            Toggle(isOn: $viewModel.hasDeliveryTime.animation()) {
                Label("Daily delivery time", systemImage: "clock")
            }
            if viewModel.hasDeliveryTime {
                DatePicker(
                    "Time",
                    selection: $viewModel.deliveryTime,
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            NavigationLink {
                TimezonePickerView(selection: $viewModel.deliveryTimezone)
            } label: {
                LabeledContent("Time zone", value: friendlyTimezone(viewModel.deliveryTimezone))
            }
            NavigationLink {
                MaxLengthPickerView(selection: $viewModel.maxLengthMinutes)
            } label: {
                LabeledContent("Max episode length", value: maxLengthLabel(viewModel.maxLengthMinutes))
            }
        } header: {
            Text("Delivery")
        } footer: {
            Text("Changing your delivery time reschedules your next episode; other changes apply from your next episode.")
        }
    }

    // MARK: - Voice / narration (Profile.voice_id / narration_style)

    private var voiceSection: some View {
        Section {
            Picker(selection: $viewModel.narrationStyle) {
                ForEach(NarrationStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            } label: {
                Label("Narration style", systemImage: "text.bubble")
            }

            LabeledContent {
                TextField("Not set", text: $viewModel.voiceId)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } label: {
                Label("Voice ID", systemImage: "waveform")
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("There's no voice catalogue yet — enter a voice ID directly if you have one.")
        }
    }

    // MARK: - Language (Cliente.idioma / Profile.language)

    /// Local device preference, so unlike every other section here it needs no
    /// Profile and no network call — which is why it's also offered in the
    /// no-profile state below.
    private var appearanceSection: some View {
        Section {
            Picker(selection: $appearanceRaw) {
                ForEach(AppearancePreference.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
        } footer: {
            Text("\"System\" follows your phone's own light or dark setting.")
        }
    }

    private var languageSection: some View {
        Section {
            Picker(selection: $viewModel.language) {
                ForEach(ProfileLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            } label: {
                Label("Language", systemImage: "globe")
            }
        } footer: {
            Text("Updates the app immediately; episodes reflect it from the next one.")
        }
    }

    // MARK: - Membership (client-side stub — PRD: "visible, disabled, labelled Coming soon")

    private var membershipSection: some View {
        Section {
            HStack {
                Label("Membership", systemImage: "star")
                Spacer()
                Text("Coming soon")
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Data & account (backend/app/api/routes/account.py)

    private var dataSection: some View {
        Section("Data & Privacy") {
            Button {
                Task { await exportData() }
            } label: {
                HStack {
                    Label("Export my data", systemImage: "square.and.arrow.up")
                    Spacer()
                    if viewModel.isExporting {
                        ProgressView()
                    }
                }
            }
            .disabled(viewModel.isExporting)

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                HStack {
                    Label("Delete account", systemImage: "trash")
                    Spacer()
                    if viewModel.isDeletingAccount {
                        ProgressView()
                    }
                }
            }
            .disabled(viewModel.isDeletingAccount)
        }
    }

    // MARK: - Sign out

    private var signOutSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                Task { await signOut() }
            }
        }
    }

    // MARK: - Save bar

    @ViewBuilder
    private var saveBar: some View {
        VStack(spacing: LucakuSpacing.sp2) {
            if let saveError = viewModel.saveError {
                Text(saveError)
                    .font(LucakuTypography.footnote)
                    .foregroundStyle(.red)
            } else if !viewModel.saveMessages.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.saveMessages, id: \.self) { message in
                        Text(message)
                            .font(LucakuTypography.footnote)
                            .foregroundStyle(LucakuColor.textSecondary)
                    }
                }
            }
            Button {
                Task { await save() }
            } label: {
                if viewModel.isSaving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Save Changes")
                        .font(LucakuTypography.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(LucakuColor.accent)
            .disabled(viewModel.isSaving)
        }
        .padding(.horizontal, LucakuSpacing.sp4)
        .padding(.vertical, LucakuSpacing.sp3)
        .background(.bar)
    }

    // MARK: - Actions

    private func load() async {
        guard let token = session.accessToken else { return }
        await viewModel.load(token: token)
    }

    private func save() async {
        guard let token = session.accessToken else { return }
        await viewModel.save(token: token)
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

    private func signOut() async {
        if let token = session.accessToken {
            try? await APIClient.shared.logout(token: token)
        }
        session.clear()
    }

    // MARK: - Formatting helpers

    private func friendlyTimezone(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    private func maxLengthLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "No limit" }
        return "\(minutes) min"
    }

    /// Bridges an `Error?`-carrying `@Published` optional String into an
    /// `isPresented: Bool` binding for `.alert`, clearing it on dismiss.
    private func errorAlertBinding(for message: Binding<String?>) -> Binding<Bool> {
        Binding(
            get: { message.wrappedValue != nil },
            set: { isPresented in if !isPresented { message.wrappedValue = nil } }
        )
    }
}

// MARK: - Time zone picker

/// A curated, real IANA identifier list (from `TimeZone.knownTimeZoneIdentifiers`,
/// not invented) filtered down to one representative per region so the list
/// stays scannable — `delivery_timezone` accepts any valid IANA name
/// server-side (validated with `zoneinfo.ZoneInfo` in profile.py), this is
/// just a friendlier way to pick one than free text entry.
private struct TimezonePickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    private var identifiers: [String] {
        TimeZone.knownTimeZoneIdentifiers.sorted()
    }

    var body: some View {
        List {
            ForEach(identifiers, id: \.self) { identifier in
                Button {
                    selection = identifier
                    dismiss()
                } label: {
                    HStack {
                        Text(identifier.replacingOccurrences(of: "_", with: " "))
                            .foregroundStyle(.primary)
                        Spacer()
                        if identifier == selection {
                            Image(systemName: "checkmark")
                                .foregroundStyle(LucakuColor.accent)
                        }
                    }
                }
            }
        }
        .navigationTitle("Time Zone")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Max length picker

private struct MaxLengthPickerView: View {
    @Binding var selection: Int?
    @Environment(\.dismiss) private var dismiss

    /// Presets are just convenient stops along `max_length_minutes` (a plain
    /// `int | None` server-side, no enum) — "No limit" maps to `nil`, which
    /// the view model turns into `clear_max_length` on save.
    private let presets: [Int?] = [nil, 10, 15, 20, 30, 45, 60]

    var body: some View {
        List {
            ForEach(presets, id: \.self) { preset in
                Button {
                    selection = preset
                    dismiss()
                } label: {
                    HStack {
                        Text(preset.map { "\($0) minutes" } ?? "No limit")
                            .foregroundStyle(.primary)
                        Spacer()
                        if preset == selection {
                            Image(systemName: "checkmark")
                                .foregroundStyle(LucakuColor.accent)
                        }
                    }
                }
            }
        }
        .navigationTitle("Max Episode Length")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Share sheet (UIActivityViewController bridge, for data export)

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    SettingsView()
        .environmentObject(SessionStore())
}
