import Foundation

// Matches backend/app/api/routes/news.py's NewsItemOut / NewsSourceOut /
// NewsListOut. Not snake-case-converted globally: the shared decoder has no
// key strategy, so every field is mapped explicitly.

struct NewsSourceOut: Decodable {
    let name: String
    let url: String
}

struct NewsItemOut: Decodable {
    let id: String
    let topicKey: String
    /// One of the backend's CATEGORIES; same raw values as `NewsCategory`.
    let category: String
    let title: String
    /// Hard-capped at 70 characters server-side (two lines in the feed).
    let summary: String
    /// Short text version, one idea per sentence or line.
    let shortVersion: String
    /// Full article text, paragraphs separated by blank lines.
    let body: String
    let sources: [NewsSourceOut]
    let publishedAt: Date
    /// UTC calendar day "YYYY-MM-DD" (kept as text; grouping uses the local day).
    let day: String
    let slot: String
    let read: Bool

    enum CodingKeys: String, CodingKey {
        case id, category, title, summary, body, sources, day, slot, read
        case topicKey = "topic_key"
        case shortVersion = "short_version"
        case publishedAt = "published_at"
    }
}

struct NewsListOut: Decodable {
    let items: [NewsItemOut]
    let nextCursor: String?
    let noFollowMatch: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
        case noFollowMatch = "no_follow_match"
    }
}

struct NewsReadAllOut: Decodable {
    let marked: Int
}
