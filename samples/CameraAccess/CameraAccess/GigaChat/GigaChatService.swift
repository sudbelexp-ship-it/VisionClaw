// VisionClaw - GigaChatService.swift
// GigaChat (Sber) backend — cloud text + vision, Russian stack.
//
// One architectural difference from OpenAI/Gemini/YandexGPT: the image is uploaded as a separate
// request first (GigaChatClient.uploadImage) rather than inlined as base64 — the model receives
// it via `attachments: [file_id]`.
//
// Adapted from OpenVision (D:\OpenVision\OpenVision\Services\Sber\SberService.swift): trimmed to
// a single-turn `ask(text:imageData:)` (VisionClaw's interaction model is a one-shot "ask" button,
// not a running conversation with history/native-tool routing like OpenVision's voice agent), so
// the ConversationContext/NativeToolContext dependencies that don't exist in this app are dropped.

import Foundation
import UIKit

actor GigaChatService {
    static let shared = GigaChatService()

    private init() {}

    /// Ask GigaChat a question, optionally about a photo, with earlier turns for context.
    func ask(text: String, imageData: Data?, history: [ChatTurn] = []) async throws -> String {
        let authKey = SettingsManager.shared.gigaChatAuthKey
        guard !authKey.isEmpty else { throw GigaChatError.notConfigured }

        var uploadedFileId: String?
        // The uploaded file is only needed for the duration of this request — delete it right
        // after the reply (or after an error, if the upload itself succeeded), so nothing piles
        // up in GigaChat's file storage.
        defer {
            if let fileId = uploadedFileId {
                let key = authKey
                Task { try? await GigaChatClient.shared.deleteFile(fileId, authKey: key) }
            }
        }

        let userText = text.isEmpty ? "What is shown in this picture?" : text
        var attachments: [String]?
        let model: String

        if let imageData {
            let resized = Self.resizeForUpload(imageData)
            let fileId = try await GigaChatClient.shared.uploadImage(resized, authKey: authKey)
            uploadedFileId = fileId
            attachments = [fileId]
            model = SettingsManager.shared.gigaChatVisionModel
        } else {
            model = SettingsManager.shared.gigaChatTextModel
        }

        var messages: [[String: Any]] = []
        let system = SettingsManager.shared.gigaChatSystemPrompt
        if !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        for turn in history {
            messages.append(["role": turn.role.rawValue, "content": turn.text])
        }
        var userMessage: [String: Any] = ["role": "user", "content": userText]
        if let attachments {
            userMessage["attachments"] = attachments
        }
        messages.append(userMessage)

        let payload: [String: Any] = ["model": model, "messages": messages]
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try await GigaChatClient.shared.chat(body: body, authKey: authKey)
    }

    /// "Test connection" button in settings — OAuth + GET /models.
    func checkConnection(authKey: String) async throws -> Int {
        try await GigaChatClient.shared.checkConnection(authKey: authKey)
    }

    // MARK: - Image preparation

    /// Long side <= `maxLongSide` (no upscale — the short side reaching `minShortSide` comes
    /// "free" for typical photos up to ~2:1 aspect, otherwise best-effort).
    static func resizeForUpload(_ jpeg: Data) -> Data {
        guard let image = UIImage(data: jpeg) else { return jpeg }
        let scale = uploadScale(width: image.size.width, height: image.size.height)
        guard scale < 1.0 else {
            return image.jpegData(compressionQuality: GigaChatConstants.jpegQuality) ?? jpeg
        }
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return resized.jpegData(compressionQuality: GigaChatConstants.jpegQuality) ?? jpeg
    }

    /// Pure scale function — kept separate from the UIKit drawing so it's synchronously testable.
    nonisolated static func uploadScale(width: CGFloat, height: CGFloat) -> CGFloat {
        let longSide = max(width, height)
        guard longSide > 0 else { return 1.0 }
        return min(1.0, GigaChatConstants.maxLongSide / longSide)
    }
}
