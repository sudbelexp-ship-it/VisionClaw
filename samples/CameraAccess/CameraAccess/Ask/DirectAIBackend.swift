// VisionClaw - DirectAIBackend.swift
// A backend the phone talks to directly (REST or on-device inference). GigaChat, YandexGPT and
// the local FastVLM model all conform -- and since OpenAI/Gemini were removed, that is every
// engine the app has, so the router below can no longer return nil.

import Foundation

/// One earlier exchange, as plain text. Photos are deliberately not carried in history: resending
/// every image on every turn multiplies cost and latency for a picture the model already described,
/// and its own description of it is in the history anyway.
struct ChatTurn: Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let text: String
}

protocol DirectAIBackend {
    /// Ask a question, optionally about a photo, with the earlier turns of this conversation for
    /// context. `history` is oldest-first and already trimmed by the caller.
    func ask(text: String, imageData: Data?, history: [ChatTurn]) async throws -> String
}

extension DirectAIBackend {
    func ask(text: String, imageData: Data?) async throws -> String {
        try await ask(text: text, imageData: imageData, history: [])
    }
}

extension GigaChatService: DirectAIBackend {}
extension YandexGPTService: DirectAIBackend {}

/// FastVLMService is @MainActor; the protocol method isn't actor-isolated, so route through an
/// explicit MainActor hop rather than declaring conformance directly (a plain `extension
/// FastVLMService: DirectAIBackend {}` would make the protocol requirement implicitly
/// MainActor-isolated too, which is fine here but this keeps the call site uniform with the
/// actor-based backends above).
struct LocalFastVLMBackend: DirectAIBackend {
    func ask(text: String, imageData: Data?, history: [ChatTurn]) async throws -> String {
        try await FastVLMService.shared.ask(text: text, imageData: imageData, history: history)
    }
}

enum DirectAIBackendRouter {
    static func backend(for engine: IntelligenceEngine) -> DirectAIBackend {
        switch engine {
        case .gigachat: return GigaChatService.shared
        case .yandexgpt: return YandexGPTService.shared
        case .localMLX: return LocalFastVLMBackend()
        }
    }
}
