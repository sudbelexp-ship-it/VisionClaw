// VisionClaw - GigaChatAuth.swift
// OAuth2 client-credentials for GigaChat: Authorization Key -> Access Token.
//
// Unlike OpenAI/Gemini (a static key), GigaChat exchanges the Authorization Key for a
// short-lived (~30 min) access token that must be refreshed ahead of expiry. This is the one
// place in the app that does that — an actor, so concurrent sendMessage calls don't race a
// refresh.
//
// Ported from OpenVision (D:\OpenVision\OpenVision\Services\Sber\SberAuth.swift), unchanged
// apart from the type/constant names.

import Foundation

actor GigaChatAuth {
    static let shared = GigaChatAuth()

    private struct Token {
        let accessToken: String
        /// Absolute expiry, Unix epoch milliseconds (confirmed via a real run — this is NOT a
        /// duration in seconds, a common misreading of GigaChat's OAuth response).
        let expiresAtMs: Int64
    }

    private var current: Token?
    private let session: URLSession

    private init() {
        session = URLSession(configuration: .default, delegate: GigaChatTrustDelegate(), delegateQueue: nil)
    }

    /// The current access token; refreshes ahead of expiry (see `tokenRefreshMarginMs`).
    func accessToken(authKey: String) async throws -> String {
        if let token = current, !isExpiringSoon(token) {
            return token.accessToken
        }
        return try await refresh(authKey: authKey)
    }

    /// Forced refresh — called by GigaChatClient on a 401 from the API.
    func forceRefresh(authKey: String) async throws -> String {
        try await refresh(authKey: authKey)
    }

    /// Cached-token status for a diagnostics screen — never the token itself.
    struct DiagnosticsStatus {
        let isAlive: Bool
        let secondsRemaining: Int?
    }

    func diagnosticsStatus() -> DiagnosticsStatus {
        guard let current else { return DiagnosticsStatus(isAlive: false, secondsRemaining: nil) }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let remainingMs = current.expiresAtMs - nowMs
        guard remainingMs > 0 else { return DiagnosticsStatus(isAlive: false, secondsRemaining: nil) }
        return DiagnosticsStatus(isAlive: true, secondsRemaining: Int(remainingMs / 1000))
    }

    private func isExpiringSoon(_ token: Token) -> Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return token.expiresAtMs - nowMs < GigaChatConstants.tokenRefreshMarginMs
    }

    private func refresh(authKey: String) async throws -> String {
        guard !authKey.isEmpty else { throw GigaChatError.notConfigured }
        guard let url = URL(string: GigaChatConstants.oauthURL) else { throw GigaChatError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Basic \(authKey)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "RqUID")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = "scope=\(GigaChatConstants.scope)".data(using: .utf8)
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GigaChatError.noResponse }
        guard (200...299).contains(http.statusCode) else {
            throw GigaChatError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let parsed = try GigaChatOAuthResponse.parse(data)
        current = Token(accessToken: parsed.accessToken, expiresAtMs: parsed.expiresAtMs)
        return parsed.accessToken
    }
}

/// Parses `POST /api/v2/oauth`'s response.
struct GigaChatOAuthResponse: Equatable {
    let accessToken: String
    let expiresAtMs: Int64

    enum ParseError: Error, Equatable {
        case invalidJSON
        case missingAccessToken
        case missingExpiresAt
    }

    static func parse(_ data: Data) throws -> GigaChatOAuthResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        guard let accessToken = obj["access_token"] as? String, !accessToken.isEmpty else {
            throw ParseError.missingAccessToken
        }
        // expires_at is a number (not a string), Unix epoch milliseconds.
        guard let expiresAtMs = (obj["expires_at"] as? NSNumber)?.int64Value else {
            throw ParseError.missingExpiresAt
        }
        return GigaChatOAuthResponse(accessToken: accessToken, expiresAtMs: expiresAtMs)
    }
}

enum GigaChatError: LocalizedError, Equatable {
    case notConfigured
    case noResponse
    case invalidResponse
    case http(Int, String)
    case tokenExhausted

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "GigaChat is not configured. Add an Authorization Key in settings."
        case .noResponse:
            return "No response from GigaChat."
        case .invalidResponse:
            return "Invalid response from GigaChat."
        case .http(let code, let detail):
            return "GigaChat error (HTTP \(code))\(detail.isEmpty ? "" : ": \(detail)")"
        case .tokenExhausted:
            return "GigaChat token limit exhausted."
        }
    }
}
