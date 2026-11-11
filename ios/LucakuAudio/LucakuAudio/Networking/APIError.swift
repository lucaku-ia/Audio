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
            // act on.
            if (400..<500).contains(status), !message.isEmpty {
                return message
            }
            // 503 is this backend's own "the model is unreachable, try again
            // shortly" (app/main.py's ModelUnavailable handler) — already
            // written for a person, so it is passed through like a 4xx.
            if status == 503, !message.isEmpty {
                return message
            }
            // Every other 5xx is a fault with nothing a customer can use.
            // This used to return "Server error (500): Internal Server Error",
            // which is how that string ended up in an onboarding speech
            // bubble, in the assistant's voice, next to a friendly avatar.
            // The status code belongs in a log, not in a conversation.
            return "Something went wrong on our side. Try again in a moment."
        case .decoding:
            return "The server's response didn't match what this app expected."
        case .transport(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        }
    }
}

/// Mirrors FastAPI's default error body shape: `{"detail": "..."}`, used by
/// every HTTPException raised in the routes (auth.py, generation.py, deps.py).
private struct FastAPIErrorBody: Decodable {
    let detail: String?
}

/// FastAPI's OTHER error body shape, which this client used to ignore.
///
/// A route that raises `HTTPException(400, detail: "...")` sends a plain
/// string. But a request that fails *validation* never reaches the route at
/// all — FastAPI rejects it with a 422 whose `detail` is an ARRAY of
/// per-field objects:
///
///     {"detail": [{"type": "string_too_short",
///                  "loc": ["body", "password"],
///                  "msg": "String should have at least 8 characters",
///                  "ctx": {"min_length": 8}}]}
///
/// Decoding that into `detail: String?` yields nil, so the whole body fell
/// through to the raw-text fallback below and the customer was shown either a
/// JSON blob or, after LoginView substituted its own wording, a flatly wrong
/// sentence. Signing up with a 3-character password reported "That email or
/// password doesn't match. Try again." — on a form where there is nothing to
/// match yet, and with no mention of the actual eight-character rule.
private struct FastAPIValidationItem: Decodable {
    let loc: [LocComponent]
    let msg: String
    let type: String
    let ctx: Ctx?

    struct Ctx: Decodable { let min_length: Int?; let max_length: Int? }

    /// `loc` mixes strings and array indices (`["body", "items", 0, "name"]`).
    enum LocComponent: Decodable {
        case string(String), index(Int)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s) }
            else { self = .index((try? c.decode(Int.self)) ?? -1) }
        }
        var name: String? { if case .string(let s) = self { return s }; return nil }
    }

    /// The field this is about — the last string in `loc`, skipping the
    /// "body"/"query" prefix FastAPI always puts first.
    var fieldName: String? {
        loc.compactMap(\.name).last(where: { $0 != "body" && $0 != "query" && $0 != "path" })
    }
}

private struct FastAPIValidationBody: Decodable {
    let detail: [FastAPIValidationItem]
}

/// Rewrites one validation failure as a sentence a customer can act on.
///
/// Pydantic's own text is accurate but written for an API consumer ("String
/// should have at least 8 characters" — which string?). The field name has to
/// come back in, and the common cases deserve real wording. The field name is
/// deliberately kept IN the sentence: callers key off it to decide which input
/// to outline.
private func humanize(_ item: FastAPIValidationItem) -> String {
    let field = item.fieldName ?? ""
    let label: String
    switch field {
    case "password": label = "Password"
    case "email": label = "Email"
    case "nombre", "name": label = "Name"
    default: label = field.isEmpty ? "That value" : field.prefix(1).uppercased() + field.dropFirst()
    }

    switch item.type {
    case "string_too_short":
        if let min = item.ctx?.min_length {
            return field == "password"
                ? "Password must be at least \(min) characters."
                : "\(label) must be at least \(min) characters."
        }
        return "\(label) is too short."
    case "string_too_long":
        if let max = item.ctx?.max_length { return "\(label) must be \(max) characters or fewer." }
        return "\(label) is too long."
    case "missing":
        return "\(label) is required."
    case "value_error", "string_pattern_mismatch":
        return field == "email" ? "That doesn't look like a valid email address." : "\(label) isn't valid."
    default:
        return "\(label): \(item.msg)"
    }
}

/// Best-effort extraction of FastAPI's `detail` from an error response body,
/// handling BOTH shapes — a plain string from an HTTPException, and the
/// validation array from a 422 — and falling back to the raw body only when
/// neither parses.
func extractErrorDetail(from data: Data) -> String {
    let decoder = JSONDecoder()

    if let body = try? decoder.decode(FastAPIErrorBody.self, from: data), let detail = body.detail {
        return detail
    }

    if let body = try? decoder.decode(FastAPIValidationBody.self, from: data), !body.detail.isEmpty {
        // One problem at a time. Showing a customer three stacked validation
        // sentences at once reads as a wall; they fix the first and resubmit.
        return humanize(body.detail[0])
    }

    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
        return text
    }
    return "Unknown error."
}
