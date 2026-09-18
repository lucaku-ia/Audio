import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    enum HistoryState {
        case idle
        case loading
        case loaded(HistoryOut)
        case failed(String)
    }

    enum GenerationState {
        case idle
        case running
        case finished(JobOut)
        case failed(String)
    }

    @Published private(set) var historyState: HistoryState = .idle
    @Published private(set) var generationState: GenerationState = .idle
    @Published var searchText: String = ""
    @Published private(set) var searchResults: SearchOut?
    @Published private(set) var isSearching = false

    func loadHistory(token: String) async {
        historyState = .loading
        do {
            let history = try await APIClient.shared.searchHistory(token: token)
            historyState = .loaded(history)
        } catch {
            historyState = .failed(error.localizedDescription)
        }
    }

    /// Triggers POST /api/generation/run — the on-demand path. Can genuinely
    /// take a while (the route runs the whole research → write → voice
    /// pipeline synchronously); the UI shows a spinner for the duration.
    ///
    /// Guarded against re-entrancy: without this, a fast double-tap on the
    /// calling button (which has no `.disabled()` of its own) could fire two
    /// concurrent requests before the first `generationState = .running`
    /// assignment has a chance to disable the UI. The backend's own
    /// idempotency (unique per customer/date/path) prevents a duplicate
    /// episode from being created, but the *losing* request still returns
    /// immediately with the winner's job, which could flip this view model
    /// to `.finished` before the pipeline is actually done — this guard
    /// avoids that race by simply never starting a second request at all.
    func runGeneration(token: String) async {
        if case .running = generationState { return }
        generationState = .running
        do {
            let job = try await APIClient.shared.runGeneration(token: token)
            generationState = .finished(job)
            await loadHistory(token: token)
        } catch {
            generationState = .failed(error.localizedDescription)
        }
    }

    func runSearch(token: String) async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await APIClient.shared.search(query: query, token: token)
        } catch {
            // Search errors don't need their own state machine for this
            // scaffold — surface nothing rather than block the history list
            // the user is also looking at.
            searchResults = nil
        }
    }
}
