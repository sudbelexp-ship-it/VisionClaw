// VisionClaw - GigaChatConstants.swift
// Endpoints and tuning values for the GigaChat (Sber) backend.
//
// Ported from OpenVision (D:\OpenVision\OpenVision\Config\Constants.swift, enum Sber) — same
// values, just pulled out as their own top-level enum since VisionClaw has no shared Constants
// namespace.

import CoreGraphics

enum GigaChatConstants {
    /// GigaChat OAuth (Authorization Key -> Access Token). Non-standard port 9443.
    static let oauthURL = "https://ngw.devices.sberbank.ru:9443/api/v2/oauth"
    /// GigaChat REST API base (files, chat/completions).
    static let apiBase = "https://gigachat.devices.sberbank.ru/api/v1"
    /// Scope for individuals (Freemium tier).
    static let scope = "GIGACHAT_API_PERS"
    /// Host suffix the Минцифры (Russian government) CA trust applies to — see GigaChatTrustDelegate.
    static let trustedHostSuffix = ".devices.sberbank.ru"

    /// Photo resize before upload: long side capped (no upscale), short side kept where possible.
    static let maxLongSide: CGFloat = 1600
    static let minShortSide: CGFloat = 800
    static let jpegQuality: CGFloat = 0.8

    /// Refresh the OAuth token proactively, not strictly on expiry.
    static let tokenRefreshMarginMs: Int64 = 60_000
    /// Max retries on HTTP 429, with growing backoff.
    static let maxRateLimitRetries = 2
}
