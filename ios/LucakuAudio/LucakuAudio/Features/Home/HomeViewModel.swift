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

    func load(token: String) async {
        state = .loading
        do {
            let home = try await APIClient.shared.home(token: token)
            state = .loaded(home)
        } catch {
            state = .failed(error.localizedDescription)
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
