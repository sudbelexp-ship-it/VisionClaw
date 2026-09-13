// VisionClaw - SpeechRecognizerOneShot.swift
// One-shot speech-to-text for the "ask" screen's mic button: tap to start listening, tap again
// (or pause) to stop and get the transcript back. Not a continuous/wake-word listener — VisionClaw
// has no such loop (Gemini Live/OpenAI Realtime do their own listening server-side); this exists
// only for the direct backends (GigaChat/YandexGPT/local FastVLM), which take a single question
// per tap rather than an open call.

import AVFoundation
import Speech

@MainActor
final class SpeechRecognizerOneShot: ObservableObject {
    static let shared = SpeechRecognizerOneShot()
    private init() {}

    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    /// Why the last listening attempt produced nothing. The first version swallowed every error
    /// from the recognition task, so a mic that recorded silence, a locale with no speech assets,
    /// and Apple's speech servers being unreachable all looked identical: a red mic button and an
    /// empty text field, with nothing to act on.
    @Published private(set) var lastError: String?
    /// Which microphone iOS actually picked ("iPhone Microphone", "Ray-Ban Meta", …). Surfaced in
    /// the no-audio message because on a glasses app the input route is very often the surprise.
    @Published private(set) var inputRouteName: String?

    private var listener: AudioCaptureHub.Listener?
    /// Loudest sample seen this session. Distinguishes "recognizer heard nothing useful" from
    /// "the microphone handed us pure silence", which have completely different fixes.
    private var peakLevel: Float = 0
    private var sawAnyResult = false

    /// The language dictation should listen for: an explicit choice in Settings, otherwise the
    /// phone's own first preferred language.
    ///
    /// Deliberately NOT `Locale.current`. That returns the locale the *app* resolved to, which is
    /// bounded by the localizations the app ships — and this app ships English only. On a Russian
    /// phone it therefore reports en-US, so the recognizer happily listened in English and wrote
    /// Russian speech out as English-looking words ("Lenient robot microphone is in yet").
    /// `Locale.preferredLanguages` is the device's own list and is unaffected by that.
    static func activeLocale() -> Locale {
        let saved = SettingsManager.shared.speechLocaleIdentifier
        if !saved.isEmpty { return Locale(identifier: saved) }
        if let preferred = Locale.preferredLanguages.first {
            return Locale(identifier: preferred)
        }
        return Locale.current
    }

    /// Starts listening. Throws if permission is denied or the chosen language has no recogniser.
    func start() async throws {
        guard !isListening else { return }
        lastError = nil
        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else { throw SpeechError.notAuthorized }
        guard await requestMicrophoneAuthorization() else { throw SpeechError.notAuthorized }

        transcript = ""
        peakLevel = 0
        sawAnyResult = false

        // Through the shared hub rather than a private AVAudioEngine: iOS gives an app one input,
        // and the hands-free assistant may already be holding it. Two engines meant whichever
        // started second silently recorded nothing.
        do {
            listener = try AudioCaptureHub.shared.addListener(
                locale: Self.activeLocale(),
                onTranscript: { [weak self] text, isFinal in
                    guard let self else { return }
                    if !text.isEmpty {
                        self.sawAnyResult = true
                        self.transcript = text
                    }
                    if isFinal { self.finish(error: nil) }
                },
                onLevel: { [weak self] rms, _ in
                    self?.peakLevel = max(self?.peakLevel ?? 0, rms)
                })
        } catch {
            throw SpeechError.unavailable(language: Self.activeLocale().identifier)
        }
        inputRouteName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
        isListening = true
    }

    /// Stops listening and finalizes whatever was heard so far in `transcript`.
    func stop() {
        finish(error: nil)
    }

    /// Tears the session down and, when nothing was transcribed, explains which of the distinct
    /// failures happened instead of leaving an empty field.
    private func finish(error: Error?) {
        guard isListening else { return }
        AudioCaptureHub.shared.removeListener(listener)
        listener = nil
        isListening = false

        if transcript.isEmpty {
            if peakLevel < 0.005 {
                lastError = "The microphone recorded silence (input: \(inputRouteName ?? "unknown")). "
                    + "If your glasses or a headset are connected, they may be holding the mic."
            } else if let error {
                let ns = error as NSError
                lastError = "Speech recognition failed: \(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
            } else if !sawAnyResult {
                lastError = "Didn't catch any words. Try speaking a little longer before stopping."
            }
        }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    enum SpeechError: LocalizedError {
        case notAuthorized
        case unavailable(language: String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech recognition needs microphone and speech-recognition permission — allow both in Settings."
            case .unavailable(let language):
                return "Dictation isn't available for \(language) on this phone. "
                    + "Pick another language under Settings → Voice input."
            }
        }
    }
}
