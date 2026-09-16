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

    /// Once облако подвело один раз за сеанс, все последующие отрезки идут сразу на Qwen3 без
    /// повторной попытки — до конца ЭТОГО сеанса. Без этого каждая следующая фраза платила бы тем
    /// же таймаутом заново, и разговор с плохой сетью означал бы паузу в 3с перед каждой репликой,
    /// а не один раз в начале.
    private var stickyFallback = false
    /// Сколько ждать ответ облака, прежде чем считать его недоступным. Дольше пары секунд перевод
    /// всё равно бесполезен — собеседник уже сказал следующую фразу.
    private static let cloudTimeout: UInt64 = 3_000_000_000

    /// Вызывается один раз в начале нового сеанса переводчика — снимает липкий откат из
    /// предыдущего разговора, чтобы разовый сетевой сбой не прибивал облако навсегда.
    func beginSession() {
        stickyFallback = false
        lastUsedFallback = false
        lastFallbackReason = nil
    }

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

    func resetCounter() { requestCount = 0 }

    /// Translate one segment through `service`, falling back to the on-device model on any
    /// failure. Which service to use is the caller's call (LiveTranslatorView's model picker) --
    /// this used to read its own persisted `service` property instead, which meant the choice
    /// lived in two places (an engine picker plus a service picker nested inside it) that had to
    /// be kept in sync for no reason once the screen collapsed to a single three-way picker.
    func translate(_ text: String,
                   service: Service,
                   from sourceName: String,
                   to targetName: String,
                   recentContext: [String]) async throws -> String {
        if !stickyFallback, service.isConfigured {
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
                stickyFallback = true
            }
        } else if !stickyFallback {
            lastFallbackReason = "\(service.label) has no key set"
            stickyFallback = true
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
        // Captured as a `let` below rather than the `var` built above: a task-group closure must
        // be @Sendable, and a mutable outer variable captured there is exactly the kind of thing
        // strict concurrency checking rejects, even though nothing actually mutates it afterward.
        let promptToSend = prompt

        // A short timeout on purpose: past a couple of seconds the translation is useless anyway,
        // and falling back to the local model beats making the user wait for something stale.
        // This used to be a comment with no code behind it -- requestCloud had no timeout at all,
        // so a slow or hanging network call just sat there for however long URLSession's own
        // default timeout is (a minute or more), and the interpreter looked completely dead for
        // the whole time rather than falling back the way the comment claimed it did.
        let rawAnswer = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                // No call out to LocalLLMTranslator.cleaned here -- that's a @MainActor-isolated
                // static method, and this closure runs as a detached child task that does NOT
                // inherit the enclosing @MainActor's isolation just because CloudTranslator itself
                // is @MainActor. Cleaning happens below, back in this method's own actor context,
                // once the race between the two child tasks has already resolved.
                switch service {
                case .gigachat:
                    return try await GigaChatService.shared.ask(text: promptToSend, imageData: nil, history: [])
                case .yandexgpt:
                    return try await YandexGPTService.shared.ask(text: promptToSend, imageData: nil, history: [])
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.cloudTimeout)
                throw CloudTranslatorError.timedOut
            }
            // First one back wins; the loser is cancelled so a cloud reply that eventually shows
            // up after the timeout doesn't keep the request alive for no reason.
            guard let result = try await group.next() else { throw CloudTranslatorError.timedOut }
            group.cancelAll()
            return result
        }
        let cleaned = LocalLLMTranslator.cleaned(rawAnswer)
        guard !cleaned.isEmpty else { throw CloudTranslatorError.emptyReply }
        return cleaned
    }

    enum CloudTranslatorError: LocalizedError {
        case emptyReply
        case timedOut

        var errorDescription: String? {
            switch self {
            case .emptyReply: return "The service returned an empty translation."
            case .timedOut: return "Cloud translation timed out."
            }
        }
    }
}
