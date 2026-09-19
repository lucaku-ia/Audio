import AVFoundation
import Foundation
import MediaPlayer

/// Real streaming audio playback for Lucaku episodes, built on `AVPlayer` —
/// no third-party audio library. Wraps a single `AVPlayer` (not
/// `AVQueuePlayer`): advancing between queue items is done manually by
/// swapping `AVPlayerItem`s on `.AVPlayerItemDidPlayToEndTime`, because each
/// item in a Lucaku queue carries its own Now Playing metadata (title,
/// duration) that needs to update the instant playback moves to the next
/// item — `AVQueuePlayer` still requires observing `currentItem` changes to
/// do that, so a plain `AVPlayer` with explicit item-ended handling ends up
/// simpler and is easier to reason about when an item fails to load (no
/// silent skip-ahead behavior to fight).
///
/// ## What this talks to, for real
/// `EpisodeOut.audio_url` (see `backend/app/api/routes/generation.py`) is a
/// direct link to an mp3 file: `episode_generator.py` synthesizes each
/// block's script via ElevenLabs (`ai_platform.synthesize`, real
/// `audio/mpeg` bytes) and writes the whole episode's concatenated audio to
/// `{MEDIA_DIR}/{episode_id}.mp3`, which `app.main` serves back out via a
/// plain `StaticFiles` mount at `/media` — **no auth dependency on that
/// route**. So `audio_url` (`"{PUBLIC_BASE_URL}/media/{episode_id}.mp3"`) is
/// fetchable with a bare `AVPlayer(url:)`; only the API call that *hands you*
/// that URL (`GET /generation/episodes/latest`) needs the bearer token, via
/// `APIClient`. `authHeaderProvider` below exists for defense-in-depth in
/// case a future revision moves audio behind auth (per the backend's own
/// "naive mp3 concatenation" / deferred-work notes suggesting the storage
/// story may change) — it is not exercised against the current backend.
@MainActor
final class AudioPlayerService: NSObject, ObservableObject {

    // MARK: - Public state

    enum PlaybackState: Equatable {
        case idle
        case loading
        case playing
        case paused
        /// Buffering after having already started — distinct from `.loading`
        /// (first load) so the UI can show a subtler indicator mid-playback.
        case buffering
        case failed(AudioPlayerError)
        /// The whole queue finished; nothing left to advance to.
        case finished
    }

    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackRate: Float = 1.0
    @Published private(set) var currentItem: AudioQueueItem?
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var queueCount: Int = 0

    var isPlaying: Bool { state == .playing }
    var hasNext: Bool { currentIndex + 1 < queue.count }
    var hasPrevious: Bool { currentIndex > 0 }

    /// Optional hook for injecting an `Authorization` header on the asset
    /// request, if a future backend revision requires one to fetch audio
    /// bytes (see the type doc). Returning nil means "no header."
    var authHeaderProvider: (() -> String?)?

    // MARK: - Internals

    private let player = AVPlayer()
    private var queue: [AudioQueueItem] = []
    private var timeObserverToken: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var loadingTimeoutTask: Task<Void, Never>?

    /// How long to wait for an item to reach `.readyToPlay` before treating
    /// it as a network failure (a stalled/unreachable stream would otherwise
    /// hang forever with no signal to the user).
    private let loadTimeout: TimeInterval = 20

    override init() {
        super.init()
        configureAudioSession()
        configureRemoteCommandCenter()
        observePlayerTimeControlStatus()
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    /// Starts (or restarts) playback of a whole queue, beginning at `startIndex`.
    func play(queue newQueue: [AudioQueueItem], startIndex: Int = 0) {
        guard !newQueue.isEmpty, newQueue.indices.contains(startIndex) else {
            state = .failed(.invalidQueue)
            return
        }
        queue = newQueue
        queueCount = newQueue.count
        loadItem(at: startIndex, autoplay: true)
    }

    /// Convenience for a single URL with no queue semantics.
    func play(url: URL, title: String, subtitle: String? = nil, knownDuration: TimeInterval? = nil) {
        play(queue: [AudioQueueItem(id: url.absoluteString, url: url, title: title, subtitle: subtitle, knownDuration: knownDuration)])
    }

    func pause() {
        player.pause()
        state = .paused
        updateNowPlayingInfo()
    }

    func resume() {
        guard currentItem != nil else { return }
        player.play()
        player.rate = playbackRate
        state = .playing
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration > 0 ? duration : time))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.updateNowPlayingInfo()
        }
        currentTime = clamped
    }

    func skipForward(by seconds: TimeInterval = 15) {
        seek(to: currentTime + seconds)
    }

    func skipBackward(by seconds: TimeInterval = 15) {
        seek(to: currentTime - seconds)
    }

    /// Sets playback speed, e.g. for the transport's 1x/1.25x/1.5x/1.75x/2x control.
    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player.rate = rate
        }
        updateNowPlayingInfo()
    }

    func advanceToNext() {
        guard hasNext else {
            player.pause()
            state = .finished
            return
        }
        loadItem(at: currentIndex + 1, autoplay: true)
    }

    func advanceToPrevious() {
        guard hasPrevious else { return }
        loadItem(at: currentIndex - 1, autoplay: true)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        cleanUpItemObservers()
        state = .idle
        currentTime = 0
        duration = 0
        currentItem = nil
        queue = []
        queueCount = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Item loading

    private func loadItem(at index: Int, autoplay: Bool) {
        cleanUpItemObservers()
        loadingTimeoutTask?.cancel()

        currentIndex = index
        let item = queue[index]
        currentItem = item
        state = .loading
        currentTime = 0
        duration = item.knownDuration ?? 0

        var options: [String: Any] = [:]
        if let header = authHeaderProvider?() {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": header]
        }
        let asset = AVURLAsset(url: item.url, options: options.isEmpty ? nil : options)
        let playerItem = AVPlayerItem(asset: asset)

        observe(playerItem: playerItem)
        player.replaceCurrentItem(with: playerItem)
        playbackRate = playbackRate == 0 ? 1.0 : playbackRate

        if autoplay {
            // AVPlayer.play() before .readyToPlay is safe — it starts as
            // soon as the item becomes ready; we still track state via KVO
            // below rather than assuming success here.
            player.play()
            player.rate = playbackRate
        }

        loadingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.loadTimeout ?? 20) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if case .loading = self.state {
                self.fail(.timedOut)
            }
        }
    }

    private func observe(playerItem: AVPlayerItem) {
        // `[weak self]` is captured again on each inner `Task`, not just the
        // outer KVO closure: the outer closure isn't MainActor-isolated (KVO
        // fires on an arbitrary queue), so a `self` weakified only in that
        // outer scope is a non-Sendable capture across the `Task`'s
        // concurrency boundary — Swift 6 strict concurrency rejects that as
        // "reference to captured var 'self' in concurrently-executing code".
        // Re-capturing `[weak self]` directly on the `Task` avoids it.
        itemStatusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handleStatusChange(item: item)
            }
        }
        bufferEmptyObservation = playerItem.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, case .playing = self.state else { return }
                if item.isPlaybackBufferEmpty {
                    self.state = .buffering
                }
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleItemDidFinish(_:)),
            name: .AVPlayerItemDidPlayToEndTime, object: playerItem
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleItemFailedToFinish(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime, object: playerItem
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePlaybackStalled(_:)),
            name: .AVPlayerItemPlaybackStalled, object: playerItem
        )

        addPeriodicTimeObserverIfNeeded()
    }

    private func handleStatusChange(item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            loadingTimeoutTask?.cancel()
            let itemDuration = item.duration.seconds
            if itemDuration.isFinite, itemDuration > 0 {
                duration = itemDuration
            }
            if state == .loading || state == .buffering {
                state = player.rate > 0 ? .playing : .paused
            }
            updateNowPlayingInfo()
        case .failed:
            let underlying = item.error
            fail(.streamFailed(underlying?.localizedDescription ?? "Unknown playback error"))
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func addPeriodicTimeObserverIfNeeded() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if case .buffering = self.state, self.player.rate > 0 {
                self.state = .playing
            }
        }
    }

    private func cleanUpItemObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil
        if let item = player.currentItem {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: item)
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: item)
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemPlaybackStalled, object: item)
        }
        loadingTimeoutTask?.cancel()
    }

    private func fail(_ error: AudioPlayerError) {
        loadingTimeoutTask?.cancel()
        player.pause()
        state = .failed(error)
    }

    @objc private func handleItemDidFinish(_ notification: Notification) {
        Task { @MainActor in
            self.advanceToNext()
        }
    }

    @objc private func handleItemFailedToFinish(_ notification: Notification) {
        let underlying = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
        Task { @MainActor in
            self.fail(.streamFailed(underlying ?? "Playback stopped unexpectedly"))
        }
    }

    @objc private func handlePlaybackStalled(_ notification: Notification) {
        Task { @MainActor in
            guard case .playing = self.state else { return }
            self.state = .buffering
        }
    }

    private func observePlayerTimeControlStatus() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch player.timeControlStatus {
                case .paused:
                    if case .failed = self.state { return }
                    if case .finished = self.state { return }
                    if case .loading = self.state { return }
                    self.state = .paused
                case .waitingToPlayAtSpecifiedRate:
                    if case .loading = self.state { return }
                    self.state = .buffering
                case .playing:
                    self.state = .playing
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Audio session / background playback

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            // Non-fatal: playback can still work foregrounded even if the
            // session couldn't be configured (e.g. running in a simulator
            // or sharing audio with another app); surface via state so a
            // real device issue isn't silently swallowed.
            state = .failed(.audioSessionUnavailable(error.localizedDescription))
        }
    }

    // MARK: - Remote command center (lock screen / control center)

    private func configureRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.hasNext else { return .noActionableNowPlayingItem }
            self.advanceToNext()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.hasPrevious else { return .noActionableNowPlayingItem }
            self.advanceToPrevious()
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.skipForward(by: 15)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skipBackward(by: 15)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let item = currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let subtitle = item.subtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

/// Real, surfaced error states — never a silent hang or a crash.
enum AudioPlayerError: Error, Equatable, LocalizedError {
    case invalidQueue
    case streamFailed(String)
    case timedOut
    case audioSessionUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidQueue:
            return "Nothing to play."
        case .streamFailed(let message):
            return "Playback failed: \(message)"
        case .timedOut:
            return "Couldn't load audio in time. Check your connection and try again."
        case .audioSessionUnavailable(let message):
            return "Audio session error: \(message)"
        }
    }
}
