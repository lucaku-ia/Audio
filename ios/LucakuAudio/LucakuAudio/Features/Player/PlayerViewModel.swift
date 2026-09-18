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
/// PLAYBACK ENGINE STATUS — READ BEFORE WIRING REAL AUDIO:
/// This scaffold has no AVFoundation/AVPlayer anywhere (confirmed by
/// searching the whole `ios/` tree). So the transport here (play/pause,
/// elapsed time, skip block) is UI STATE ONLY, advanced by a local `Timer`
/// while `isPlaying` is true — it does not decode or play any audio. This
/// intentionally matches the task scope ("actual audio playback engine is
/// out of scope for this pass unless the scaffold already has one wired").
/// To make this real: swap the `Timer`-driven `elapsedInBlockS` for an
/// `AVPlayer` observing `episode.audioUrl`, seeking to `block.startS` on
/// block change, and mirroring `currentTime`/`rate` instead of simulating
/// them.
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

    @Published var currentBlockIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published private(set) var elapsedInBlockS: Double = 0

    @Published var speed: PlaybackSpeed = .oneX
    @Published var clearerVoiceEnabled: Bool = true
    @Published var skipSilenceEnabled: Bool = false

    @Published var isNowPlayingExpanded: Bool = false
    @Published var isTuningSheetOpen: Bool = false
    @Published var rating: AnswerRating?

    private var timer: Timer?

    // MARK: Derived

    var blocks: [BlockOut] { episode?.blocks ?? [] }
    var hasEpisode: Bool { episode != nil && !blocks.isEmpty }

    var currentBlock: BlockOut? {
        blocks.indices.contains(currentBlockIndex) ? blocks[currentBlockIndex] : nil
    }

    var currentBlockDurationS: Int {
        guard let block = currentBlock else { return 0 }
        return max(0, block.endS - block.startS)
    }

    var currentBlockProgressFraction: Double {
        let duration = Double(currentBlockDurationS)
        guard duration > 0 else { return 0 }
        return min(1, elapsedInBlockS / duration)
    }

    var isCaughtUp: Bool {
        if case .loaded = loadState {
            return blocks.isEmpty
        }
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
            self.episode = episode
            currentBlockIndex = 0
            elapsedInBlockS = 0
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

    // MARK: Transport (UI-only — see class doc)

    /// Selects a block as "now playing." Mirrors tapping any row in the
    /// block list per DESIGN_SPEC_V3.md's "block list, not a timeline"
    /// pattern — never a scrub-bar seek.
    func selectBlock(_ index: Int, autoplay: Bool = true) {
        guard blocks.indices.contains(index) else { return }
        currentBlockIndex = index
        elapsedInBlockS = 0
        isPlaying = autoplay
        autoplay ? startTimer() : stopTimer()
    }

    func togglePlay() {
        guard hasEpisode else { return }
        isPlaying.toggle()
        isPlaying ? startTimer() : stopTimer()
    }

    func skipToNextBlock() {
        guard currentBlockIndex + 1 < blocks.count else { return }
        selectBlock(currentBlockIndex + 1, autoplay: isPlaying)
    }

    func skipToPreviousBlock() {
        guard currentBlockIndex > 0 else { return }
        selectBlock(currentBlockIndex - 1, autoplay: isPlaying)
    }

    func expandNowPlaying() {
        guard hasEpisode else { return }
        isNowPlayingExpanded = true
    }

    func collapseNowPlaying() {
        isNowPlayingExpanded = false
        isTuningSheetOpen = false
    }

    /// Seeks within the current block's (simulated) elapsed time — used by
    /// the transcript panel's "tap a line to seek" affordance. `fraction`
    /// is 0...1 of the block's duration.
    func seekWithinBlock(fraction: Double) {
        guard currentBlockDurationS > 0 else { return }
        elapsedInBlockS = min(Double(currentBlockDurationS), max(0, fraction) * Double(currentBlockDurationS))
    }

    /// Tapping the speed readout label itself resets to 1× (Pocket Casts'
    /// proven affordance per DESIGN_SPEC_V3.md's "Speed / tuning controls").
    func resetSpeedToOne() {
        speed = .oneX
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isPlaying, currentBlockDurationS > 0 else { return }
        elapsedInBlockS += 0.5 * speed.rawValue
        if elapsedInBlockS >= Double(currentBlockDurationS) {
            if currentBlockIndex + 1 < blocks.count {
                selectBlock(currentBlockIndex + 1, autoplay: true)
            } else {
                elapsedInBlockS = Double(currentBlockDurationS)
                isPlaying = false
                stopTimer()
            }
        }
    }

    deinit {
        timer?.invalidate()
    }
}
