// VisionClaw - DirectAIBackend.swift
// A backend the phone talks to directly (REST or on-device inference). GigaChat, YandexGPT and
// the local FastVLM model all conform -- and since OpenAI/Gemini were removed, that is every
// engine the app has, so the router below can no longer return nil.

import Foundation

protocol DirectAIBackend {
    /// Ask a question, optionally about a photo. One-shot: implementations don't keep a running
    /// conversation history — each call is a fresh turn.
    func ask(text: String, imageData: Data?) async throws -> String
}

extension GigaChatService: DirectAIBackend {}
extension YandexGPTService: DirectAIBackend {}

/// FastVLMService is @MainActor; the protocol method isn't actor-isolated, so route through an
/// explicit MainActor hop rather than declaring conformance directly (a plain `extension
/// FastVLMService: DirectAIBackend {}` would make the protocol requirement implicitly
/// MainActor-isolated too, which is fine here but this keeps the call site uniform with the
/// actor-based backends above).
struct LocalFastVLMBackend: DirectAIBackend {
    func ask(text: String, imageData: Data?) async throws -> String {
        try await FastVLMService.shared.ask(text: text, imageData: imageData)
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
