import AVFoundation
import Foundation
import Speech

/// Voice for Onboarding: reads a prompt aloud (`AVSpeechSynthesizer`) and
/// turns a spoken answer into text, on-device (`SFSpeechRecognizer` +
/// `AVAudioEngine`). Nothing here is the Generator's ElevenLabs voice — this
/// is the system's own local TTS/STT, appropriate for reading UI prompts and
/// dictating a free-text answer, not for the customer's daily episode.
///
/// Requires `NSMicrophoneUsageDescription` and
/// `NSSpeechRecognitionUsageDescription` in Info.plist (added alongside this
/// file) or both permission requests below silently deny.
@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isListening = false
    /// Live partial (then final) transcript while `isListening` — a caller
    /// binds a text field to this, or reads it once listening stops.
    @Published var transcript = ""

    private let synthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Speak

    /// `languageCode` is a BCP-47 tag ("es-MX", "en-US") — see
    /// `LucakuLocale.speechLanguage(for:)` for how a request's `Cliente.idioma`
    /// ("es"/"en") maps to one.
    func speak(_ text: String, languageCode: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        stopListening() // never speak and listen at the same time
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: languageCode) ?? AVSpeechSynthesisVoice(language: "en-US")
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        guard isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - Listen

    /// Starts on-device dictation into `transcript`, updated live as the
    /// recognizer produces partial results. Throws `SpeechServiceError` if
    /// mic/speech-recognition permission is denied or no recognizer exists
    /// for `languageCode` — callers show `error.localizedDescription` rather
    /// than fail silently (a customer who can't be heard needs to know, not
    /// just fall back to a blank field).
    func startListening(languageCode: String) async throws {
        stopSpeaking()

        guard await requestSpeechAuthorization() == .authorized else {
            throw SpeechServiceError.notAuthorized
        }
        guard await requestMicrophonePermission() else {
            throw SpeechServiceError.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageCode)), recognizer.isAvailable else {
            throw SpeechServiceError.recognizerUnavailable
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        // Captures the local `request`, never `self` — this tap fires on a
        // real-time audio thread, not the main actor `self` is isolated to;
        // Apple's own sample code uses exactly this "capture the local
        // request" shape for that reason.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        transcript = ""
        isListening = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // `[weak self]` captured fresh on this Task, not carried in from
            // the outer completion handler — see AudioPlayerService.swift's
            // observe(playerItem:) for why that distinction matters under
            // Swift 6 strict concurrency (a weak ref captured only in a
            // non-isolated outer closure can't safely cross into a
            // `@MainActor` Task).
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.stopListening()
                }
            }
        }
    }

    func stopListening() {
        guard isListening else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Permissions

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// `AVAudioSession.requestRecordPermission` (not the newer
    /// `AVAudioApplication` API) — deprecated in iOS 17 but stable and
    /// well-documented back to iOS 8, and this only needs a yes/no answer.
    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

enum SpeechServiceError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Lucaku needs microphone and speech access to hear you — enable it in Settings, or type instead."
        case .recognizerUnavailable:
            return "Speech recognition isn't available right now — try typing instead."
        }
    }
}

/// Maps `Cliente.idioma` ("es" | "en") to a real BCP-47 speech tag. A plain
/// "es"/"en" ISO code isn't specific enough for `AVSpeechSynthesisVoice`/
/// `SFSpeechRecognizer`, which expect a region (`AVSpeechSynthesisVoice
/// .speechVoices()` lists concrete tags like "es-MX", never bare "es").
/// "es-MX" over "es-ES": the seed content and product tone target Latin
/// American Spanish (see backend/app/data/onboarding_seeds.json).
enum LucakuLocale {
    static func speechLanguage(forIdioma idioma: String) -> String {
        idioma == "es" ? "es-MX" : "en-US"
    }
}
