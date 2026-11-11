import Foundation

/// Drives Features/Interests/InterestsView.swift (screens 6.1-6.4).
///
/// Data sources (all existing endpoints):
/// - Categories ("Everything in Sports"): `GET /onboarding/interest_options`
///   + `GET /onboarding/state` (`selected_interests`); add/remove through
///   `PATCH /onboarding/interests`, which replaces the whole list.
/// - Topics (specific questions): the customer's standing `Request`s,
///   `GET /requests?kind=standing&status=active`. Follow = `POST /requests`,
///   edit = `PATCH /requests/{id}`, stop = `PATCH /requests/{id}/archive`,
///   undo/restore = `PATCH /requests/{id}/resume`.
/// - Delivery settings: `GET/PATCH /profile` (time, max length, narration
///   style). Delivery on/off and a minimum-length are not modelled server side.
@MainActor
final class InterestsViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// A catalogue category the customer follows as a whole.
    struct Interest: Identifiable, Equatable {
        let id: String
        let label: String
    }

    /// A specific followed question (a standing `Request`).
    struct Topic: Identifiable, Equatable {
        let id: String
        let label: String
        let question: String
        let categoryId: String?
    }

    /// Something removed that can be put back.
    enum Removed: Identifiable, Equatable {
        case category(Interest)
        case topic(Topic)

        var id: String {
            switch self {
            case .category(let c): return "c:" + c.id
            case .topic(let t): return "t:" + t.id
            }
        }

        var label: String {
            switch self {
            case .category(let c): return c.label
            case .topic(let t): return t.label
            }
        }
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var standingInterests: [Interest] = []
    @Published private(set) var allCategories: [Interest] = []
    @Published private(set) var topics: [Topic] = []
    /// Archived topics (server) plus categories removed this session.
    @Published private(set) var recentlyRemoved: [Removed] = []
    /// Item currently offered an Undo (snackbar).
    @Published private(set) var undoItem: Removed?
    @Published private(set) var pendingIds: Set<String> = []
    @Published var errorMessage: String?

    // Add bar (6.1 / 6.3)
    @Published var freeTextQuery: String = ""
    @Published private(set) var isSubmittingFreeText = false
    @Published private(set) var confirmation: String?

    // Delivery settings (6.1 / 6.4)
    @Published private(set) var deliveryTime: String?      // "HH:mm"
    @Published private(set) var maxLengthMinutes: Int?
    @Published private(set) var narrationStyle: NarrationStyle = .news
    @Published private(set) var voiceId: String?

    /// The two voices the prototype offers. The backend stores a free-form
    /// ElevenLabs voice id, so an id set elsewhere that is not one of these
    /// still shows — as itself — rather than being silently relabelled.
    struct Voice: Equatable {
        let id: String
        let name: String
        let detail: String

        static let catalogue: [Voice] = [
            Voice(id: "valentina", name: "Valentina", detail: "Warm, calm female voice"),
            Voice(id: "andres", name: "Andrés", detail: "Clear, steady male voice"),
        ]
    }

    /// The effective voice. With nothing stored the generator uses the first
    /// catalogue entry, so that is what the tile reports — "Default" named a
    /// voice nobody could identify.
    var voiceLabel: String {
        guard let voiceId, !voiceId.isEmpty else { return Voice.catalogue[0].name }
        return Voice.catalogue.first { $0.id == voiceId }?.name ?? voiceId
    }
    @Published private(set) var settingsEdited = false
    @Published private(set) var isSavingSettings = false

    private var selectedIds: [String] = []
    private var undoTask: Task<Void, Never>?
    private var timeTask: Task<Void, Never>?

    // MARK: - Load

    func load(token: String) async {
        if case .loaded = loadState {} else { loadState = .loading }
        do {
            async let optionsTask = APIClient.shared.interestOptions(token: token)
            async let stateTask = APIClient.shared.onboardingState(token: token)
            let (options, state) = try await (optionsTask, stateTask)
            allCategories = options.map { Interest(id: $0.id, label: $0.label) }
            selectedIds = state.selectedInterests
            recomputeCategories()
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
            return
        }
        // Best effort: the rest of the screen still works without them.
        await loadTopics(token: token)
        await loadProfile(token: token)
    }

    private func loadTopics(token: String) async {
        if let active = try? await APIClient.shared.listRequests(status: "active", kind: "standing", token: token) {
            topics = active.map(Self.topic(from:))
        }
        if let archived = try? await APIClient.shared.listRequests(status: "archived", kind: "standing", token: token) {
            let sessionCategories = recentlyRemoved.filter { if case .category = $0 { return true } else { return false } }
            let recent = archived.sorted { $0.creadoEn > $1.creadoEn }.prefix(5).map { Removed.topic(Self.topic(from: $0)) }
            recentlyRemoved = Array((sessionCategories + recent).prefix(6))
        }
    }

    private func loadProfile(token: String) async {
        guard let profile = try? await APIClient.shared.getProfile(token: token) else { return }
        deliveryTime = profile.deliveryTime
        maxLengthMinutes = profile.maxLengthMinutes
        narrationStyle = profile.narrationStyle
        voiceId = profile.voiceId
    }

    private static func topic(from r: RequestOut) -> Topic {
        Topic(id: r.id, label: r.structured.topic, question: r.rawText,
              categoryId: InterestCatalog.categoryId(for: r.structured.topic + " " + r.rawText))
    }

    private func recomputeCategories() {
        let labelById = Dictionary(allCategories.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        standingInterests = selectedIds.compactMap { id in
            labelById[id].map { Interest(id: id, label: $0) }
        }
    }

    // MARK: - Lookups

    func label(forCategory id: String) -> String {
        allCategories.first { $0.id == id }?.label ?? InterestCatalog.fallbackLabel[id] ?? id.capitalized
    }

    func followsCategory(_ id: String) -> Bool { selectedIds.contains(id) }

    func followsTopic(label: String) -> Bool { topic(named: label) != nil }

    func topic(named label: String) -> Topic? {
        let l = label.lowercased()
        return topics.first {
            $0.label.lowercased() == l || $0.question.lowercased() == InterestCatalog.followText(label).lowercased()
        }
    }

    /// Browse-all tile check: the category itself or any of its specific topics.
    func isCategoryActive(_ id: String) -> Bool {
        followsCategory(id) || (InterestCatalog.specific[id] ?? []).contains { followsTopic(label: $0) }
    }

    // MARK: - Categories

    func addCategory(id: String, token: String) async {
        guard !selectedIds.contains(id) else { return }
        await mutate(newList: selectedIds + [id], id: id, token: token)
    }

    /// The backend requires at least one category, so removing the last one
    /// is refused locally instead of round-tripping to a 422.
    func removeCategory(id: String, token: String) async {
        guard selectedIds.contains(id) else { return }
        guard selectedIds.count > 1 else {
            errorMessage = "You need at least one category. Add another before removing this one."
            return
        }
        let removed = standingInterests.first { $0.id == id }
        await mutate(newList: selectedIds.filter { $0 != id }, id: id, token: token)
        if let removed, !selectedIds.contains(id) { offerUndo(.category(removed)) }
    }

    private func mutate(newList: [String], id: String, token: String) async {
        pendingIds.insert(id)
        errorMessage = nil
        defer { pendingIds.remove(id) }
        do {
            let state = try await APIClient.shared.setInterests(newList, token: token)
            selectedIds = state.selectedInterests
            recomputeCategories()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Topics

    /// Follow a suggested / specific topic (one tap). Creates a standing request.
    func followTopic(label: String, token: String) async {
        guard !followsTopic(label: label), !pendingIds.contains(label) else { return }
        pendingIds.insert(label)
        errorMessage = nil
        defer { pendingIds.remove(label) }
        do {
            let request = try await APIClient.shared.createRequest(
                rawText: InterestCatalog.followText(label), kind: "standing", createdFrom: "interests", token: token
            )
            topics.append(Self.topic(from: request))
            confirmation = "Following \u{201C}\(label)\u{201D}. It shows up from your next episode."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unfollowTopic(label: String, token: String) async {
        guard let topic = topic(named: label) else { return }
        await stopFollowing(topic, token: token)
    }

    /// "Stop following": archives the request; offers Undo and lists it under
    /// Recently removed.
    func stopFollowing(_ topic: Topic, token: String) async {
        pendingIds.insert(topic.id)
        errorMessage = nil
        defer { pendingIds.remove(topic.id) }
        do {
            try await APIClient.shared.archiveRequest(id: topic.id, token: token)
            topics.removeAll { $0.id == topic.id }
            confirmation = nil
            offerUndo(.topic(topic))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Edit the question Lucaku researches (applies immediately server side).
    @discardableResult
    func editTopic(_ topic: Topic, question: String, token: String) async -> Topic? {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 5, text != topic.question else { return topic }
        pendingIds.insert(topic.id)
        errorMessage = nil
        defer { pendingIds.remove(topic.id) }
        do {
            let updated = Self.topic(from: try await APIClient.shared.editRequest(id: topic.id, rawText: text, token: token))
            if let i = topics.firstIndex(where: { $0.id == topic.id }) { topics[i] = updated }
            return updated
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Undo / recently removed

    private func offerUndo(_ item: Removed) {
        undoItem = item
        recentlyRemoved.removeAll { $0.id == item.id }
        recentlyRemoved.insert(item, at: 0)
        recentlyRemoved = Array(recentlyRemoved.prefix(6))
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.undoItem = nil
        }
    }

    func dismissUndo() {
        undoTask?.cancel()
        undoItem = nil
    }

    func restore(_ item: Removed, token: String) async {
        dismissUndo()
        switch item {
        case .category(let c):
            await addCategory(id: c.id, token: token)
            if selectedIds.contains(c.id) { recentlyRemoved.removeAll { $0.id == item.id } }
        case .topic(let t):
            pendingIds.insert(t.id)
            defer { pendingIds.remove(t.id) }
            do {
                try await APIClient.shared.resumeRequest(id: t.id, token: token)
                if !topics.contains(where: { $0.id == t.id }) { topics.append(t) }
                recentlyRemoved.removeAll { $0.id == item.id }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Add bar (type or say)

    /// Submits the bar's text as a new standing `Request`; the AI Platform
    /// categorizes it (and may reject it with its own `rejected_reason`).
    func submitFreeText(token: String) async {
        let text = freeTextQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSubmittingFreeText else { return }
        isSubmittingFreeText = true
        confirmation = nil
        errorMessage = nil
        defer { isSubmittingFreeText = false }
        do {
            let request = try await APIClient.shared.createRequest(
                rawText: text.count < 5 ? InterestCatalog.followText(text) : text,
                kind: "standing", createdFrom: "interests", token: token
            )
            let topic = Self.topic(from: request)
            topics.append(topic)
            freeTextQuery = ""
            if let cat = topic.categoryId {
                confirmation = "Added \u{201C}\(topic.label)\u{201D} \u{2014} Lucaku will track it daily under \(label(forCategory: cat))."
            } else {
                confirmation = "Added \u{201C}\(topic.label)\u{201D}. You'll hear about it from your next episode."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissConfirmation() { confirmation = nil }

    // MARK: - Delivery settings

    /// Delivery time is debounced: the wheel fires on every tick.
    func setDeliveryTime(_ hhmm: String, token: String) {
        deliveryTime = hhmm
        timeTask?.cancel()
        timeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await self?.save(SettingsBody(deliveryTime: hhmm), token: token)
        }
    }

    func setMaxLength(_ minutes: Int?, token: String) async {
        maxLengthMinutes = minutes
        var body = SettingsBody()
        if let minutes { body.maxLengthMinutes = minutes } else { body.clearMaxLength = true }
        await save(body, token: token)
    }

    func setNarrationStyle(_ style: NarrationStyle, token: String) async {
        narrationStyle = style
        await save(SettingsBody(narrationStyle: style), token: token)
    }

    func setVoice(_ id: String, token: String) async {
        voiceId = id
        await save(SettingsBody(voiceId: id), token: token)
    }

    private func save(_ body: SettingsBody, token: String) async {
        isSavingSettings = true
        defer { isSavingSettings = false }
        do {
            _ = try await APIClient.shared.updateSettings(body, token: token)
            settingsEdited = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Static catalogue data (from the design prototype)

/// Local presentation data: category order for the palette, specific topics
/// per category, suggestion chips and keyword categorisation.
enum InterestCatalog {
    /// Prototype CATALOG order; the palette index of a category is its position.
    static let order = ["local", "politics", "world", "markets", "personal_finance", "technology",
                        "science", "health", "climate", "sports", "entertainment", "lifestyle"]

    static let fallbackLabel: [String: String] = [
        "local": "Colombia & your city", "politics": "Politics & government", "world": "World",
        "markets": "Economy & business", "personal_finance": "Personal finance", "technology": "Technology & AI",
        "science": "Science & space", "health": "Health & wellness", "climate": "Climate & environment",
        "sports": "Sports", "entertainment": "Culture & entertainment", "lifestyle": "Lifestyle & travel",
    ]

    static let specific: [String: [String]] = [
        "lifestyle": ["Travel deals", "Food & restaurants", "Cars"],
        "sports": ["World Cup", "Champions League", "NBA", "Formula 1", "Tennis"],
        "markets": ["Amazon stock", "Interest rates", "Bitcoin", "Oil prices", "S&P 500"],
        "technology": ["AI startups", "Apple", "Electric cars", "Cybersecurity"],
        "world": ["US elections", "Europe", "China", "Middle East"],
        "local": ["Colombian economy", "Bogot\u{00E1}", "Colombian politics"],
        "health": ["Fitness", "Nutrition", "Sleep"],
        "science": ["Space", "Medical breakthroughs"],
        "entertainment": ["Movies", "Music", "Streaming series"],
        "politics": ["Elections", "Supreme Court decisions"],
        "climate": ["Climate change", "Renewable energy"],
        "personal_finance": ["Saving & investing", "Mortgages", "Taxes"],
    ]

    static let popular = ["World Cup", "Champions League", "AI startups", "Amazon stock", "Formula 1",
                          "Bitcoin", "Interest rates", "Climate change", "NBA", "Electric cars"]

    /// Question text sent when following a specific topic.
    static func followText(_ label: String) -> String { "Keep me up to date on \(label)." }

    /// Keyword categorisation, only used for the tile caption/colour/icon.
    static func categoryId(for text: String) -> String? {
        let t = text.lowercased()
        let rules: [(String, [String])] = [
            ("sports", ["sport", "football", "soccer", "league", "nba", "tennis", "formula", "world cup", "arsenal", "madrid", "millonarios", " fc"]),
            ("markets", ["market", "econom", "stock", "bitcoin", "crypto", "interest rate", "oil", "dollar", "inflation", "s&p"]),
            ("technology", ["tech", "artificial", " ai ", "ai startups", "software", "apple", "electric car", "cyber"]),
            ("science", ["science", "space", "physics", "medical breakthrough"]),
            ("health", ["health", "fitness", "nutrition", "sleep", "wellness"]),
            ("climate", ["climate", "environment", "energy"]),
            ("politics", ["politic", "election", "government", "congress", "supreme court"]),
            ("entertainment", ["movie", "music", "series", "culture", "film", "streaming"]),
            ("personal_finance", ["saving", "mortgage", "tax", "invest"]),
            ("lifestyle", ["travel", "food", "restaurant", "cars"]),
            ("local", ["colombia", "bogot"]),
            ("world", ["world", "europe", "china", "middle east", "international"]),
        ]
        for (id, words) in rules where words.contains(where: { t.contains($0) }) { return id }
        return nil
    }
}
