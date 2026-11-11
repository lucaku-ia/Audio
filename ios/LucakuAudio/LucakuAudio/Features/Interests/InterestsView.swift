import SwiftUI

/// Interests — the clickable prototype's redesign, which the file this
/// replaces predates (its own comment said "the overall direction is still
/// under review, spec alternatives A-D"; the prototype settled it).
///
/// The screen is an extension of the onboarding chat rather than a library
/// browser. Three parts, top to bottom:
///
/// 1. **Your episode**, as four tiles — ready at, length, style, voice. These
///    are the four things that decide what arrives tomorrow morning, so they
///    sit above what you follow rather than below it.
/// 2. **You follow**, grouped by category, as chips inside one card. Edit
///    turns the chips into removable ones; removing offers an Undo.
/// 3. **Lucaku, docked above the tab bar** — the same composer as onboarding.
///    Adding, removing and changing anything is a sentence, not a form.
///
/// What this drops from the previous version: the search field, the "Your
/// topics" gradient tiles, "Suggested for you", "Browse all" and "Recently
/// removed". Browsing a catalogue was the old model; the prototype replaced
/// it with telling Lucaku what you want in words.
struct InterestsView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var viewModel = InterestsViewModel()
    @StateObject private var speech = SpeechService()

    @FocusState private var composerFocused: Bool
    @State private var isEditing = false
    @State private var showTimeWheel = false
    @State private var wheelTime = Date()

    private let tileColumns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        Group {
            switch viewModel.loadState {
            case .idle, .loading:
                ProgressView().tint(LucakuColor.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView("Couldn't load Interests", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .loaded:
                content
            }
        }
        .background(LucakuColor.bg.ignoresSafeArea())
        .task { await load() }
        .alert("Couldn't update interests", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: speech.transcript) { _, text in
            if speech.isListening { viewModel.freeTextQuery = text }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            StatusBarFadeAnchor()
            VStack(alignment: .leading, spacing: 0) {
                Text("Interests")
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(LucakuColor.textPrimary)
                    .padding(.top, 10)

                Text("What goes into your daily episode.")
                    .font(.system(size: 15))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .padding(.top, 2)

                sectionLabel("Your episode")
                    .padding(.top, 22)

                LazyVGrid(columns: tileColumns, spacing: 8) {
                    ForEach(episodeTiles) { tile in
                        EpisodeSettingTile(tile: tile)
                    }
                }

                Text(researchNote)
                    .font(.system(size: 13))
                    .foregroundStyle(LucakuColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.horizontal, 2)

                followHeader
                    .padding(.top, 22)

                followCard

                if let undo = viewModel.undoItem {
                    undoRow(undo)
                        .padding(.top, 10)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .statusBarFade()
        .safeAreaInset(edge: .bottom, spacing: 0) { dock }
        .sheet(isPresented: $showTimeWheel) { timeWheelSheet }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(LucakuColor.textSecondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 1 · Your episode

    /// "Research starts at 6:00 AM. Changes apply from your next episode." —
    /// the hour before delivery is when the pipeline actually runs, so this is
    /// the real deadline for a change to land in tomorrow's episode.
    private var researchNote: String {
        guard let time = viewModel.deliveryTime, let start = Self.subtractHour(from: time) else {
            return "Changes apply from your next episode."
        }
        return "Research starts at \(Self.display(start)). Changes apply from your next episode."
    }

    private var episodeTiles: [EpisodeTile] {
        [
            EpisodeTile(id: "time", icon: "clock", label: "Ready at",
                        value: viewModel.deliveryTime.map(Self.display) ?? "Not set",
                        menu: nil, action: openTimeWheel),
            EpisodeTile(id: "length", icon: "timer", label: "Length",
                        value: viewModel.maxLengthMinutes.map { "\($0) min" } ?? "No limit",
                        menu: .length, action: nil),
            EpisodeTile(id: "style", icon: "book", label: "Style",
                        value: viewModel.narrationStyle.shortLabel, menu: .style, action: nil),
            EpisodeTile(id: "voice", icon: "mic", label: "Voice",
                        value: viewModel.voiceLabel, menu: .voice, action: nil),
        ]
    }

    /// A tile is either a button (time, which opens a wheel) or a menu. The
    /// menu cases are `Menu` rather than a sheet so a one-of-four choice costs
    /// one tap and stays in place, the way iOS's own inline pickers do.
    private func EpisodeSettingTile(tile: EpisodeTile) -> some View {
        Group {
            switch tile.menu {
            case .none:
                Button { tile.action?() } label: { tileLabel(tile) }
            case .length:
                Menu { lengthMenu } label: { tileLabel(tile) }
            case .style:
                Menu { styleMenu } label: { tileLabel(tile) }
            case .voice:
                Menu { voiceMenu } label: { tileLabel(tile) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tile.label), \(tile.value)")
    }

    private func tileLabel(_ tile: EpisodeTile) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LucakuColor.accentTint)
                Image(systemName: tile.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LucakuColor.accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(tile.label)
                    .font(.system(size: 12))
                    .foregroundStyle(LucakuColor.textSecondary)
                Text(tile.value)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LucakuColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 62)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LucakuColor.surface)
        )
    }

    @ViewBuilder private var lengthMenu: some View {
        ForEach([5, 10, 15, 20], id: \.self) { minutes in
            Button("\(minutes) min") { Task { await setLength(minutes) } }
        }
        Button("No limit") { Task { await setLength(nil) } }
    }

    @ViewBuilder private var styleMenu: some View {
        ForEach(NarrationStyle.allCases, id: \.self) { style in
            Button {
                Task { await setStyle(style) }
            } label: {
                Text(style.shortLabel)
                if !style.menuDetail.isEmpty { Text(style.menuDetail) }
            }
        }
    }

    @ViewBuilder private var voiceMenu: some View {
        ForEach(InterestsViewModel.Voice.catalogue, id: \.id) { voice in
            Button {
                Task { await setVoice(voice.id) }
            } label: {
                Text(voice.name)
                Text(voice.detail)
            }
        }
    }

    private var timeWheelSheet: some View {
        NavigationStack {
            DatePicker("Ready at", selection: $wheelTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LucakuColor.bg.ignoresSafeArea())
                .navigationTitle("Ready at")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showTimeWheel = false
                            if let token = session.accessToken {
                                viewModel.setDeliveryTime(Self.hhmm(from: wheelTime), token: token)
                            }
                        }
                    }
                }
        }
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
    }

    private func openTimeWheel() {
        if let time = viewModel.deliveryTime, let date = Self.parse(time) { wheelTime = date }
        showTimeWheel = true
    }

    // MARK: - 2 · You follow

    private var followHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("You follow · \(followCount)")
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(LucakuColor.textSecondary)
                .textCase(.uppercase)
            Spacer()
            if !followGroups.isEmpty {
                Button(isEditing ? "Done" : "Edit") {
                    withAnimation(LucakuMotion.house) { isEditing.toggle() }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LucakuColor.accent)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }

    /// Everything followed, bucketed by category, so the card reads as "what
    /// you follow in Sports / in Markets" rather than one undifferentiated
    /// pile of chips.
    ///
    /// A category followed wholesale, with no specific question under it,
    /// shows a single muted "Top stories" chip instead of repeating the
    /// category's own name back at you beneath itself.
    private var followGroups: [FollowGroup] {
        var topicsByCategory: [String: [InterestsViewModel.Topic]] = [:]
        for topic in viewModel.topics {
            topicsByCategory[topic.categoryId ?? "other", default: []].append(topic)
        }

        var ids = viewModel.standingInterests.map(\.id)
        for key in topicsByCategory.keys where !ids.contains(key) { ids.append(key) }

        return ids.map { id in
            let topics = topicsByCategory[id] ?? []
            let items: [FollowChipItem]
            if topics.isEmpty {
                items = [FollowChipItem(id: "c:" + id, label: "Top stories", muted: true,
                                        removable: true,
                                        remove: { Task { await removeCategory(id: id) } })]
            } else {
                items = topics.map { topic in
                    FollowChipItem(id: "t:" + topic.id, label: topic.label, muted: false,
                                   removable: true,
                                   remove: { Task { await removeTopic(topic) } })
                }
            }
            return FollowGroup(id: id, label: viewModel.label(forCategory: id), items: items)
        }
    }

    /// Topics, plus any category followed wholesale. A category that already
    /// contributes topics is not counted twice.
    private var followCount: Int {
        let covered = Set(viewModel.topics.map { $0.categoryId ?? "other" })
        return viewModel.topics.count + viewModel.standingInterests.filter { !covered.contains($0.id) }.count
    }

    private var followCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if followGroups.isEmpty {
                Text("Nothing yet. Tell Lucaku below what you want to follow.")
                    .font(.system(size: 15))
                    .foregroundStyle(LucakuColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 16)
            } else {
                ForEach(Array(followGroups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 {
                        Rectangle().fill(LucakuColor.borderSoft).frame(height: 0.5)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(InterestPalette.gradient(forCategory: group.id))
                            Image(systemName: Self.icon(forCategory: group.id))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 34, height: 34)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.label)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(LucakuColor.textPrimary)
                            FlowLayout(spacing: 6) {
                                ForEach(group.items) { item in
                                    followChip(item)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LucakuColor.surface)
        )
    }

    private func followChip(_ item: FollowChipItem) -> some View {
        HStack(spacing: 4) {
            Text(item.label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.muted ? LucakuColor.textSecondary : LucakuColor.textPrimary)
                .lineLimit(1)
            if isEditing && item.removable {
                Button(action: item.remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LucakuColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop following \(item.label)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, isEditing && item.removable ? 7 : 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(LucakuColor.fill))
    }

    private func undoRow(_ removed: InterestsViewModel.Removed) -> some View {
        HStack(spacing: 10) {
            Text("Removed “\(removed.label)”")
                .font(.system(size: 14))
                .foregroundStyle(LucakuColor.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Undo") {
                guard let token = session.accessToken else { return }
                Task { await viewModel.restore(removed, token: token) }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(LucakuColor.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LucakuColor.surface)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - 3 · Lucaku, docked

    /// The composer sits in the screen's own bottom safe area, which places it
    /// above the mini player and tab bar without either knowing about it.
    private var dock: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("l.")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(LucakuColor.accent)

                TextField(speech.isListening ? "Listening…" : "Add, remove or change anything",
                          text: $viewModel.freeTextQuery)
                    .font(.system(size: 15))
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await send() } }

                Button {
                    toggleMic()
                } label: {
                    Image(systemName: speech.isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(speech.isListening ? .white : LucakuColor.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(speech.isListening ? LucakuColor.destructive : .clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speech.isListening ? "Stop listening" : "Speak instead of typing")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Capsule().fill(LucakuColor.surface))
            .overlay(Capsule().strokeBorder(LucakuColor.borderSoft, lineWidth: 0.5))

            Button {
                Task { await send() }
            } label: {
                ZStack {
                    Circle().fill(canSend ? LucakuColor.accent : LucakuColor.fill)
                    if viewModel.isSubmittingFreeText {
                        ProgressView().tint(LucakuColor.accentOn).controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(canSend ? LucakuColor.accentOn : LucakuColor.textTertiary)
                    }
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !viewModel.freeTextQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isSubmittingFreeText
    }

    // MARK: - Actions

    private func load() async {
        guard let token = session.accessToken else { return }
        await viewModel.load(token: token)
    }

    private func send() async {
        guard canSend, let token = session.accessToken else { return }
        if speech.isListening { speech.stopListening() }
        composerFocused = false
        await viewModel.submitFreeText(token: token)
    }

    private func toggleMic() {
        if speech.isListening {
            speech.stopListening()
            return
        }
        viewModel.freeTextQuery = ""
        Task {
            // A refused mic permission surfaces in the same alert as any other
            // Interests failure rather than leaving a dead button.
            do {
                try await speech.startListening(
                    languageCode: LucakuLocale.speechLanguage(forIdioma: Locale.current.language.languageCode?.identifier ?? "es")
                )
            } catch {
                viewModel.errorMessage = "Couldn't start listening. Check microphone and speech permissions in Settings."
            }
        }
    }

    private func setLength(_ minutes: Int?) async {
        guard let token = session.accessToken else { return }
        await viewModel.setMaxLength(minutes, token: token)
    }

    private func setStyle(_ style: NarrationStyle) async {
        guard let token = session.accessToken else { return }
        await viewModel.setNarrationStyle(style, token: token)
    }

    private func setVoice(_ id: String) async {
        guard let token = session.accessToken else { return }
        await viewModel.setVoice(id, token: token)
    }

    private func removeTopic(_ topic: InterestsViewModel.Topic) async {
        guard let token = session.accessToken else { return }
        await viewModel.stopFollowing(topic, token: token)
    }

    private func removeCategory(id: String) async {
        guard let token = session.accessToken else { return }
        await viewModel.removeCategory(id: id, token: token)
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } })
    }

    // MARK: - Small helpers

    struct EpisodeTile: Identifiable {
        enum MenuKind { case length, style, voice }
        let id: String
        let icon: String
        let label: String
        let value: String
        let menu: MenuKind?
        let action: (() -> Void)?
    }

    struct FollowGroup: Identifiable {
        let id: String
        let label: String
        let items: [FollowChipItem]
    }

    struct FollowChipItem: Identifiable {
        let id: String
        let label: String
        /// The "Top stories" placeholder for a category with no question of
        /// its own — drawn quieter than a real topic.
        let muted: Bool
        let removable: Bool
        let remove: () -> Void
    }

    private static let hhmmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func parse(_ hhmm: String) -> Date? { hhmmFormatter.date(from: hhmm) }
    private static func hhmm(from date: Date) -> String { hhmmFormatter.string(from: date) }

    /// "07:00" -> "7:00 AM", in the reader's own locale.
    private static func display(_ hhmm: String) -> String {
        guard let date = parse(hhmm) else { return hhmm }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private static func subtractHour(from hhmm: String) -> String? {
        guard let date = parse(hhmm) else { return nil }
        return Self.hhmm(from: date.addingTimeInterval(-3600))
    }

    private static func icon(forCategory id: String) -> String {
        switch id {
        case "sports": return "sportscourt.fill"
        case "markets", "economy": return "chart.line.uptrend.xyaxis"
        case "technology": return "cpu.fill"
        case "politics": return "building.columns.fill"
        case "local": return "mappin.and.ellipse"
        case "world": return "globe"
        case "climate": return "leaf.fill"
        case "health": return "heart.fill"
        case "science": return "atom"
        case "culture", "entertainment": return "film.fill"
        default: return "star.fill"
        }
    }
}
