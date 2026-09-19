import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(HomeOut)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var requestTodayText: String = ""
    @Published private(set) var isSubmittingRequest = false
    @Published var requestTodayError: String?

    /// The customer's active standing requests — Home's "Your topics" grid.
    /// `structured.topic` (the AI-derived category) is what's shown, not the
    /// raw sentence they typed.
    @Published private(set) var topics: [RequestOut] = []

    /// Interest tag id -> localized label ("technology" -> "Tecnología"),
    /// from the same catalogue the Interests screen uses. Best effort: if it
    /// can't be fetched, tags fall back to a prettified id.
    @Published private(set) var interestLabels: [String: String] = [:]

    func label(forTag tag: String?) -> String {
        guard let tag else { return "Lucaku" }
        return interestLabels[tag] ?? HomeFormat.prettyTag(tag)
    }

    /// `showSpinner: false` is for background refreshes (pull-to-refresh, the
    /// poll while an episode is being made): keep the current content on
    /// screen instead of flashing the loading state, and never replace good
    /// content with an error because one poll happened to fail.
    func load(token: String, showSpinner: Bool = true) async {
        var alreadyLoaded = false
        if case .loaded = state { alreadyLoaded = true }
        if showSpinner || !alreadyLoaded {
            state = .loading
        }

        do {
            async let homeTask = APIClient.shared.home(token: token)
            async let topicsTask = try? await APIClient.shared.listRequests(status: "active", kind: "standing", token: token)
            async let optionsTask = try? await APIClient.shared.interestOptions(token: token)

            let home = try await homeTask
            if let fetchedTopics = await topicsTask {
                topics = fetchedTopics
            }
            if let options = await optionsTask {
                interestLabels = Dictionary(options.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
            }
            state = .loaded(home)
        } catch {
            if !alreadyLoaded || showSpinner {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Home's own "Request something for today" action, for the empty_day
    /// banner state — POST /api/home/request-today.
    func submitRequestToday(token: String) async {
        guard !requestTodayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSubmittingRequest = true
        requestTodayError = nil
        defer { isSubmittingRequest = false }
        do {
            _ = try await APIClient.shared.requestToday(rawText: requestTodayText, token: token)
            requestTodayText = ""
            await load(token: token) // banner state changes once a request exists
        } catch {
            requestTodayError = error.localizedDescription
        }
    }
}
