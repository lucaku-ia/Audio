import SwiftUI

// MARK: - Models

/// The 12 news categories (screens spec section 2). Raw values double as stable ids.
enum NewsCategory: String, CaseIterable, Identifiable {
    case local, politics, world, markets, personalFinance, technology
    case science, health, climate, sports, entertainment, lifestyle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "Local news"
        case .politics: return "Politics & government"
        case .world: return "World"
        case .markets: return "Economy & business"
        case .personalFinance: return "Personal finance"
        case .technology: return "Technology & AI"
        case .science: return "Science & space"
        case .health: return "Health & wellness"
        case .climate: return "Climate & environment"
        case .sports: return "Sports"
        case .entertainment: return "Culture & entertainment"
        case .lifestyle: return "Lifestyle & travel"
        }
    }

    /// SF Symbol used for thumbnails and topic chips.
    var symbol: String {
        switch self {
        case .local: return "mappin.and.ellipse"
        case .politics: return "building.columns"
        case .world: return "globe"
        case .markets: return "chart.line.uptrend.xyaxis"
        case .personalFinance: return "banknote"
        case .technology: return "cpu"
        case .science: return "atom"
        case .health: return "heart"
        case .climate: return "leaf"
        case .sports: return "sportscourt"
        case .entertainment: return "theatermasks"
        case .lifestyle: return "airplane"
        }
    }

    /// Maps a topic in the customer's own words to a category, so their news
    /// is never empty (screens spec 3.x). Mirrors the prototype's keyword rules.
    static func infer(from text: String) -> NewsCategory? {
        let t = text.lowercased()
        let rules: [(NewsCategory, [String])] = [
            (.sports, ["fc", "football", "soccer", "league", "cup", "nba", "nfl", "f1", "formula", "tennis", "arsenal", "madrid", "barcelona", "millonarios", "match", "team", "sport"]),
            (.personalFinance, ["saving", "savings", "mortgage", "tax", "budget", "money"]),
            (.markets, ["stock", "market", "econom", "rate", "inflation", "bank", "dollar", "peso", "shares", "bitcoin", "oil"]),
            (.technology, ["ai", "artificial", "intelligence", "tech", "startup", "apple", "google", "software", "chip", "crypto", "cyber"]),
            (.local, ["colombia", "bogot", "medell", "cali"]),
            (.politics, ["election", "politic", "congress", "president", "government", "court"]),
            (.climate, ["climate", "weather", "energy", "solar", "environment"]),
            (.health, ["health", "medic", "fitness", "nutrition", "sleep", "wellness"]),
            (.science, ["science", "space", "nasa", "physics", "research"]),
            (.entertainment, ["movie", "music", "film", "series", "tv", "streaming", "culture", "concert"]),
            (.lifestyle, ["travel", "food", "restaurant", "car", "flight", "fashion"]),
            (.world, ["world", "war", "international", "europe", "china", "middle east"]),
        ]
        let tokens = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for (category, keywords) in rules {
            for word in keywords {
                // Short tokens must match whole words ("ai", "tv", "fc", "f1", "car").
                let hit = word.count <= 3 ? tokens.contains(word) : t.contains(word)
                if hit { return category }
            }
        }
        return nil
    }
}

struct NewsStory: Identifiable, Hashable {
    let id: String
    let category: NewsCategory
    let title: String
    /// A real summary written for two lines (at most ~70 characters).
    let summary: String
    let points: [String]
    let body: [String]
    let sources: String
    /// 0 = today, 1 = yesterday, ...
    let dayOffset: Int
    /// Minutes since midnight, for ordering inside a day.
    let minuteOfDay: Int
    let readMinutes: Int

    var timeLabel: String {
        let h = minuteOfDay / 60, m = minuteOfDay % 60
        return String(format: "%d:%02d %@", h % 12 == 0 ? 12 : h % 12, m, h >= 12 ? "PM" : "AM")
    }

    var date: Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date()
        return cal.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: day) ?? day
    }

    /// "Tuesday, November 10"
    var dayLabel: String { NewsStory.dayLabel(offset: dayOffset) }

    static func dayLabel(offset: Int) -> String {
        let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: day)
    }
}

// MARK: - Repository

/// Source of the news feed.
///
/// TODO(backend): the backend has no news endpoint yet. When it exists, add an
/// `APINewsRepository` conforming to this protocol (GET /api/news, read/unread
/// and rating sync) and swap it in `NewsStore.init`. Nothing else changes.
protocol NewsRepository {
    func stories(token: String?) async throws -> [NewsStory]
}

/// TODO(backend): placeholder content. Realistic English sample stories across
/// the 12 categories; not real reporting.
struct SampleNewsRepository: NewsRepository {
    func stories(token: String?) async throws -> [NewsStory] { Self.sample }

    static let sample: [NewsStory] = [
        NewsStory(
            id: "mk1", category: .markets,
            title: "Banco de la República holds its rate for a second month",
            summary: "Rates stay put; cuts could start early next year if inflation eases.",
            points: ["The benchmark rate stays where it was last month.", "Inflation is cooling, but more slowly than the board wants.", "Cuts look more likely in the first quarter than this year."],
            body: ["The central bank's board voted to leave its benchmark rate unchanged, the second pause in a row. The decision was widely expected, so markets barely moved.", "Board members said inflation is easing but still above target. For savers, that means deposit rates should stay close to where they are for now."],
            sources: "Banco de la República, local press", dayOffset: 0, minuteOfDay: 6 * 60 + 40, readMinutes: 2),
        NewsStory(
            id: "te1", category: .technology,
            title: "Two major labs release new reasoning models",
            summary: "New models promise better coding help and longer memory.",
            points: ["Both models focus on multi-step reasoning.", "Early testers report real gains on coding and research tasks.", "Companies are folding them into everyday office tools."],
            body: ["Two leading AI labs released new models on the same day, each pitched at reasoning through longer problems and remembering more of a conversation.", "Early testers say the biggest gains show up in software work and research summaries. Both companies plan to bring the models into the tools people already use at work."],
            sources: "Company blogs, tech press", dayOffset: 0, minuteOfDay: 6 * 60 + 55, readMinutes: 3),
        NewsStory(
            id: "sp1", category: .sports,
            title: "Arsenal edge a tight home win with a second-half set piece",
            summary: "A set-piece goal keeps Arsenal close to the top of the table.",
            points: ["The first half had few clear chances.", "A corner broke the deadlock early in the second half.", "A hard away trip comes next, midweek."],
            body: ["Arsenal collected three points at home after a cagey first half. The goal came from a set piece shortly after the break, and the defence held firm to the end.", "The result keeps them within reach of the leaders, with a difficult away fixture coming up in midweek."],
            sources: "Premier League, match reports", dayOffset: 0, minuteOfDay: 7 * 60 + 10, readMinutes: 2),
        NewsStory(
            id: "lo1", category: .local,
            title: "Bogotá opens the first stretch of its new metro viaduct",
            summary: "The first viaduct section is done; test runs begin next month.",
            points: ["The first elevated section is structurally complete.", "Test runs with empty trains start next month.", "Full service is still several years away."],
            body: ["City officials marked the completion of the first elevated section of the metro line, a milestone after years of construction.", "Engineers will run empty trains along the stretch next month to test signals and braking. Passenger service on the full line is still some way off."],
            sources: "El Tiempo, city hall", dayOffset: 0, minuteOfDay: 7 * 60 + 25, readMinutes: 2),
        NewsStory(
            id: "wo1", category: .world,
            title: "EU leaders agree on a new energy-sharing plan for winter",
            summary: "A shared gas reserve aims to cap prices and avoid shortages.",
            points: ["Member states will pool part of their gas reserves.", "The plan aims to limit price spikes this winter.", "Details on cost sharing are still being negotiated."],
            body: ["European leaders agreed on a framework to share gas reserves between member states if supplies tighten this winter.", "Officials say the goal is to calm prices and avoid shortages. How the costs will be split between countries is still to be settled."],
            sources: "The Guardian, Reuters", dayOffset: 0, minuteOfDay: 7 * 60 + 45, readMinutes: 3),
        NewsStory(
            id: "he1", category: .health,
            title: "Short daily walks linked to lower heart risk, large study finds",
            summary: "Ten minutes a day made a measurable difference in the data.",
            points: ["The study followed tens of thousands of adults.", "Even ten minutes a day was linked to lower risk.", "Benefits grew with longer walks, but with diminishing returns."],
            body: ["A large study found that adults who walked briskly for just ten minutes a day had a lower risk of heart disease than those who did not.", "Researchers stress the result shows a link, not proof of cause, but say it supports a simple message: a little movement every day adds up."],
            sources: "Medical journal, health press", dayOffset: 0, minuteOfDay: 8 * 60 + 5, readMinutes: 2),

        NewsStory(
            id: "po1", category: .politics,
            title: "Congress advances the pension reform to a final vote",
            summary: "The bill passed a key committee; a floor vote is set for next week.",
            points: ["A key committee approved the bill after a long debate.", "A floor vote is scheduled for next week.", "Unions and employers still disagree on the retirement age."],
            body: ["The pension reform cleared a key committee after weeks of debate, sending it to a final vote on the floor next week.", "Supporters say it makes the system fairer. Unions and employers still disagree on details such as the retirement age."],
            sources: "El Espectador, Semana", dayOffset: 1, minuteOfDay: 6 * 60 + 30, readMinutes: 3),
        NewsStory(
            id: "pf1", category: .personalFinance,
            title: "Why high-yield savings accounts still beat most fixed deposits",
            summary: "Online accounts pay more and keep your money accessible.",
            points: ["Online accounts often pay noticeably more.", "Your money stays accessible, unlike a fixed term.", "Check whether the rate is introductory."],
            body: ["With rates on hold, many online savings accounts still pay more than traditional fixed deposits, and you can withdraw at any time.", "Before switching, check whether the rate is a short introductory offer and whether deposits are insured."],
            sources: "Personal finance press", dayOffset: 1, minuteOfDay: 6 * 60 + 45, readMinutes: 2),
        NewsStory(
            id: "sc1", category: .science,
            title: "A new telescope image shows a planet-forming disc in detail",
            summary: "The sharpest view yet of how young planets begin to take shape.",
            points: ["The image shows rings and gaps in a young star's disc.", "Gaps may mark where new planets are forming.", "More targets are planned next year."],
            body: ["Astronomers released the sharpest image yet of a disc of gas and dust around a young star, with clear rings and gaps.", "Those gaps are thought to be carved out by planets in the making. The team plans to observe more young stars next year."],
            sources: "Space agency, science press", dayOffset: 1, minuteOfDay: 7 * 60, readMinutes: 2),
        NewsStory(
            id: "cl1", category: .climate,
            title: "Colombia expands solar farms across the Caribbean coast",
            summary: "Three new solar plants will power about 200,000 homes.",
            points: ["Three new plants are now connected to the grid.", "Together they can supply about 200,000 homes.", "Storage is the next challenge."],
            body: ["Three new solar plants on the Caribbean coast have been connected to the national grid, adding clean power in one of the sunniest regions of the country.", "Officials say the next challenge is storage, so that the energy can be used after sunset."],
            sources: "Ministry of Energy, local press", dayOffset: 1, minuteOfDay: 7 * 60 + 20, readMinutes: 2),
        NewsStory(
            id: "en1", category: .entertainment,
            title: "A Colombian film wins top prize at a major festival",
            summary: "The drama took the top award and will open in theaters next month.",
            points: ["The drama won the festival's top award.", "Critics praised its cast and cinematography.", "It opens in Colombian theaters next month."],
            body: ["A Colombian drama took home the top prize at an international film festival, a first for the country at this event.", "Critics singled out the performances and the cinematography. The film opens in Colombian theaters next month."],
            sources: "Festival press, El Colombiano", dayOffset: 1, minuteOfDay: 7 * 60 + 40, readMinutes: 2),
        NewsStory(
            id: "li1", category: .lifestyle,
            title: "Cheaper flights to Europe: when and where to book this winter",
            summary: "Midweek departures and shoulder-season dates cut fares the most.",
            points: ["Midweek departures are usually cheaper.", "Shoulder-season dates beat peak holidays.", "Flexible airports can save a lot."],
            body: ["Travel analysts say the best fares to Europe this winter are on midweek departures and in the weeks just outside the holiday peak.", "Being flexible about the departure airport can also cut the price noticeably."],
            sources: "Travel press", dayOffset: 1, minuteOfDay: 8 * 60, readMinutes: 2),
    ]
}

// MARK: - Store

enum StoryRating: String { case up, down }

struct NewsDayGroup: Identifiable {
    let dayOffset: Int
    let stories: [NewsStory]
    var id: Int { dayOffset }
}

/// Holds the feed plus the per-user state (read, ratings, collapsed days).
/// Read state persists locally in `UserDefaults` until the backend syncs it.
@MainActor
final class NewsStore: ObservableObject {
    /// Stories shown per day before "Show N more".
    static let storiesPerDay = 4

    @Published private(set) var stories: [NewsStory] = []
    @Published private(set) var readIDs: Set<String>
    @Published private(set) var ratings: [String: StoryRating] = [:]
    @Published var collapsedDays: Set<Int> = []
    @Published var expandedDays: Set<Int> = []
    @Published private(set) var followed: Set<NewsCategory> = []

    private let repository: NewsRepository
    private static let readKey = "lucaku.news.readIDs"

    init(repository: NewsRepository = SampleNewsRepository()) {
        self.repository = repository
        if let saved = UserDefaults.standard.array(forKey: Self.readKey) as? [String] {
            readIDs = Set(saved)
        } else {
            // First run: yesterday's stories start out read so a collapsed
            // "today" reveals an already-read day (3.5).
            readIDs = Set(SampleNewsRepository.sample.filter { $0.dayOffset > 0 }.map(\.id))
        }
    }

    func load(token: String?) async {
        if let loaded = try? await repository.stories(token: token) { stories = loaded }
    }

    /// Maps the customer's topics to categories; an empty result shows everything.
    func setFollowedTopics(_ topics: [String]) {
        followed = Set(topics.compactMap(NewsCategory.infer(from:)))
    }

    var feed: [NewsStory] {
        let filtered = followed.isEmpty ? stories : stories.filter { followed.contains($0.category) }
        return filtered.isEmpty ? stories : filtered
    }

    /// Newest day first; earliest time first inside a day.
    var groups: [NewsDayGroup] {
        Dictionary(grouping: feed, by: \.dayOffset)
            .map { NewsDayGroup(dayOffset: $0.key, stories: $0.value.sorted { $0.minuteOfDay < $1.minuteOfDay }) }
            .sorted { $0.dayOffset < $1.dayOffset }
    }

    var unreadCount: Int { feed.filter { !readIDs.contains($0.id) }.count }

    func isRead(_ story: NewsStory) -> Bool { readIDs.contains(story.id) }

    func unreadCount(in group: NewsDayGroup) -> Int { group.stories.filter { !isRead($0) }.count }

    func toggleRead(_ story: NewsStory) {
        if readIDs.contains(story.id) { readIDs.remove(story.id) } else { readIDs.insert(story.id) }
        persist()
    }

    func markRead(_ story: NewsStory) {
        guard !readIDs.contains(story.id) else { return }
        readIDs.insert(story.id)
        persist()
    }

    func markAllRead() {
        readIDs.formUnion(feed.map(\.id))
        persist()
    }

    func rating(for story: NewsStory) -> StoryRating? { ratings[story.id] }

    func setRating(_ rating: StoryRating?, for story: NewsStory) { ratings[story.id] = rating }

    func toggleCollapsed(_ day: Int) {
        if collapsedDays.contains(day) { collapsedDays.remove(day) } else { collapsedDays.insert(day) }
    }

    func toggleExpanded(_ day: Int) {
        if expandedDays.contains(day) { expandedDays.remove(day) } else { expandedDays.insert(day) }
    }

    private func persist() {
        UserDefaults.standard.set(Array(readIDs), forKey: Self.readKey)
    }
}
