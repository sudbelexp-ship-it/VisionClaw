// VisionClaw - SpeechSynthesizer.swift
// Speaks a direct backend's reply aloud on the "ask" screen. Plain AVSpeechSynthesizer — no
// on-device neural TTS (Kokoro) here, unlike OpenVision; that's a heavier addition this port
// didn't ask for, and the system voice is a reasonable default for a one-shot reply.

import AVFoundation

@MainActor
final class SpeechSynthesizer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechSynthesizer()

    @Published private(set) var isSpeaking = false

    /// Множитель скорости, 0.5x…2x. Хранится здесь, а не передаётся в каждый вызов: его меняют
    /// ползунком во время разговора, и все, кто говорит, должны подхватывать новое значение сами.
    ///
    /// Уже произносимая фраза не ускоряется — AVSpeechSynthesizer не меняет темп на лету. В
    /// переводчике и у гида фразы короткие, поэтому новое значение слышно почти сразу.
    static let rateKey = "speechRateMultiplier"

    @Published var rateMultiplier: Double {
        didSet { UserDefaults.standard.set(rateMultiplier, forKey: Self.rateKey) }
    }

    /// Значение для AVSpeechUtterance: базовый темп, умноженный на выбранное, в допустимых пределах.
    var utteranceRate: Float {
        let raw = AVSpeechUtteranceDefaultSpeechRate * Float(rateMultiplier)
        return min(max(raw, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        let stored = UserDefaults.standard.double(forKey: Self.rateKey)
        rateMultiplier = stored > 0 ? stored : 1.0
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
        utterance.rate = utteranceRate
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
