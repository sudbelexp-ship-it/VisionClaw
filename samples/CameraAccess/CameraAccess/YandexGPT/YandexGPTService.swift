// VisionClaw - YandexGPTService.swift
// YandexGPT (Yandex Cloud) backend — cloud text + vision, OpenAI-compatible REST shape.
//
// Much simpler than GigaChat: a static API key (no OAuth token exchange), inline base64 images
// (no separate upload step), and a standard, globally-trusted TLS certificate (Yandex isn't
// subject to the sanctions-driven cutoff from Western CAs that pushed Sberbank onto the
// Минцифры root — no custom URLSessionDelegate needed here).
//
// Endpoint/schema confirmed directly against Yandex's own docs (aistudio.yandex.ru) at the time
// this was written:
//   POST https://ai.api.cloud.yandex.net/v1/chat/completions
//   Headers: Authorization: Api-Key <key>, OpenAI-Project: <folder_id>
//   Text model:   "gpt://<folder_id>/yandexgpt/latest"
//   Vision model: "gpt://<folder_id>/qwen3.6-35b-a3b" (Yandex's multimodal offering is a hosted
//                 Qwen model, not a separate proprietary "YandexVLM" endpoint)
//   Vision content shape is identical to OpenAI's own:
//     [{"type":"text","text":"..."},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,..."}}]
//   Response is the standard OpenAI chat-completion shape (choices[0].message.content).

import Foundation

actor YandexGPTService {
    static let shared = YandexGPTService()

    private let session = URLSession.shared

    private init() {}

    /// Ask YandexGPT a question, optionally about a photo. One-shot: no conversation history.
    func ask(text: String, imageData: Data?) async throws -> String {
        let apiKey = SettingsManager.shared.yandexGPTApiKey
        let folderId = SettingsManager.shared.yandexGPTFolderId
        guard !apiKey.isEmpty, !folderId.isEmpty else { throw YandexGPTError.notConfigured }

        let model: String
        let content: Any
        if let imageData {
            model = "gpt://\(folderId)/qwen3.6-35b-a3b"
            let base64 = imageData.base64EncodedString()
            content = [
                ["type": "text", "text": text.isEmpty ? "What is shown in this picture?" : text],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
            ]
        } else {
            model = "gpt://\(folderId)/yandexgpt/latest"
            content = text
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": content]],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: "https://ai.api.cloud.yandex.net/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Api-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(folderId, forHTTPHeaderField: "OpenAI-Project")
        request.httpBody = body
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw YandexGPTError.noResponse }
        guard (200...299).contains(http.statusCode) else {
            throw YandexGPTError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try YandexGPTChatResponse.parse(data)
    }

    /// "Test connection" button in settings — a minimal text completion.
    func checkConnection() async throws {
        _ = try await ask(text: "ping", imageData: nil)
    }
}

/// Parses YandexGPT's OpenAI-compatible response shape: `choices[0].message.content`.
enum YandexGPTChatResponse {
    enum ParseError: Error, Equatable { case invalidJSON, emptyChoices, missingContent }

    static func parse(_ data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]] else {
            throw ParseError.invalidJSON
        }
        guard let message = choices.first?["message"] as? [String: Any] else {
            throw ParseError.emptyChoices
        }
        guard let content = (message["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw ParseError.missingContent
        }
        return content
    }
}

enum YandexGPTError: LocalizedError, Equatable {
    case notConfigured
    case noResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "YandexGPT is not configured. Add an API key and Folder ID in settings."
        case .noResponse:
            return "No response from YandexGPT."
        case .http(let code, let detail):
            return "YandexGPT error (HTTP \(code))\(detail.isEmpty ? "" : ": \(detail)")"
        }
    }
}
