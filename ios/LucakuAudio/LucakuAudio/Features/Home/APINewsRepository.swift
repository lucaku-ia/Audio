import Foundation

/// Live news feed backed by GET /api/news and the read-state endpoints.
///
/// Fetches the customer's followed feed (`scope=followed`); when the server
/// reports `no_follow_match` it asks for the whole feed (`scope=all`), as the
/// backend contract describes. All backend-to-`NewsStory` adaptation lives
/// here so the Home views never see backend field names.
final class APINewsRepository: NewsRepository {
    private let client: APIClient
    /// Scope of the last successful list call, reused for "mark all read".
    private var lastScope = "followed"

    /// Safety cap on pagination (pages of `pageSize`), the window is 7 days.
    private let maxPages = 5
    private let pageSize = 100

    init(client: APIClient = .shared) {
        self.client = client
    }

    var isLive: Bool { true }

    func stories(token: String?) async throws -> [NewsStory] {
        guard let token else { throw APIError.notAuthenticated }
        var scope = "followed"
        var items = try await fetchAll(scope: scope, token: token)
        if items.items.isEmpty && items.noFollowMatch {
            scope = "all"
            items = try await fetchAll(scope: scope, token: token)
        }
        lastScope = scope
        return items.items.map(Self.story(from:))
    }

    func setRead(id: String, read: Bool, token: String) async throws {
        try await client.setNewsRead(id: id, read: read, token: token)
    }

    func markAllRead(token: String) async throws {
        try await client.markAllNewsRead(scope: lastScope, token: token)
    }

    // MARK: - Fetching

    private func fetchAll(scope: String, token: String) async throws -> (items: [NewsItemOut], noFollowMatch: Bool) {
        var all: [NewsItemOut] = []
        var cursor: String?
        var noMatch = false
        for page in 0..<maxPages {
            let result = try await client.news(scope: scope, cursor: cursor, limit: pageSize, token: token)
            if page == 0 { noMatch = result.noFollowMatch }
            all += result.items
            guard let next = result.nextCursor else { break }
            cursor = next
        }
        return (all, noMatch)
    }

    // MARK: - Mapping

    static func story(from item: NewsItemOut, now: Date = Date(), calendar: Calendar = .current) -> NewsStory {
        let published = item.publishedAt
        let startOfPublished = calendar.startOfDay(for: published)
        let startOfToday = calendar.startOfDay(for: now)
        let dayOffset = max(0, calendar.dateComponents([.day], from: startOfPublished, to: startOfToday).day ?? 0)
        let parts = calendar.dateComponents([.hour, .minute], from: published)
        let minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)

        let paragraphs = paragraphs(of: item.body)
        let words = item.body.split(whereSeparator: \.isWhitespace).count

        return NewsStory(
            id: item.id,
            category: NewsCategory(rawValue: item.category) ?? .world,
            title: item.title,
            summary: item.summary,
            points: points(of: item.shortVersion),
            body: paragraphs.isEmpty ? [item.summary] : paragraphs,
            sources: sourcesLabel(item.sources),
            dayOffset: dayOffset,
            minuteOfDay: minuteOfDay,
            readMinutes: max(1, Int((Double(words) / 200).rounded())),
            serverRead: item.read
        )
    }

    /// The short version as bullet points: one per line when the text has
    /// lines, otherwise one per sentence (at most five).
    static func points(of shortVersion: String) -> [String] {
        let bulletChars = CharacterSet(charactersIn: "-*\u{2022}\u{00B7} \t")
        let lines = shortVersion
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: bulletChars) }
            .filter { !$0.isEmpty }
        if lines.count > 1 { return Array(lines.prefix(5)) }

        var sentences: [String] = []
        let text = lines.first ?? ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let sub = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !sub.isEmpty {
                sentences.append(sub)
            }
        }
        return Array(sentences.prefix(5))
    }

    static func paragraphs(of body: String) -> [String] {
        let byBlank = body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if byBlank.count > 1 { return byBlank }
        return body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func sourcesLabel(_ sources: [NewsSourceOut]) -> String {
        var seen = Set<String>()
        let names = sources.map(\.name).filter { !$0.isEmpty && seen.insert($0).inserted }
        return names.joined(separator: ", ")
    }
}
