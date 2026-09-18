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
    func runGeneration(token: String) async {
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
