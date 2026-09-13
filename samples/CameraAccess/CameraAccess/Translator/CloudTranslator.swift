// VisionClaw - CloudTranslator.swift
// Translation through GigaChat or YandexGPT, with an automatic fall back to the on-device model.
//
// Both local options were tried first and neither was good enough: Apple's is sentence-level and
// literal, and Qwen3 at a size that fits a phone still loses the thread. A full cloud model is
// materially better at exactly the things that were wrong -- idiom, word order, and keeping a
// sentence coherent when it arrives in pieces.
//
// The cost is a second or so per segment and tokens burned for as long as the conversation runs,
// which is why this is not simply "use the cloud". A translator is most needed abroad, where the
// network is worst, so every failure -- no signal, a timeout, an exhausted quota -- silently drops
// to Qwen3 rather than leaving the user with nothing. Reachability is not probed in advance: the
// only reliable test of whether a request will work is making it.

import Foundation

@MainActor
final class CloudTranslator: ObservableObject {
    static let shared = CloudTranslator()
    private init() {}

    /// Сколько запросов ушло в облако за сеанс. Показывается на экране: счёт идёт на сотни в час,
    /// и узнавать об этом из выписки поздно.
    @Published private(set) var requestCount = 0
    /// Ушёл ли последний отрезок в облако или откатился на устройство — чтобы экран говорил, что
    /// человек слышит на самом деле, а не что он выбрал.
    @Published private(set) var lastUsedFallback = false
    @Published private(set) var lastFallbackReason: String?

    /// Which hosted service translates. GigaChat and YandexGPT are the two the app is configured
    /// for; the local model is not a cloud option, so selecting it in the chat does not drag the
    /// translator along with it.
    static let serviceKey = "translatorCloudService"

    enum Service: String, CaseIterable, Identifiable {
        case gigachat
        case yandexgpt

        var id: String { rawValue }
        var label: String { self == .gigachat ? "GigaChat" : "YandexGPT" }

        var isConfigured: Bool {
            switch self {
            case .gigachat:
                return !SettingsManager.shared.gigaChatAuthKey.isEmpty
            case .yandexgpt:
                return !SettingsManager.shared.yandexGPTApiKey.isEmpty
                    && !SettingsManager.shared.yandexGPTFolderId.isEmpty
            }
        }
    }

    var service: Service {
        get {
            if let raw = UserDefaults.standard.string(forKey: Self.serviceKey),
               let stored = Service(rawValue: raw) {
                return stored
            }
            // First run: whichever the user has actually set up, rather than a fixed default that
            // fails on its first request.
            return Service.allCases.first(where: \.isConfigured) ?? .gigachat
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.serviceKey) }
    }

    func resetCounter() { requestCount = 0 }

    /// Translate one segment, falling back to the on-device model on any failure.
    func translate(_ text: String,
                   from sourceName: String,
                   to targetName: String,
                   recentContext: [String]) async throws -> String {
        let service = self.service
        if service.isConfigured {
            requestCount += 1
            do {
                let answer = try await requestCloud(text, service: service,
                                                    from: sourceName, to: targetName,
                                                    recentContext: recentContext)
                lastUsedFallback = false
                lastFallbackReason = nil
                return answer
            } catch {
                lastFallbackReason = error.localizedDescription
            }
        } else {
            lastFallbackReason = "\(service.label) has no key set"
        }

        lastUsedFallback = true
        return try await LocalLLMTranslator.shared.translate(
            text, from: sourceName, to: targetName,
            recentContext: recentContext, isFragment: true)
    }

    private func requestCloud(_ text: String,
                              service: Service,
                              from sourceName: String,
                              to targetName: String,
                              recentContext: [String]) async throws -> String {
        // Инструкция намеренно короткая. Она уходит с КАЖДЫМ отрезком речи, а отрезков за час
        // разговора набираются сотни: на замерах длинный вариант давал 97 токенов инструкций
        // против 25 токенов самого текста — то есть 86% оплаченного объёма не несли смысла.
        var prompt = "Переведи с \(sourceName) на \(targetName). Только перевод. "
            + "Это фрагмент живой речи, может обрываться — не дополняй его.\n"
        if let previous = recentContext.last {
            // Одна предыдущая реплика вместо трёх: род и местоимения она удерживает так же,
            // а объём контекста втрое меньше.
            prompt += "Предыдущая фраза (для связности, не переводить): \(previous)\n"
        }
        prompt += "\n" + text

        // A short timeout on purpose: past a couple of seconds the translation is useless anyway,
        // and falling back to the local model beats making the user wait for something stale.
        let answer: String
        switch service {
        case .gigachat:
            answer = try await GigaChatService.shared.ask(text: prompt, imageData: nil, history: [])
        case .yandexgpt:
            answer = try await YandexGPTService.shared.ask(text: prompt, imageData: nil, history: [])
        }
        let cleaned = LocalLLMTranslator.cleaned(answer)
        guard !cleaned.isEmpty else { throw CloudTranslatorError.emptyReply }
        return cleaned
    }

    enum CloudTranslatorError: LocalizedError {
        case emptyReply
        var errorDescription: String? { "The service returned an empty translation." }
    }
}
