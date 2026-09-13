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

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Loudest sample seen this session. Distinguishes "recognizer heard nothing useful" from
    /// "the microphone handed us pure silence", which have completely different fixes.
    private var peakLevel: Float = 0
    private var sawAnyResult = false

    /// A recognizer for the device's own language, falling back to Russian and then English.
    /// `SFSpeechRecognizer()` uses the current locale implicitly and returns nil when that locale
    /// has no speech support at all — which surfaced as a bare "isn't available right now".
    private static func makeRecognizer() -> SFSpeechRecognizer? {
        var candidates: [Locale] = [Locale.current]
        if let code = Locale.current.language.languageCode?.identifier, code == "ru" {
            candidates.append(Locale(identifier: "ru-RU"))
        }
        candidates.append(Locale(identifier: "ru-RU"))
        candidates.append(Locale(identifier: "en-US"))
        for locale in candidates {
            if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable {
                return recognizer
            }
        }
        return SFSpeechRecognizer()
    }

    /// Starts listening. Throws if speech recognition or microphone permission is denied, or the
    /// recognizer isn't available (e.g. no network, on a locale requiring one).
    func start() async throws {
        guard !isListening else { return }
        lastError = nil
        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else { throw SpeechError.notAuthorized }
        guard await requestMicrophoneAuthorization() else { throw SpeechError.notAuthorized }
        guard let recognizer = Self.makeRecognizer(), recognizer.isAvailable else {
            throw SpeechError.unavailable
        }

        transcript = ""
        peakLevel = 0
        sawAnyResult = false

        let session = AVAudioSession.sharedInstance()
        // No .allowBluetooth: with the Meta glasses (or any HFP headset) paired, that flag makes
        // iOS route capture to the headset's mic, so speaking into the phone recorded silence —
        // on a glasses app that is the normal state, not the edge case. Output still reaches a
        // Bluetooth speaker via .allowBluetoothA2DP; only capture is pinned to the phone.
        // Mode stays .default rather than .measurement so iOS keeps its input gain/noise
        // processing, which dictation depends on.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
        inputRouteName = session.currentRoute.inputs.first?.portName

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer on-device dictation wherever the language pack allows it: it needs no round trip
        // to Apple's speech servers, which is both faster and the difference between working and
        // not on a network where those servers are slow or unreachable. `supportsOnDeviceRecognition`
        // is false unless the assets are actually installed, so this never silently degrades.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = audioEngine.inputNode
        // inputFormat, not outputFormat: the output format of the input node can come back with a
        // zero sample rate before the route settles, and installTap raises on such a format.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw SpeechError.noInput(route: inputRouteName)
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            guard let channel = buffer.floatChannelData?[0] else { return }
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channel[i]))
            }
            Task { @MainActor in self?.peakLevel = max(self?.peakLevel ?? 0, peak) }
        }
        audioEngine.prepare()
        try audioEngine.start()
        isListening = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in
                    self.sawAnyResult = true
                    self.transcript = result.bestTranscription.formattedString
                }
            }
            if let error {
                Task { @MainActor in self.finish(error: error) }
            } else if result?.isFinal == true {
                Task { @MainActor in self.finish(error: nil) }
            }
        }
    }

    /// Stops listening and finalizes whatever was heard so far in `transcript`.
    func stop() {
        finish(error: nil)
    }

    /// Tears the session down and, when nothing was transcribed, explains which of the three
    /// distinct failures happened instead of leaving an empty field.
    private func finish(error: Error?) {
        guard isListening else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

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
        case unavailable
        case noInput(route: String?)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech recognition needs microphone and speech-recognition permission — allow both in Settings."
            case .unavailable:
                return "Speech recognition isn't available for this language on this device."
            case .noInput(let route):
                return "No usable microphone input\(route.map { " (route: \($0))" } ?? "")."
            }
        }
    }
}
