import Foundation
import Combine

/// Drives the Player feature (block list + mini player + Now Playing +
/// tuning sheet) against the REAL `GET /api/generation/episodes/latest`
/// endpoint (see backend/app/api/routes/generation.py) — the only endpoint
/// today that returns an episode's blocks (question/topic, duration,
/// script). There is no separate "get episode blocks" or "get audio stream
/// URL" call to add: `EpisodeOut.audioUrl` (already modeled in
/// GenerationModels.swift) is the one audio URL for the whole episode, and
/// `BlockOut.startS`/`endS` are that file's offsets into it.
///
/// PLAYBACK ENGINE STATUS:
/// This now owns a real `AudioPlayerService` (AVFoundation, see
/// `Services/Audio/AudioPlayerService.swift`, merged via PR #18) instead of
/// the old UI-only `Timer`-driven fake transport. The backend serves ONE
/// concatenated mp3 per episode, not one per block, so "block-level
/// navigation" is implemented as SEEKING within that one continuous stream:
/// `selectBlock`/`skipToNextBlock`/`skipToPreviousBlock` all resolve to a
/// `seek(to:)` call on the block's real `start_s`, and `currentBlockIndex`
/// (the "currently playing" highlight) is derived every tick by comparing
/// the service's real, published `currentTime` against each block's
/// `start_s`/`end_s` range — there is no separately-advancing fake index to
/// keep in sync.
@MainActor
final class PlayerViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    // MARK: Published state

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var episode: EpisodeOut?
    /// Seed string for the generated cover art (see `LucakuCover`) of the
    /// episode in the player — set to whatever the card/tile the customer
    /// tapped was seeded with, so the mini player wears the same colour as
    /// the card it came from.
    @Published private(set) var coverSeed: String = "lucaku"
    /// Previously-played episodes for the "Earlier" section. Each row here
    /// represents a WHOLE past episode (search/history has no per-block
    /// detail for old episodes), so these rows are visually identical to a
    /// block row but are not tappable into a block-level player — see the
    /// comment on `EarlierRow` usage in PlayerListView.
    @Published private(set) var earlier: [HistoryEntryOut] = []

    /// Set only when the user tried to play an episode that has no
    /// `audio_url` yet (voicing still pending server-side) — a real, visible
    /// error distinct from a playback failure inside `AudioPlayerService`.
    @Published private(set) var audioUnavailableMessage: String?

    @Published var speed: PlaybackSpeed = .oneX {
        didSet {
            guard speed != oldValue else { return }
            audioService.setRate(Float(speed.rawValue))
        }
    }
    @Published var isNowPlayingExpanded: Bool = false

    // MARK: Now Playing UI state (screens spec 4.x)

    /// Which tab of Now Playing is showing: "In this episode" (default, 4.5)
    /// or "Transcript" (4.4).
    @Published var nowPlayingTab: NowPlayingTab = .episode
    /// "Not quite" feedback sheet (4.7) — the single feedback entry point.
    @Published var isFeedbackSheetOpen: Bool = false
    /// Share a story sheet (4.8-4.9).
    @Published var isShareSheetOpen: Bool = false
    /// Local-only: which episodes the customer marked "download to listen
    /// without data". TODO(backend): no offline-download support exists yet
    /// (no file cache in AudioPlayerService); this only drives the UI state.
    @Published private(set) var downloadedEpisodeIds: Set<String> = []
    /// Local-only per-story rating (Useful / Not quite), keyed by block id.
    @Published private var ratings: [String: AnswerRating] = [:]
    /// What the server holds per block id (needed to toggle a rating off).
    private var savedFeedback: [String: SavedFeedback] = [:]
    /// Session token, remembered from the last load for feedback calls.
    private var token: String?

    // MARK: Real audio engine

    /// Owned (or injected, e.g. for previews/tests) real playback engine —
    /// no more fake `Timer`. Exposed so callers that need the raw service
    /// (e.g. a future mini-player unification) can reach it, but the view
    /// layer should prefer this view model's derived properties below.
    let audioService: AudioPlayerService

    private var cancellables = Set<AnyCancellable>()
    /// Tracks the episode id currently loaded into `audioService`, so a
    /// pull-to-refresh that returns the SAME episode doesn't interrupt
    /// in-progress playback, but a genuinely new episode does.
    private var loadedEpisodeId: String?

    init(audioService: AudioPlayerService? = nil) {
        let resolvedAudioService = audioService ?? AudioPlayerService()
        self.audioService = resolvedAudioService

        // AudioPlayerService is its own ObservableObject; forward its
        // change notifications through this view model's so that views
        // observing PlayerViewModel (not audioService directly) still
        // redraw when currentTime/state/etc. change.
        resolvedAudioService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: Derived — episode / blocks

    var blocks: [BlockOut] { episode?.blocks ?? [] }
    var hasEpisode: Bool { episode != nil && !blocks.isEmpty }

    // MARK: Derived — real transport state (reads straight from AudioPlayerService)

    var isPlaying: Bool { audioService.isPlaying }
    var currentTime: TimeInterval { audioService.currentTime }

    /// The block whose `[start_s, end_s)` range contains the engine's real
    /// `currentTime` — recomputed on every engine tick, never tracked as a
    /// separate advancing index.
    var currentBlockIndex: Int {
        guard !blocks.isEmpty else { return 0 }
        if let index = blocks.firstIndex(where: { block in
            Double(block.startS) <= currentTime && currentTime < Double(block.endS)
        }) {
            return index
        }
        // Before the engine has loaded (currentTime == 0) or past the last
        // block's end (e.g. right at episode end), clamp to a sane edge.
        if currentTime >= Double(blocks.last?.endS ?? 0) {
            return blocks.count - 1
        }
        return 0
    }

    var currentBlock: BlockOut? {
        blocks.indices.contains(currentBlockIndex) ? blocks[currentBlockIndex] : nil
    }

    var currentBlockDurationS: Int {
        guard let block = currentBlock else { return 0 }
        return max(0, block.endS - block.startS)
    }

    var currentBlockProgressFraction: Double {
        guard let block = currentBlock else { return 0 }
        let duration = Double(max(0, block.endS - block.startS))
        guard duration > 0 else { return 0 }
        return min(1, max(0, (currentTime - Double(block.startS)) / duration))
    }

    var isCaughtUp: Bool {
        if case .loaded = loadState {
            return blocks.isEmpty
        }
        return false
    }

    /// Real error surfaced by the audio engine (network failure, stream
    /// failure, timeout, audio-session failure) — never a silent hang.
    var playbackErrorMessage: String? {
        if case .failed(let error) = audioService.state {
            return error.errorDescription
        }
        return nil
    }

    /// Either an audio-engine error or "this episode has no audio yet" —
    /// whichever applies. Views should show this instead of hanging quietly.
    var displayedErrorMessage: String? {
        audioUnavailableMessage ?? playbackErrorMessage
    }

    var isBuffering: Bool {
        if case .buffering = audioService.state { return true }
        if case .loading = audioService.state { return true }
        return false
    }

    // MARK: Loading

    func load(token: String) async {
        self.token = token
        defer { Task { await loadSavedFeedback() } }
        loadState = .loading
        async let episodeResult: Result<EpisodeOut, Error> = fetchEpisode(token: token)
        async let historyResult: Result<HistoryOut, Error> = fetchHistory(token: token)

        let episode = await episodeResult
        let history = await historyResult

        switch episode {
        case .success(let episode):
            if episode.id != loadedEpisodeId {
                // A genuinely different episode than whatever (if anything)
                // is currently loaded into the engine — reset playback so we
                // don't keep streaming a stale episode's audio.
                audioService.stop()
                loadedEpisodeId = nil
            }
            self.episode = episode
            self.coverSeed = episode.headline ?? "today"
            audioUnavailableMessage = nil
            loadState = .loaded
        case .failure(let error):
            if let apiError = error as? APIError, case .server(let status, _) = apiError, status == 404 {
                // No episode yet today — this is the calm "You're caught up"
                // empty state, not an error.
                self.episode = nil
                loadState = .loaded
            } else {
                loadState = .failed(error.localizedDescription)
            }
        }

        if case .success(let history) = history {
            // Exclude whatever we already show as "today" so Earlier doesn't
            // duplicate it.
            var todayId: String?
            if case .success(let loadedEpisode) = episode { todayId = loadedEpisode.id }
            earlier = history.items.filter { $0.episodeId != todayId }
        }
    }

    /// The episode currently loaded into the shared player, if any — Home
    /// compares this against today's episode id so a playing sample or past
    /// day never lights up today's block rows.
    var loadedEpisodeIdentifier: String? { episode?.id }

    /// Loads one specific episode (a shared sample from "For you"/"Explore",
    /// or a past day from Recent) into the shared player. Unlike `load(token:)`
    /// — which always means "today's own latest episode" — this is what makes
    /// Home's shelves actually playable. `autoplay: true` starts it from the
    /// first block right away (the Spotify-style "tap a card, it plays" feel).
    /// Returns false (and sets `audioUnavailableMessage`) if the episode
    /// couldn't be fetched, so the caller can leave the UI alone.
    @discardableResult
    func loadEpisode(id: String, token: String, autoplay: Bool, coverSeed: String? = nil) async -> Bool {
        self.token = token
        if episode?.id == id, hasEpisode {
            if autoplay { selectBlock(0, autoplay: true) }
            return true
        }
        do {
            let fetched = try await APIClient.shared.episode(id: id, token: token)
            // A genuinely different episode than whatever's in the engine —
            // reset playback so we never keep streaming the old one's audio.
            audioService.stop()
            loadedEpisodeId = nil
            self.episode = fetched
            self.coverSeed = coverSeed ?? fetched.headline ?? "lucaku"
            audioUnavailableMessage = nil
            loadState = .loaded
            Task { await loadSavedFeedback() }
            if autoplay { selectBlock(0, autoplay: true) }
            return true
        } catch {
            audioUnavailableMessage = error.localizedDescription
            return false
        }
    }

    private func fetchEpisode(token: String) async -> Result<EpisodeOut, Error> {
        do {
            return .success(try await APIClient.shared.latestEpisode(token: token))
        } catch {
            return .failure(error)
        }
    }

    private func fetchHistory(token: String) async -> Result<HistoryOut, Error> {
        do {
            return .success(try await APIClient.shared.searchHistory(offset: 0, limit: 10, token: token))
        } catch {
            // Earlier section is a nice-to-have; a failure here shouldn't
            // block the primary block-list experience.
            return .failure(error)
        }
    }

    // MARK: Transport (real — backed by AudioPlayerService)

    /// Loads the episode's one continuous mp3 into the engine, if it isn't
    /// already loaded. No-op if already loaded (so repeated taps don't
    /// restart playback from zero).
    private func ensureAudioLoaded() {
        guard audioService.currentItem == nil else { return }
        guard let episode, let urlString = episode.audioUrl, let url = URL(string: urlString) else {
            audioUnavailableMessage = "Audio isn't ready for this episode yet. Check back shortly."
            return
        }
        audioUnavailableMessage = nil
        audioService.play(
            url: url,
            title: episode.headline ?? "Lucaku Audio",
            subtitle: episode.fecha,
            knownDuration: episode.durationS.map(TimeInterval.init)
        )
        loadedEpisodeId = episode.id
    }

    /// Selects a block as "now playing" by seeking the real engine to that
    /// block's `start_s` — mirrors tapping any row in the block list per
    /// DESIGN_SPEC_V3.md's "block list, not a timeline" pattern — never a
    /// scrub-bar seek, but a real seek into the one continuous stream.
    func selectBlock(_ index: Int, autoplay: Bool = true) {
        guard blocks.indices.contains(index) else { return }
        let block = blocks[index]
        ensureAudioLoaded()
        guard audioService.currentItem != nil else { return } // no audio_url — bail, error already surfaced
        audioService.seek(to: Double(block.startS))
        if autoplay, !audioService.isPlaying {
            audioService.resume()
        }
    }

    func togglePlay() {
        guard hasEpisode else { return }
        if audioService.currentItem == nil {
            ensureAudioLoaded()
        } else {
            audioService.togglePlayPause()
        }
    }

    func skipToNextBlock() {
        let next = currentBlockIndex + 1
        guard blocks.indices.contains(next) else { return }
        selectBlock(next, autoplay: isPlaying || audioService.currentItem == nil)
    }

    func skipToPreviousBlock() {
        let previous = currentBlockIndex - 1
        guard previous >= 0 else { return }
        selectBlock(previous, autoplay: isPlaying || audioService.currentItem == nil)
    }

    func expandNowPlaying() {
        guard hasEpisode else { return }
        isNowPlayingExpanded = true
    }

    func collapseNowPlaying() {
        isNowPlayingExpanded = false
        isFeedbackSheetOpen = false
        isShareSheetOpen = false
    }

    // MARK: Episode-wide transport (scrubber, ±15 s, speed)

    /// Whole-episode length in seconds (engine duration once known, else the
    /// episode's declared length, else the last block's end).
    var episodeDurationS: Double {
        if audioService.duration > 0 { return audioService.duration }
        if let declared = episode?.durationS, declared > 0 { return Double(declared) }
        return Double(blocks.last?.endS ?? 0)
    }

    var episodeProgressFraction: Double {
        let duration = episodeDurationS
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    /// Scrubber seek: `fraction` is 0...1 of the whole episode.
    func seekEpisode(fraction: Double) {
        guard hasEpisode else { return }
        ensureAudioLoaded()
        guard audioService.currentItem != nil else { return }
        audioService.seek(to: min(1, max(0, fraction)) * episodeDurationS)
    }

    /// ±15 s skip (negative = back).
    func skip(by seconds: Double) {
        guard hasEpisode else { return }
        ensureAudioLoaded()
        guard audioService.currentItem != nil else { return }
        audioService.seek(to: max(0, currentTime + seconds))
    }

    /// Speed is always visible on the main screen; tapping steps through
    /// 1× → 1.25× → 1.5× → 1.75× → 2× and wraps.
    func cycleSpeed() {
        let all = PlaybackSpeed.allCases
        guard let index = all.firstIndex(of: speed) else { speed = .oneX; return }
        speed = all[(index + 1) % all.count]
    }

    // MARK: Download (UI only)

    var isCurrentEpisodeDownloaded: Bool {
        episode.map { downloadedEpisodeIds.contains($0.id) } ?? false
    }

    func toggleDownload() {
        guard let id = episode?.id else { return }
        if downloadedEpisodeIds.contains(id) {
            downloadedEpisodeIds.remove(id)
        } else {
            downloadedEpisodeIds.insert(id)
        }
    }

    // MARK: Feedback (Useful / Not quite)

    var currentRating: AnswerRating? {
        currentBlock.flatMap { ratings[$0.id] }
    }

    /// Useful chip — toggles.
    func toggleUseful() {
        guard let id = currentBlock?.id else { return }
        syncRating(ratings[id] == .up ? nil : .up, id: id)
    }

    /// Not quite chip — a second tap clears it; otherwise opens the shared
    /// feedback sheet (4.7).
    func tapNotQuite() {
        guard let id = currentBlock?.id else { return }
        if ratings[id] == .down {
            syncRating(nil, id: id)
        } else {
            isFeedbackSheetOpen = true
        }
    }

    /// Sheet "Send feedback": "Not quite" with the chosen reasons and text.
    func submitFeedback(options: [String], text: String) {
        if let id = currentBlock?.id {
            syncRating(.down, id: id, reasons: FeedbackMapping.codes(for: options), suggestion: text)
        }
        isFeedbackSheetOpen = false
    }

    /// Sheet "Report a problem": files the report (POST /feedback/report) and
    /// keeps the "Not quite" mark the chips showed before.
    func reportProblem() {
        if let id = currentBlock?.id {
            if let token, FeedbackMapping.isSendable(id) {
                let body = FeedbackReportBody(
                    targetType: FeedbackTarget.story.rawValue, targetId: id,
                    text: "Reported from the player: \(currentBlock?.summary ?? "story")"
                )
                Task { _ = try? await APIClient.shared.reportProblem(body, token: token) }
            }
            if ratings[id] != .down { syncRating(.down, id: id) }
        }
        isFeedbackSheetOpen = false
    }

    /// Optimistic: the chip flips immediately, the server call follows, and the
    /// previous state is restored if it fails. Clearing (`nil`) re-sends the
    /// stored payload, which the backend treats as "toggle off".
    private func syncRating(_ rating: AnswerRating?, id: String, reasons: [String] = [], suggestion: String? = nil) {
        let previous = ratings[id]
        let previousSaved = savedFeedback[id]
        ratings[id] = rating
        guard let token, FeedbackMapping.isSendable(id) else { return }

        let body: FeedbackBody
        if let rating {
            body = FeedbackBody(
                targetType: FeedbackTarget.story.rawValue, targetId: id,
                rating: rating == .up ? "useful" : "not_quite",
                reasons: reasons, suggestion: FeedbackMapping.suggestion(suggestion)
            )
        } else if let saved = previousSaved {
            body = FeedbackBody(
                targetType: FeedbackTarget.story.rawValue, targetId: id, rating: saved.rating,
                reasons: saved.reasons, suggestion: saved.suggestion
            )
        } else if let previous {
            body = FeedbackBody(
                targetType: FeedbackTarget.story.rawValue, targetId: id,
                rating: previous == .up ? "useful" : "not_quite", reasons: [], suggestion: nil
            )
        } else {
            return
        }
        Task {
            do {
                let result = try await APIClient.shared.submitFeedback(body, token: token)
                applyServerFeedback(result.removed ? nil : result.feedback, id: id)
            } catch {
                ratings[id] = previous
                savedFeedback[id] = previousSaved
            }
        }
    }

    private func applyServerFeedback(_ feedback: FeedbackOut?, id: String) {
        savedFeedback[id] = feedback.map { SavedFeedback(rating: $0.rating, reasons: $0.reasons, suggestion: $0.suggestion) }
        ratings[id] = feedback.map { $0.rating == "useful" ? AnswerRating.up : .down }
    }

    /// Loads the saved Useful / Not quite state of the loaded episode's stories.
    private func loadSavedFeedback() async {
        guard let token else { return }
        let ids = blocks.map(\.id).filter(FeedbackMapping.isSendable)
        guard !ids.isEmpty,
              let saved = try? await APIClient.shared.feedback(targetType: .story, targetIds: ids, token: token)
        else { return }
        for item in saved where ratings[item.targetId] == nil && savedFeedback[item.targetId] == nil {
            applyServerFeedback(item, id: item.targetId)
        }
    }

    /// Seeks within the current block — used by the transcript panel's "tap
    /// a line to seek" affordance. `fraction` is 0...1 of the block's
    /// duration; resolved to a real absolute `seek(to:)` on the engine.
    func seekWithinBlock(fraction: Double) {
        guard let block = currentBlock, currentBlockDurationS > 0 else { return }
        ensureAudioLoaded()
        guard audioService.currentItem != nil else { return }
        let target = Double(block.startS) + min(1, max(0, fraction)) * Double(currentBlockDurationS)
        audioService.seek(to: target)
    }

    /// Tapping the speed readout label itself resets to 1× (Pocket Casts'
    /// proven affordance per DESIGN_SPEC_V3.md's "Speed / tuning controls").
    func resetSpeedToOne() {
        speed = .oneX
    }

    /// Retries after a real playback error (network failure, stream
    /// failure, timeout) by tearing down the engine's stale item and
    /// reloading the current episode's audio from scratch.
    func retryPlayback() {
        audioService.stop()
        loadedEpisodeId = nil
        ensureAudioLoaded()
    }

    deinit {
        // AudioPlayerService's own deinit tears down its time observer /
        // notification registrations; nothing extra to clean up here now
        // that the fake Timer is gone.
    }
}
