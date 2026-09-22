import Foundation

/// Thin networking layer over `URLSession` + async/await. No completion
/// handlers, no third-party HTTP library — matches every endpoint this
/// scaffold needs against the real routes in
/// backend/app/api/routes/{auth,home,generation,search}.py.
///
/// An `actor` because `URLSession` + `JSONDecoder` here are stateless and
/// safe to share, and callers may reasonably fire requests concurrently
/// (e.g. Home's banner + recent + shared inventory in one call already, but
/// a future screen might not be).
actor APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(session: URLSession = .shared) {
        self.session = session

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    // MARK: - Auth (backend/app/api/routes/auth.py)

    func signup(_ body: SignupRequest) async throws -> TokenResponse {
        try await send(path: "/auth/signup", method: "POST", jsonBody: body, token: nil)
    }

    /// POST /api/auth/login is FastAPI's `OAuth2PasswordRequestForm` —
    /// `application/x-www-form-urlencoded`, not JSON. `form.username` is the
    /// email (OAuth2PasswordRequestForm's field is literally named
    /// `username`; the backend reads it as `form.username` and looks it up
    /// by `Cliente.email`).
    func login(email: String, password: String) async throws -> TokenResponse {
        var request = try makeRequest(path: "/auth/login", method: "POST", token: nil)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let formBody = "username=\(formEncoded(email))&password=\(formEncoded(password))"
        request.httpBody = Data(formBody.utf8)
        return try await perform(request)
    }

    func logout(token: String) async throws {
        _ = try await sendRaw(path: "/auth/logout", method: "POST", token: token)
    }

    func me(token: String) async throws -> MeResponse {
        try await send(path: "/auth/me", method: "GET", token: token)
    }

    // MARK: - Home (backend/app/api/routes/home.py)

    func home(token: String) async throws -> HomeOut {
        try await send(path: "/home", method: "GET", token: token)
    }

    func requestToday(rawText: String, token: String) async throws -> RequestOut {
        try await send(
            path: "/home/request-today", method: "POST",
            jsonBody: RequestTodayBody(rawText: rawText), token: token
        )
    }

    // MARK: - Episode Generator (backend/app/api/routes/generation.py)

    /// Triggers on-demand generation for the calling customer. Runs the
    /// pipeline synchronously server-side (the route's own docstring warns
    /// this can be slow and time out for a customer with many active
    /// requests) — so this call may legitimately take a while.
    func runGeneration(token: String) async throws -> JobOut {
        // URLSession's default request timeout is 60s of silence, and this
        // route sends nothing until the whole research → write → voice
        // pipeline finishes (routinely 1–2 minutes) — without a longer
        // timeout the app reports a failure while the server is still
        // happily generating the episode.
        var request = try makeRequest(path: "/generation/run", method: "POST", token: token)
        request.timeoutInterval = 300
        return try await perform(request)
    }

    /// Any single episode the caller may hear: one of their own (a past day
    /// from Recent) or a shared-inventory sample (Home's "For you"/"Explore").
    func episode(id: String, token: String) async throws -> EpisodeOut {
        try await send(path: "/generation/episodes/\(id)", method: "GET", token: token)
    }

    func job(id: String, token: String) async throws -> JobOut {
        try await send(path: "/generation/jobs/\(id)", method: "GET", token: token)
    }

    func latestEpisode(token: String) async throws -> EpisodeOut {
        try await send(path: "/generation/episodes/latest", method: "GET", token: token)
    }

    // MARK: - Profile / Settings (backend/app/api/routes/profile.py)

    func getProfile(token: String) async throws -> ProfileOut {
        try await send(path: "/profile", method: "GET", token: token)
    }

    /// PUT /api/profile — Onboarding's full initial write (delivery time,
    /// max length, voice, narration style). See `ProfileSetupBody`'s doc for
    /// why this is a separate call from `updateSettings` (PATCH) below.
    func setupProfile(_ body: ProfileSetupBody, token: String) async throws -> ProfileOut {
        try await send(path: "/profile", method: "PUT", jsonBody: body, token: token)
    }

    /// Partial update — only the fields set on `body` are sent (see
    /// `SettingsBody`'s doc comment), matching the backend's
    /// `model_fields_set` partial-update semantics.
    func updateSettings(_ body: SettingsBody, token: String) async throws -> SettingsOut {
        try await send(path: "/profile", method: "PATCH", jsonBody: body, token: token)
    }

    // MARK: - Onboarding / Interests (backend/app/api/routes/onboarding.py)

    /// The curated interest catalogue, localized server-side. Used by the
    /// Interests screen both to label a customer's `selected_interests` ids
    /// and to populate "Explore more" (every option not already selected).
    func interestOptions(token: String) async throws -> [InterestOption] {
        try await send(path: "/onboarding/interest_options", method: "GET", token: token)
    }

    func onboardingState(token: String) async throws -> OnboardingStateOut {
        try await send(path: "/onboarding/state", method: "GET", token: token)
    }

    /// Replaces the customer's ENTIRE standing-interests list — there is no
    /// per-interest add/remove endpoint server-side (see OnboardingModels.swift).
    func setInterests(_ interests: [String], token: String) async throws -> OnboardingStateOut {
        try await send(path: "/onboarding/interests", method: "PATCH", jsonBody: InterestsBody(interests: interests), token: token)
    }

    func onboardingSuggestions(interest: String, token: String) async throws -> SuggestionsOut {
        try await send(
            path: "/onboarding/suggestions", method: "GET",
            query: [URLQueryItem(name: "interest", value: interest)], token: token
        )
    }

    func acceptOnboardingConsent(token: String) async throws {
        _ = try await sendRaw(path: "/onboarding/consent", method: "POST", token: token)
    }

    @discardableResult
    func setOnboardingStep(_ step: String, token: String) async throws -> OnboardingStateOut {
        try await send(path: "/onboarding/step", method: "PATCH", jsonBody: SetStepBody(step: step), token: token)
    }

    func confirmOnboarding(token: String) async throws -> OnboardingConfirmationOut {
        try await send(path: "/onboarding/confirm", method: "POST", token: token)
    }

    @discardableResult
    func setOnboardingNotifications(enabled: Bool, token: String) async throws -> OnboardingStateOut {
        try await send(
            path: "/onboarding/notifications", method: "PATCH",
            jsonBody: NotificationsBody(enabled: enabled), token: token
        )
    }

    @discardableResult
    func completeOnboarding(token: String) async throws -> OnboardingStateOut {
        try await send(path: "/onboarding/complete", method: "POST", token: token)
    }

    // MARK: - Account & data (backend/app/api/routes/account.py)

    /// Returns the raw JSON body of the customer's full data export — see
    /// `SettingsModels.swift`'s note on why this isn't decoded into structs.
    func exportAccountData(token: String) async throws -> Data {
        try await sendRaw(path: "/account/export", method: "GET", token: token)
    }

    func deleteAccount(token: String) async throws -> DeleteAccountResponse {
        try await send(path: "/account", method: "DELETE", token: token)
    }

    // MARK: - Search & AI (backend/app/api/routes/search.py)

    func searchHistory(offset: Int = 0, limit: Int = 20, token: String) async throws -> HistoryOut {
        try await send(
            path: "/search/history",
            method: "GET",
            query: [URLQueryItem(name: "offset", value: "\(offset)"), URLQueryItem(name: "limit", value: "\(limit)")],
            token: token
        )
    }

    func search(query: String, limit: Int = 20, token: String) async throws -> SearchOut {
        try await send(
            path: "/search/query",
            method: "GET",
            query: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "\(limit)")],
            token: token
        )
    }

    // MARK: - Request Management (backend/app/api/routes/requests.py)

    /// GET /requests?status=... — used by Search to check which topics
    /// already have an active standing request, so "Add as a new interest"
    /// doesn't offer to create a duplicate for something already tracked.
    func listRequests(status: String? = nil, kind: String? = nil, token: String) async throws -> [RequestOut] {
        var query: [URLQueryItem] = []
        if let status {
            query.append(URLQueryItem(name: "status", value: status))
        }
        if let kind {
            query.append(URLQueryItem(name: "kind", value: kind))
        }
        return try await send(path: "/requests", method: "GET", query: query, token: token)
    }

    /// POST /requests — used by Search's "Add as a new interest" action (see
    /// `CreateRequestBody`'s doc comment for why this, and not a dedicated
    /// interests endpoint, is the real backend operation behind that UI).
    func createRequest(rawText: String, kind: String = "standing", createdFrom: String, token: String) async throws -> RequestOut {
        try await send(
            path: "/requests", method: "POST",
            jsonBody: CreateRequestBody(rawText: rawText, kind: kind, createdFrom: createdFrom),
            token: token
        )
    }

    // MARK: - Request building / sending

    private func makeRequest(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        token: String?
    ) throws -> URLRequest {
        var components = URLComponents(url: Config.apiBaseURL, resolvingAgainstBaseURL: false)
        components?.path = Config.apiPrefix + path
        if !query.isEmpty {
            components?.queryItems = query
        }
        guard let url = components?.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await performRaw(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    @discardableResult
    private func performRaw(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(underlying: URLError(.badServerResponse))
        }

        if http.statusCode == 401 {
            // Tells SessionStore to clear itself so ContentView routes back
            // to Login instead of every screen just failing silently — see
            // Notification.Name.sessionExpired's doc in SessionStore.swift.
            NotificationCenter.default.post(name: .sessionExpired, object: nil)
            throw APIError.notAuthenticated
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: http.statusCode, message: extractErrorDetail(from: data))
        }
        return data
    }

    private func send<T: Decodable>(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        token: String?
    ) async throws -> T {
        let request = try makeRequest(path: path, method: method, query: query, token: token)
        return try await perform(request)
    }

    private func send<Body: Encodable, T: Decodable>(
        path: String,
        method: String,
        jsonBody: Body,
        token: String?
    ) async throws -> T {
        var request = try makeRequest(path: path, method: method, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(jsonBody)
        return try await perform(request)
    }

    @discardableResult
    private func sendRaw(path: String, method: String, token: String?) async throws -> Data {
        let request = try makeRequest(path: path, method: method, token: token)
        return try await performRaw(request)
    }

    private func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// The backend's `datetime` fields (e.g. `creado_en`, `eta`,
    /// `published_at`) are Pydantic `datetime` values serialized by FastAPI
    /// as ISO 8601 with fractional seconds (e.g. "2026-09-18T10:15:30.123456").
    /// Plain `.iso8601` can't parse the fractional-second component, so this
    /// tries with fractional seconds first and falls back to without.
    static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)

            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: string) {
                return date
            }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: string) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected ISO 8601 date string, got \(string)"
            )
        }
    }
}
