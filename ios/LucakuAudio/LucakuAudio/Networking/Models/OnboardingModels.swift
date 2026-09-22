import Foundation

// Matches backend/app/api/routes/onboarding.py exactly (field names, types,
// optionality) — read directly from the route file, not guessed. Backing
// model: backend/app/models/onboarding.py's `OnboardingState`.
//
// IMPORTANT — this is the ONLY real interests data model in the backend.
// There is no dedicated "Interests" table/route: a customer's standing
// interests are just `OnboardingState.selected_interests`, a flat list of
// interest-id strings (e.g. "markets", "technology") chosen from the curated
// catalogue in `backend/app/data/onboarding_seeds.json` and served back via
// `GET /onboarding/interest_options`. There is:
//   - no per-interest cadence field (no "daily"/"weekly" concept at all),
//   - no per-interest paused/active flag,
//   - no per-interest add/remove endpoint — `PATCH /onboarding/interests`
//     replaces the ENTIRE list in one call, so "add" and "remove" are both
//     implemented client-side as "send the new full list."
// The Interests screen (Features/Interests/) is built against exactly this
// shape; anything the mockup depicts beyond it (cadence text, a mute toggle
// that persists) is a deliberate, clearly-commented UI stub — see
// InterestsViewModel.swift and InterestsView.swift.

/// `GET /onboarding/interest_options` — the full curated catalogue, already
/// localized server-side to the customer's `Cliente.idioma`.
struct InterestOption: Decodable, Identifiable, Equatable {
    let id: String
    let label: String
}

/// `GET /onboarding/state` / `PATCH /onboarding/interests` response body
/// (`StateOut` in onboarding.py). Only `selectedInterests` is used by the
/// Interests screen today; the rest is decoded for completeness/future reuse
/// rather than fabricating a narrower type.
struct OnboardingStateOut: Decodable {
    let step: String
    let selectedInterests: [String]
    let activeRequestCount: Int
    let notificationsEnabled: Bool?
    let tourCompleted: Bool
    let consentAccepted: Bool
    let onboardingComplete: Bool

    enum CodingKeys: String, CodingKey {
        case step
        case selectedInterests = "selected_interests"
        case activeRequestCount = "active_request_count"
        case notificationsEnabled = "notifications_enabled"
        case tourCompleted = "tour_completed"
        case consentAccepted = "consent_accepted"
        case onboardingComplete = "onboarding_complete"
    }
}

/// `PATCH /onboarding/interests` request body (`InterestsBody`). The backend
/// requires at least one interest (`Field(min_length=1)`) — enforced
/// client-side too before sending, so a failed "remove the last interest"
/// attempt surfaces a clear local message instead of a raw 422.
struct InterestsBody: Encodable {
    let interests: [String]
}

/// `GET /onboarding/suggestions?interest=` response — a curated seed-list
/// pick for one interest (`app/data/onboarding_seeds.json`, not AI; see that
/// route's own docstring). Each string is ready to save as-is via
/// `POST /requests`, or edit first.
struct SuggestionsOut: Decodable {
    let interest: String
    let suggestions: [String]
}

/// `PATCH /onboarding/step` request body. `step` is one of the backend's
/// `OnboardingStep` enum's raw values — sent as a plain string since this
/// client only ever forwards a value it already got from `StateOut.step`,
/// never constructs one from scratch.
struct SetStepBody: Encodable {
    let step: String
}

/// `PATCH /onboarding/notifications` request body.
struct NotificationsBody: Encodable {
    let enabled: Bool
}

/// `POST /onboarding/confirm` response (`ConfirmationOut`) — the PRD's T-60
/// first-episode scheduling message, computed from `Profile.delivery_time`.
struct OnboardingConfirmationOut: Decodable {
    let message: String
    /// "scheduled" | "on_demand"
    let path: String
    let firstEpisodeEta: Date

    enum CodingKeys: String, CodingKey {
        case message, path
        case firstEpisodeEta = "first_episode_eta"
    }
}
