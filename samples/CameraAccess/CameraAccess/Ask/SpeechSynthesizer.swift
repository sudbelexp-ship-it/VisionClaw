// VisionClaw - SpeechSynthesizer.swift
// Speaks a direct backend's reply aloud on the "ask" screen. Plain AVSpeechSynthesizer — no
// on-device neural TTS (Kokoro) here, unlike OpenVision; that's a heavier addition this port
// didn't ask for, and the system voice is a reasonable default for a one-shot reply.

import AVFoundation

@MainActor
final class SpeechSynthesizer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechSynthesizer()

    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        // Prefer a Russian voice when the reply is Russian (GigaChat/YandexGPT default to
        // Russian); AVSpeechSynthesisVoice picks the best match for the given BCP-47 code, or
        // falls back to the device's default voice if that locale isn't installed.
        utterance.voice = AVSpeechSynthesisVoice(language: detectedLanguageCode(for: text))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func detectedLanguageCode(for text: String) -> String {
        let hasCyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        return hasCyrillic ? "ru-RU" : "en-US"
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
