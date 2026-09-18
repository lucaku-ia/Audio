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
    @Published var clearerVoiceEnabled: Bool = true
    @Published var skipSilenceEnabled: Bool = false

    @Published var isNowPlayingExpanded: Bool = false
    @Published var isTuningSheetOpen: Bool = false
    @Published var rating: AnswerRating?

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
        isTuningSheetOpen = false
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
