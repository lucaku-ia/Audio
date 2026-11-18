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

    /// "HH:mm" delivery time from the profile (best effort); nil falls back to 7:00 AM.
    @Published private(set) var deliveryTime: String?

    /// Server-computed next delivery from GET /home (nil on older backends or
    /// before a delivery time is set: the profile-based logic then applies).
    @Published private(set) var nextDelivery: NextDeliveryOut?

    /// Topics the customer follows, from GET /home (chips for "Your Lucaku").
    @Published private(set) var followedTopics: [FollowedTopicOut] = []

    private var deliveryHourMinute: (hour: Int, minute: Int) {
        let parts = (nextDelivery?.localTime ?? deliveryTime ?? "07:00").split(separator: ":").compactMap { Int($0) }
        return (parts.first ?? 7, parts.count > 1 ? parts[1] : 0)
    }

    /// Delivery time as "7:00 AM".
    var deliveryClock: String {
        let (hour, minute) = deliveryHourMinute
        return String(format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12, minute, hour >= 12 ? "PM" : "AM")
    }

    /// "Tomorrow at 7:00 AM" / "At 7:00 AM" pieces for the "Your Lucaku" card.
    func nextEpisodeLine(todayIsReady: Bool) -> (label: String, when: String) {
        let (hour, minute) = deliveryHourMinute
        let clock = deliveryClock
        guard todayIsReady else { return ("Then, every day", "At \(clock)") }
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let localLater = hour * 60 + minute > (now.hour ?? 0) * 60 + (now.minute ?? 0)
        let later: Bool
        if let next = nextDelivery, Date() < next.at {
            // Live check against the delivery's own timezone, not the fetch-time flag.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: next.timezone) ?? .current
            later = calendar.isDate(next.at, inSameDayAs: Date())
        } else {
            later = localLater
        }
        return ("Next episode", "\(later ? "Today" : "Tomorrow") at \(clock)")
    }

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
            async let profileTask = try? await APIClient.shared.getProfile(token: token)

            let home = try await homeTask
            if let profile = await profileTask {
                deliveryTime = profile.deliveryTime
            }
            if let fetchedTopics = await topicsTask {
                topics = fetchedTopics
            }
            if let options = await optionsTask {
                interestLabels = Dictionary(options.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
            }
            nextDelivery = home.nextDelivery
            followedTopics = home.followedTopics
            state = .loaded(home)
        } catch {
            if !alreadyLoaded || showSpinner {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// 3.16: follow the first topic (POST /requests, standing) from Home.
    func addFirstTopic(token: String) async {
        let text = requestTodayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSubmittingRequest = true
        requestTodayError = nil
        defer { isSubmittingRequest = false }
        do {
            _ = try await APIClient.shared.createRequest(rawText: text, kind: "standing", createdFrom: "interests", token: token)
            requestTodayText = ""
            await load(token: token)
        } catch {
            requestTodayError = error.localizedDescription
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
