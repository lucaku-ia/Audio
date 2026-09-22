import Foundation

/// Mirrors `backend/app/models/onboarding.py`'s `OnboardingStep` enum exactly
/// (raw values match server JSON). `consent` has no server-side equivalent —
/// it's a local-only screen shown before `interests` the first time, gating
/// `POST /onboarding/consent` (Ley 1581 de 2012 — see onboarding.py's own
/// docstring: "consent language must appear before the first request is
/// saved").
enum OnboardingStep: String {
    case consent
    case interests
    case requests
    case delivery
    case sound
    case confirm
    case notifications
    case tour
    case done
}

/// Drives the whole Onboarding flow (Features/Onboarding/OnboardingView.swift)
/// against the real backend state machine (`backend/app/api/routes/
/// onboarding.py`) — resumable server-side per the PRD, so relaunching mid-flow
/// picks up at the same step rather than restarting.
///
/// One important asymmetry with the backend: `delivery` and `sound` are two
/// separate UI steps here (matching the PRD's two separate customer stories),
/// but both write through the SAME endpoint, `PUT /api/profile`
/// (`ProfileSetupBody` — a full write, not a partial PATCH). Each step's
/// "Continue" therefore resends every profile field this view model is
/// currently holding, not just the ones that screen owns, so nothing entered
/// on an earlier step is lost when a later step's save overwrites the row.
@MainActor
final class OnboardingViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var step: OnboardingStep = .consent
    @Published private(set) var idioma: String = "es"

    // Interests
    @Published private(set) var interestOptions: [InterestOption] = []
    @Published var selectedInterests: Set<String> = []

    // Requests
    @Published private(set) var activeRequestCount = 0
    /// AI-derived topics for requests added so far this session — shown as a
    /// running "what you've added" list.
    @Published private(set) var addedTopics: [String] = []
    @Published private(set) var suggestionsByInterest: [String: [String]] = [:]
    @Published private(set) var loadingSuggestionsFor: Set<String> = []
    @Published var freeText: String = ""
    @Published private(set) var isSubmittingRequest = false

    // Delivery
    @Published var deliveryTime: Date = {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 7
        components.minute = 0
        return Calendar.current.date(from: components) ?? Date()
    }()
    @Published var deliveryTimezone: String = TimeZone.current.identifier
    /// nil = no limit. PRD default is 10.
    @Published var maxLengthMinutes: Int? = 10

    // Sound
    @Published var narrationStyle: NarrationStyle = .news
    @Published var voiceId: String = ""

    // Confirm
    @Published private(set) var confirmationMessage: String?
    @Published private(set) var isConfirming = false

    // Notifications
    @Published private(set) var notificationsEnabled = false

    @Published var errorMessage: String?

    /// The onboarding-narration speech language for the customer's captured
    /// `idioma` — see `SpeechService`/`LucakuLocale`.
    var speechLanguage: String { LucakuLocale.speechLanguage(forIdioma: idioma) }

    let onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    // MARK: - Load / resume

    func load(token: String) async {
        loadState = .loading
        do {
            async let meResult = APIClient.shared.me(token: token)
            async let stateResult = APIClient.shared.onboardingState(token: token)
            async let optionsResult = APIClient.shared.interestOptions(token: token)
            let me = try await meResult
            let state = try await stateResult
            interestOptions = try await optionsResult

            idioma = me.idioma
            selectedInterests = Set(state.selectedInterests)
            activeRequestCount = state.activeRequestCount
            notificationsEnabled = state.notificationsEnabled ?? false

            if state.onboardingComplete {
                onFinished()
                return
            }
            // Resume at the server's own step, except: if consent hasn't been
            // accepted yet, show that local-only screen first regardless of
            // how far `state.step` otherwise got (shouldn't normally happen,
            // but consent is the one gate this client — not the server —
            // enforces before letting requests be created).
            if !state.consentAccepted {
                step = .consent
            } else {
                step = OnboardingStep(rawValue: state.step) ?? .interests
            }
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Consent

    func acceptConsent(token: String) async {
        do {
            try await APIClient.shared.acceptOnboardingConsent(token: token)
            step = .interests
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Interests

    func toggleInterest(_ id: String) {
        if selectedInterests.contains(id) {
            selectedInterests.remove(id)
        } else {
            selectedInterests.insert(id)
        }
    }

    func continueFromInterests(token: String) async {
        guard !selectedInterests.isEmpty else {
            errorMessage = "Pick at least one topic to continue."
            return
        }
        do {
            // PATCH /onboarding/interests auto-advances interests -> requests
            // server-side on first call — see onboarding.py's set_interests.
            let state = try await APIClient.shared.setInterests(Array(selectedInterests), token: token)
            step = OnboardingStep(rawValue: state.step) ?? .requests
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Requests

    func loadSuggestions(interest: String, token: String) async {
        guard suggestionsByInterest[interest] == nil, !loadingSuggestionsFor.contains(interest) else { return }
        loadingSuggestionsFor.insert(interest)
        defer { loadingSuggestionsFor.remove(interest) }
        do {
            let result = try await APIClient.shared.onboardingSuggestions(interest: interest, token: token)
            suggestionsByInterest[interest] = result.suggestions
        } catch {
            // Non-fatal — the free-text field is always available as a fallback.
        }
    }

    /// Saves `text` as a new standing request (`POST /requests`,
    /// `created_from=onboarding`) — used for both an approved/edited
    /// suggestion and free (typed or dictated) text; the backend doesn't
    /// distinguish them. Returns true on success so the caller can clear its
    /// input field only when the save actually happened.
    @discardableResult
    func addRequest(text: String, token: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5, !isSubmittingRequest else { return false }
        isSubmittingRequest = true
        errorMessage = nil
        defer { isSubmittingRequest = false }
        do {
            let request = try await APIClient.shared.createRequest(
                rawText: trimmed, kind: "standing", createdFrom: "onboarding", token: token
            )
            activeRequestCount += 1
            addedTopics.append(request.structured.topic)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func continueFromRequests(token: String) async {
        guard activeRequestCount >= 1 else {
            errorMessage = "Add at least one topic before continuing — this is the one step Lucaku can't skip."
            return
        }
        await advanceStep(to: .delivery, token: token)
    }

    // MARK: - Delivery

    func continueFromDelivery(token: String) async {
        await saveProfile(token: token, thenAdvanceTo: .sound)
    }

    // MARK: - Sound

    func continueFromSound(token: String) async {
        await saveProfile(token: token, thenAdvanceTo: .confirm)
    }

    private func saveProfile(token: String, thenAdvanceTo nextStep: OnboardingStep) async {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let body = ProfileSetupBody(
            voiceId: voiceId.trimmingCharacters(in: .whitespaces).isEmpty ? nil : voiceId,
            narrationStyle: narrationStyle,
            deliveryTime: formatter.string(from: deliveryTime),
            deliveryTimezone: deliveryTimezone,
            maxLengthMinutes: maxLengthMinutes
        )
        do {
            _ = try await APIClient.shared.setupProfile(body, token: token)
            await advanceStep(to: nextStep, token: token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Confirm

    func confirm(token: String) async {
        isConfirming = true
        errorMessage = nil
        defer { isConfirming = false }
        do {
            let result = try await APIClient.shared.confirmOnboarding(token: token)
            confirmationMessage = result.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func continueFromConfirm(token: String) async {
        await advanceStep(to: .notifications, token: token)
    }

    // MARK: - Notifications

    func setNotifications(enabled: Bool, token: String) async {
        do {
            // PATCH /onboarding/notifications advances notifications -> tour
            // server-side — see onboarding.py's set_notifications.
            let state = try await APIClient.shared.setOnboardingNotifications(enabled: enabled, token: token)
            notificationsEnabled = enabled
            step = OnboardingStep(rawValue: state.step) ?? .tour
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Tour / finish

    func finish(token: String) async {
        do {
            _ = try await APIClient.shared.completeOnboarding(token: token)
            onFinished()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Shared

    private func advanceStep(to newStep: OnboardingStep, token: String) async {
        do {
            // PATCH /onboarding/step — the manual transition path for the
            // skip affordances (voice, notifications, additional requests are
            // all skippable per the PRD's own tenet 3).
            let state = try await APIClient.shared.setOnboardingStep(newStep.rawValue, token: token)
            step = OnboardingStep(rawValue: state.step) ?? newStep
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
