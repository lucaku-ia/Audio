import Foundation

/// Backs the Search tab (see SearchView.swift's file-level doc comment for
/// the full real-vs-omitted breakdown). Every network call here hits a real,
/// already-deployed endpoint — GET /api/search/query (backend/app/api/routes/
/// search.py) for keyword search, GET /api/home (backend/app/api/routes/
/// home.py) for interest-derived suggestions, and POST /api/requests
/// (backend/app/api/routes/requests.py) for "Add as a new interest".
@MainActor
final class SearchViewModel: ObservableObject {
    enum ResultState: Equatable {
        case idle
        case searching
        case loaded(SearchOut)
        case failed(String)

        static func == (lhs: ResultState, rhs: ResultState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.searching, .searching): return true
            case (.loaded(let a), .loaded(let b)): return a.query == b.query
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var query: String = ""
    @Published private(set) var resultState: ResultState = .idle
    @Published private(set) var recentSearches: [String] = []

    /// GET /home's `shared_inventory` — the one real, interest-derived data
    /// source available (see SearchView.swift's doc comment on why this
    /// stands in for the mockup's "Suggested for you" instead of a dedicated
    /// suggestions endpoint, which doesn't exist).
    @Published private(set) var suggestions: [SharedInventoryOut] = []

    /// Raw-text values (trimmed, lowercased) that either already exist as an
    /// active standing request (checked once per screen visit via GET
    /// /requests) or were just added in this session — either way, the "Add"
    /// button for that text should read "Added" rather than let the customer
    /// create a duplicate standing request for the same topic.
    @Published private(set) var addedTopics: Set<String> = []
    @Published private(set) var addingTopics: Set<String> = []
    @Published var addTopicError: String?

    private let recentSearchesStore = RecentSearchesStore()
    private var searchTask: Task<Void, Never>?

    init() {
        recentSearches = recentSearchesStore.load()
    }

    // MARK: - Pre-search data

    /// Best-effort — if this fails, the "Suggested for you" section is
    /// simply omitted rather than shown broken or blocking the rest of the
    /// screen (this is a nice-to-have, not the screen's primary job).
    func loadSuggestions(token: String) async {
        guard let home = try? await APIClient.shared.home(token: token) else { return }
        suggestions = home.sharedInventory
    }

    /// GET /requests?status=active — used only to pre-mark topics that
    /// already have a matching active standing request, so "Add" doesn't
    /// offer to create a duplicate. Best-effort like `loadSuggestions`.
    func loadExistingStandingTopics(token: String) async {
        guard let active = try? await APIClient.shared.listRequests(status: "active", token: token) else { return }
        let standing = active.filter { $0.kind == "standing" }.map { normalize($0.rawText) }
        addedTopics.formUnion(standing)
    }

    // MARK: - Search

    func submitSearch(token: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resultState = .idle
            return
        }
        recentSearchesStore.record(trimmed)
        recentSearches = recentSearchesStore.load()

        searchTask?.cancel()
        resultState = .searching
        searchTask = Task {
            do {
                let result = try await APIClient.shared.search(query: trimmed, token: token)
                if Task.isCancelled { return }
                resultState = .loaded(result)
            } catch {
                if Task.isCancelled { return }
                resultState = .failed(error.localizedDescription)
            }
        }
    }

    /// Recent-search chips and "Suggested for you" rows fill the field and
    /// run the search immediately, matching the mockup's `data-fill` rows.
    func fillAndSearch(_ text: String, token: String) {
        query = text
        submitSearch(token: token)
    }

    func clearSearch() {
        searchTask?.cancel()
        query = ""
        resultState = .idle
    }

    // MARK: - Add as a new interest

    func isTopicAdded(_ topic: String) -> Bool {
        addedTopics.contains(normalize(topic))
    }

    func isTopicAdding(_ topic: String) -> Bool {
        addingTopics.contains(normalize(topic))
    }

    /// Creates a real standing Request via POST /requests (created_from:
    /// "search") — see CreateRequestBody's doc comment. On success the topic
    /// is marked "Added" so the button can't be tapped again for the same
    /// text; on failure (e.g. the AI Platform's safety/structuring gate
    /// rejects free-text that's too short or unresearchable) the error is
    /// surfaced rather than silently marked added.
    func addTopicAsInterest(_ topic: String, token: String) async {
        let key = normalize(topic)
        guard !addedTopics.contains(key), !addingTopics.contains(key) else { return }
        addingTopics.insert(key)
        addTopicError = nil
        defer { addingTopics.remove(key) }
        do {
            _ = try await APIClient.shared.createRequest(rawText: topic, createdFrom: "search", token: token)
            addedTopics.insert(key)
        } catch {
            addTopicError = error.localizedDescription
        }
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Local-only recent-search history. There is no backend endpoint for
/// persisting a customer's search *queries* (GET /search/history is
/// something different — a chronological list of their Episodes, not their
/// past searches), so this is honestly UserDefaults-backed rather than
/// invented as a fake server feature. Capped at 8 entries, most-recent-first,
/// de-duplicated case-insensitively.
final class RecentSearchesStore {
    private let key = "search.recentQueries.v1"
    private let limit = 8
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    func record(_ query: String) {
        var items = load()
        items.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        items.insert(query, at: 0)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
        defaults.set(items, forKey: key)
    }
}
