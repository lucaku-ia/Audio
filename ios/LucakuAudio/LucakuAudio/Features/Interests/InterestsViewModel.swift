import Foundation

/// Drives Features/Interests/InterestsView.swift.
///
/// Real data source: `GET /onboarding/interest_options` (the full curated
/// catalogue, localized server-side) and `GET /onboarding/state` (which
/// interest ids the customer has selected — `OnboardingState.selected_interests`).
/// "Standing interests" = the customer's selected ids, resolved to labels.
/// "Explore more" = every catalogue option NOT already selected — a real,
/// server-sourced list (not invented "related topics"; see the module
/// comment in OnboardingModels.swift and the README's note that Home's own
/// per-topic suggestion surface has no AI-backed source yet either).
///
/// Add/remove both go through the one real mutation endpoint,
/// `PATCH /onboarding/interests`, which replaces the whole list — there is
/// no per-interest endpoint. Cadence and pause/resume are NOT modeled
/// anywhere server-side (no field on `OnboardingState` for either), so this
/// view model deliberately does not fabricate persisted state for them; the
/// view renders those controls as visually-present-but-inert stubs.
@MainActor
final class InterestsViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    struct Interest: Identifiable, Equatable {
        let id: String
        let label: String
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var standingInterests: [Interest] = []
    @Published private(set) var exploreOptions: [Interest] = []

    /// Row currently showing its expand-below disclosure (cadence stub +
    /// real "Remove interest" action). Only one row expands at a time, same
    /// idiom as Home's block-row expand (HomeComponents.swift).
    @Published var expandedInterestId: String?

    /// In-flight remove/add calls, keyed by interest id, so each row can show
    /// its own inline spinner and the rest of the list stays interactive.
    @Published private(set) var pendingIds: Set<String> = []

    @Published var errorMessage: String?

    private var allOptions: [InterestOption] = []
    private var selectedIds: [String] = []

    func load(token: String) async {
        loadState = .loading
        do {
            async let optionsTask = APIClient.shared.interestOptions(token: token)
            async let stateTask = APIClient.shared.onboardingState(token: token)
            let (options, state) = try await (optionsTask, stateTask)
            allOptions = options
            selectedIds = state.selectedInterests
            recompute()
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func recompute() {
        let labelById = Dictionary(uniqueKeysWithValues: allOptions.map { ($0.id, $0.label) })
        // Preserve the order the customer originally selected them in
        // (selected_interests is a plain ordered list server-side).
        standingInterests = selectedIds.compactMap { id in
            labelById[id].map { Interest(id: id, label: $0) }
        }
        let selectedSet = Set(selectedIds)
        exploreOptions = allOptions
            .filter { !selectedSet.contains($0.id) }
            .map { Interest(id: $0.id, label: $0.label) }
    }

    /// Real, wired action: adds `id` to the standing list via
    /// `PATCH /onboarding/interests` with the full updated list.
    func addInterest(id: String, token: String) async {
        guard !selectedIds.contains(id) else { return }
        await mutate(newList: selectedIds + [id], id: id, token: token)
    }

    /// Real, wired action: the mockup's destructive "Remove interest" chip
    /// under a standing interest's expand disclosure. The backend requires
    /// at least one interest (`InterestsBody.interests: Field(min_length=1)`),
    /// so removing the last one is refused locally with a clear message
    /// rather than round-tripping to a 422.
    func removeInterest(id: String, token: String) async {
        guard selectedIds.contains(id) else { return }
        guard selectedIds.count > 1 else {
            errorMessage = "You need at least one standing interest — add another before removing this one."
            return
        }
        expandedInterestId = nil
        await mutate(newList: selectedIds.filter { $0 != id }, id: id, token: token)
    }

    private func mutate(newList: [String], id: String, token: String) async {
        pendingIds.insert(id)
        errorMessage = nil
        defer { pendingIds.remove(id) }
        do {
            let state = try await APIClient.shared.setInterests(newList, token: token)
            selectedIds = state.selectedInterests
            recompute()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleExpanded(_ id: String) {
        expandedInterestId = expandedInterestId == id ? nil : id
    }
}
