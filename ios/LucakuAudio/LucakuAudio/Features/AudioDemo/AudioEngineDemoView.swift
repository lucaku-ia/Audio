import SwiftUI

/// Standalone debug view for manually verifying `AudioPlayerService` against
/// the real, live backend — NOT wired into the app's real navigation
/// (`ContentView`/`HomeView`/tab bar are untouched). This exists purely to
/// prove real audio streams and plays: it logs in against the deployed
/// Railway backend (or reuses a token already in the Keychain from a normal
/// login), fetches the signed-in customer's latest real episode via
/// `GET /generation/episodes/latest`, and hands its real `audio_url` to
/// `AudioPlayerService` for actual `AVPlayer` playback with real
/// play/pause/seek/speed controls.
///
/// To try it: temporarily point `ContentView`'s body at
/// `AudioEngineDemoView()` (or push it from anywhere) while testing, then
/// revert — this file intentionally isn't referenced from the real nav graph
/// so it can't collide with the in-flight Player screen work.
struct AudioEngineDemoView: View {
    @StateObject private var player = AudioPlayerService()

    @State private var email = ""
    @State private var password = ""
    @State private var manualToken = KeychainHelper.read(key: "com.lucaku.audio.accessToken")
        ?? ProcessInfo.processInfo.environment["LUCAKU_DEBUG_TOKEN"] ?? ""
    @State private var episode: EpisodeOut?
    @State private var statusText = "Not loaded"
    @State private var isBusy = false

    private let rates: [Float] = [1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        NavigationStack {
            Form {
                Section("Auth") {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                    SecureField("Password", text: $password)
                    Button("Log in") { Task { await login() } }
                        .disabled(isBusy || email.isEmpty || password.isEmpty)

                    TextField("Or paste a bearer token", text: $manualToken)
                        .textInputAutocapitalization(.never)
                        .font(.caption)
                }

                Section("Episode") {
                    Button("Fetch latest episode") { Task { await fetchEpisode() } }
                        .disabled(isBusy || manualToken.isEmpty)
                    if let episode {
                        Text(episode.headline ?? "(no headline)")
                            .font(.headline)
                        if let url = episode.audioUrl {
                            Text(url).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("This episode has no audio_url yet (voicing was skipped or not configured server-side).")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Text(statusText).font(.footnote).foregroundStyle(.secondary)
                }

                Section("Playback") {
                    Button("Load & Play real audio") { loadAndPlay() }
                        .disabled(episode?.audioUrl == nil)

                    HStack {
                        Text(playbackStateLabel)
                        Spacer()
                        Text(timeLabel).monospacedDigit()
                    }

                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...(max(player.duration, 1))
                    )

                    HStack(spacing: 24) {
                        Button { player.skipBackward(by: 15) } label: {
                            Image(systemName: "gobackward.15")
                        }
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 40))
                        }
                        Button { player.skipForward(by: 15) } label: {
                            Image(systemName: "goforward.15")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.plain)

                    Picker("Speed", selection: Binding(
                        get: { player.playbackRate },
                        set: { player.setRate($0) }
                    )) {
                        ForEach(rates, id: \.self) { rate in
                            Text("\(rate.formatted())x").tag(rate)
                        }
                    }
                    .pickerStyle(.segmented)

                    if case .failed(let error) = player.state {
                        Text(error.localizedDescription)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Audio Engine Demo")
            .task {
                // Manual-verification convenience: if launched with
                // LUCAKU_DEBUG_TOKEN and LUCAKU_DEBUG_AUTOPLAY=1 in the
                // environment (e.g. `xcrun simctl launch --console-pty` with
                // SIMCTL_CHILD_ vars), automatically fetch and play the
                // signed-in customer's latest real episode — avoids relying
                // on fragile simulator UI taps just to prove the engine
                // streams and plays real audio end to end.
                guard ProcessInfo.processInfo.environment["LUCAKU_DEBUG_AUTOPLAY"] == "1", !manualToken.isEmpty else { return }
                await fetchEpisode()
                loadAndPlay()
            }
        }
    }

    private var playbackStateLabel: String {
        switch player.state {
        case .idle: return "Idle"
        case .loading: return "Loading…"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .buffering: return "Buffering…"
        case .finished: return "Finished"
        case .failed: return "Failed"
        }
    }

    private var timeLabel: String {
        "\(formatted(player.currentTime)) / \(formatted(player.duration))"
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func login() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let token = try await APIClient.shared.login(email: email, password: password)
            manualToken = token.accessToken
            statusText = "Logged in."
        } catch {
            statusText = "Login failed: \(error.localizedDescription)"
        }
    }

    private func fetchEpisode() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await APIClient.shared.latestEpisode(token: manualToken)
            episode = result
            statusText = "Fetched episode \(result.id)."
        } catch {
            statusText = "Fetch failed: \(error.localizedDescription)"
        }
    }

    private func loadAndPlay() {
        guard let episode, let urlString = episode.audioUrl, let url = URL(string: urlString) else { return }
        player.play(
            url: url,
            title: episode.headline ?? "Lucaku Episode",
            subtitle: episode.fecha,
            knownDuration: episode.durationS.map(TimeInterval.init)
        )
    }
}

#Preview {
    AudioEngineDemoView()
}
