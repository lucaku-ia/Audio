import Foundation

/// Errors surfaced by `APIClient`. Kept small and specific enough that a view
/// can show something more useful than "something went wrong" while this
/// scaffold's own UI stays plain (see README: styling is a separate team's
/// job right now).
enum APIError: LocalizedError {
    case invalidURL
    case notAuthenticated
    case server(status: Int, message: String)
    case decoding(underlying: Error)
    case transport(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid request URL."
        case .notAuthenticated:
            return "You're not signed in."
        case .server(let status, let message):
            // A 4xx from this backend is usually a deliberate, customer-facing
            // sentence, not a fault — `structure_request`'s clarity screen
            // replies things like "We couldn't tell which team you mean;
            // reply with the team name and league". Dressing that up as
            // "Server error (400)" buries the one part the customer needs to
            // act on. 5xx (and anything without a message) really is a fault,
            // so it keeps the status code for reporting.
            if (400..<500).contains(status), !message.isEmpty {
                return message
            }
            return "Server error (\(status)): \(message)"
        case .decoding:
            return "The server's response didn't match what this app expected."
        case .transport(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        }
    }
}

/// Mirrors FastAPI's default error body shape: `{"detail": "..."}`, used by
/// every HTTPException raised in the routes read for this scaffold (auth.py,
/// generation.py, deps.py, etc).
private struct FastAPIErrorBody: Decodable {
    let detail: String?
}

/// Best-effort extraction of FastAPI's `detail` field from an error response
/// body, falling back to the raw body text (or a generic message) when it
/// isn't shaped as expected.
func extractErrorDetail(from data: Data) -> String {
    if let body = try? JSONDecoder().decode(FastAPIErrorBody.self, from: data), let detail = body.detail {
        return detail
    }
    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
        return text
    }
    return "Unknown error."
}
