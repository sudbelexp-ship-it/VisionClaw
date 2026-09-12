// VisionClaw - GigaChatClient.swift
// Low-level GigaChat REST client: file upload/delete, chat/completions.
//
// Deliberately serialized: the Freemium tier for individuals serves exactly one in-flight
// request — a second concurrent one gets an error. `actor` alone does NOT guarantee this (Swift
// actors are re-entrant across await), so requests additionally go through an explicit
// sequential queue (`enqueue`).
//
// GigaChat's image format differs from OpenAI/Gemini/Yandex (inline base64): GigaChat requires
// the photo to be uploaded first via POST /files, and the returned `id` is then referenced in
// the chat request's `attachments`.
//
// Ported from OpenVision (D:\OpenVision\OpenVision\Services\Sber\GigaChatClient.swift), unchanged
// apart from type names and the constants namespace.

import Foundation

actor GigaChatClient {
    static let shared = GigaChatClient()

    private let session: URLSession
    private var queueTail: Task<Void, Never> = Task {}

    private init() {
        session = URLSession(configuration: .default, delegate: GigaChatTrustDelegate(), delegateQueue: nil)
    }

    // MARK: - Public API (every call goes through the `enqueue` queue)

    func uploadImage(_ jpeg: Data, authKey: String) async throws -> String {
        try await enqueue { try await self.performUpload(jpeg, authKey: authKey) }
    }

    func deleteFile(_ fileId: String, authKey: String) async throws {
        try await enqueue { try await self.performDelete(fileId, authKey: authKey) }
    }

    /// `body` is already-serialized JSON `{"model": ..., "messages": [...]}`. Passed as `Data`
    /// rather than `[String: Any]` because the type crosses an actor boundary, and `Any` inside a
    /// dictionary isn't `Sendable`.
    func chat(body: Data, authKey: String) async throws -> String {
        try await enqueue { try await self.performChat(body: body, authKey: authKey) }
    }

    /// OAuth + GET /models — used by the "Test connection" button in settings. Returns the
    /// number of available models, purely as a success indicator for the UI.
    func checkConnection(authKey: String) async throws -> Int {
        try await enqueue { try await self.performListModels(authKey: authKey) }
    }

    // MARK: - Sequential queue

    /// Waits for every previously queued operation to finish, then runs `operation` — so every
    /// GigaChat request goes strictly one at a time, even if called concurrently.
    private func enqueue<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = queueTail
        var outcome: Result<T, Error>!
        let task = Task {
            _ = await previous.value
            do {
                outcome = .success(try await operation())
            } catch {
                outcome = .failure(error)
            }
        }
        queueTail = Task { await task.value }
        await task.value
        return try outcome.get()
    }

    // MARK: - Requests

    private func performUpload(_ jpeg: Data, authKey: String) async throws -> String {
        let boundary = "VisionClaw-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"purpose\"\r\n\r\n".data(using: .utf8)!)
        body.append("general\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let data = try await send(authKey: authKey) { token in
            var request = URLRequest(url: URL(string: "\(GigaChatConstants.apiBase)/files")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = body
            request.timeoutInterval = 60
            return request
        }
        return try GigaChatFileResponse.parse(data).id
    }

    private func performDelete(_ fileId: String, authKey: String) async throws {
        _ = try await send(authKey: authKey) { token in
            var request = URLRequest(
                url: URL(string: "\(GigaChatConstants.apiBase)/files/\(fileId)/delete")!
            )
            // POST, not DELETE — confirmed against the real API.
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30
            return request
        }
    }

    private func performChat(body: Data, authKey: String) async throws -> String {
        let data = try await send(authKey: authKey) { token in
            var request = URLRequest(url: URL(string: "\(GigaChatConstants.apiBase)/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = body
            request.timeoutInterval = 60
            return request
        }
        return try GigaChatChatResponse.parse(data)
    }

    private func performListModels(authKey: String) async throws -> Int {
        let data = try await send(authKey: authKey) { token in
            var request = URLRequest(url: URL(string: "\(GigaChatConstants.apiBase)/models")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30
            return request
        }
        return try GigaChatModelsResponse.parse(data).count
    }

    /// Shared plumbing: supplies the current token, retries once on 401 (forcing a refresh), up
    /// to `maxRateLimitRetries` times on 429 (growing pause), 402 -> a clear "out of tokens" error.
    private func send(
        authKey: String,
        makeRequest: @escaping (String) -> URLRequest
    ) async throws -> Data {
        var token = try await GigaChatAuth.shared.accessToken(authKey: authKey)
        var retried401 = false
        var rateLimitRetries = 0

        while true {
            let (data, response) = try await session.data(for: makeRequest(token))
            guard let http = response as? HTTPURLResponse else { throw GigaChatError.noResponse }

            switch http.statusCode {
            case 200...299:
                return data
            case 401 where !retried401:
                retried401 = true
                token = try await GigaChatAuth.shared.forceRefresh(authKey: authKey)
            case 429 where rateLimitRetries < GigaChatConstants.maxRateLimitRetries:
                rateLimitRetries += 1
                let delayMs = 1_000 + rateLimitRetries * 500 // 1.5s, then 2.0s
                try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            case 402:
                throw GigaChatError.tokenExhausted
            default:
                throw GigaChatError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}

/// Parses `POST /files` — just the `id` (a UUID string), needed for `attachments` in the chat request.
struct GigaChatFileResponse: Equatable {
    let id: String

    enum ParseError: Error, Equatable { case invalidJSON, missingId }

    static func parse(_ data: Data) throws -> GigaChatFileResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        guard let id = obj["id"] as? String, !id.isEmpty else {
            throw ParseError.missingId
        }
        return GigaChatFileResponse(id: id)
    }
}

/// Parses `GET /models` — OpenAI-compatible shape: `{"data": [{"id": "..."}, ...]}`.
struct GigaChatModelsResponse: Equatable {
    let count: Int

    enum ParseError: Error, Equatable { case invalidJSON }

    static func parse(_ data: Data) throws -> GigaChatModelsResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["data"] as? [[String: Any]] else {
            throw ParseError.invalidJSON
        }
        return GigaChatModelsResponse(count: models.count)
    }
}

/// Parses `POST /chat/completions` — OpenAI-compatible shape: `choices[0].message.content`.
enum GigaChatChatResponse {
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
