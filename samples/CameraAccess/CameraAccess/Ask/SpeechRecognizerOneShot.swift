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

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Starts listening. Throws if speech recognition or microphone permission is denied, or the
    /// recognizer isn't available (e.g. no network, on a locale requiring one).
    func start() async throws {
        guard !isListening else { return }
        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else { throw SpeechError.notAuthorized }
        guard await requestMicrophoneAuthorization() else { throw SpeechError.notAuthorized }
        guard let recognizer, recognizer.isAvailable else { throw SpeechError.unavailable }

        transcript = ""
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
        isListening = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in self.transcript = result.bestTranscription.formattedString }
            }
            if error != nil || result?.isFinal == true {
                Task { @MainActor in self.stop() }
            }
        }
    }

    /// Stops listening and finalizes whatever was heard so far in `transcript`.
    func stop() {
        guard isListening else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech recognition needs microphone and speech-recognition permission — allow both in Settings."
            case .unavailable:
                return "Speech recognition isn't available right now."
            }
        }
    }
}
