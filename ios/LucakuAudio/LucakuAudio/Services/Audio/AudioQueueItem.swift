import Foundation

/// One playable unit for `AudioPlayerService` — today that's always a whole
/// episode (`backend/app/api/routes/generation.py`'s `EpisodeOut.audio_url`
/// is a single mp3 per episode: `episode_generator.py` synthesizes each
/// block's script separately via ElevenLabs but naively concatenates the
/// resulting mp3 bytes server-side before writing `{episode_id}.mp3`, so the
/// API never hands the app more than one URL per episode — see that file's
/// module docstring, "Naive mp3 concatenation").
///
/// The service is still built around a queue of these, not a single URL,
/// for two reasons: (1) the backend's own docstring flags per-block audio
/// files as a known-deferred improvement ("Real per-block timestamp
/// alignment... Naive mp3 concatenation"), so a future API revision handing
/// the app one URL per block is plausible and shouldn't require touching the
/// playback engine; and (2) a real playlist (queueing the next episode once
/// one finishes) is the more immediate use of the same mechanism. Advancing
/// between items with different remote URLs and metadata is exactly the
/// case `AudioPlayerService` is built to handle.
struct AudioQueueItem: Identifiable, Equatable {
    /// Stable identity for the item — an episode id or `"<episode>-block-<n>"`.
    let id: String
    /// Remote URL to stream from. Currently always a public, unauthenticated
    /// `{PUBLIC_BASE_URL}/media/{episode_id}.mp3` URL served by FastAPI's
    /// `StaticFiles` mount in `backend/app/main.py` (`app.mount("/media", ...)`)
    /// — that route has no `Depends(get_current_cliente)`, so no bearer token
    /// is needed to fetch the audio bytes themselves (only the metadata call
    /// that hands you this URL, `GET /generation/episodes/latest`, is
    /// authenticated). See `AudioPlayerService` for how that's wired.
    let url: URL
    /// Now Playing / lock-screen title, e.g. the episode headline.
    let title: String
    /// Now Playing subtitle, e.g. "Lucaku Audio" or the episode's date.
    let subtitle: String?
    /// Known duration in seconds, if the backend already told us
    /// (`EpisodeOut.duration_s`). Falls back to whatever `AVPlayerItem`
    /// reports once the asset loads if this is nil.
    let knownDuration: TimeInterval?

    init(id: String, url: URL, title: String, subtitle: String? = nil, knownDuration: TimeInterval? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.knownDuration = knownDuration
    }
}
