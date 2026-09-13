// VisionClaw - ChatSession.swift
// The conversation itself, owned outside any screen.
//
// It used to live in AskAssistantView's @State, which quietly made the glasses assistant
// impossible: a voice command answered by the glasses had nowhere to put its question and its
// answer, so the two halves of the app -- the chat you type in and the glasses you talk to --
// could not be the same conversation. Anything that can ask a question now writes here, and the
// chat screen is simply a view of it.

import Foundation
import UIKit

/// One turn in the transcript. Photos live on the message that carried them, so scrolling back
/// shows what was actually asked about rather than just the words.
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, failure }

    let id: UUID
    let role: Role
    var text: String
    var image: UIImage?
    /// Name of this photo's file in the history folder, assigned once when the message is created.
    /// Without it every save would write the same picture again under a new name, and the history
    /// size cap would be reached by duplicates rather than by conversations.
    var imageFile: String?

    init(role: Role, text: String, image: UIImage? = nil, imageFile: String? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.image = image
        self.imageFile = imageFile
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class ChatSession: ObservableObject {
    static let shared = ChatSession()
    private init() {}

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isAsking = false
    /// Set while a glasses voice command is being handled, so the chat screen can show what is
    /// happening even though the user is not looking at it.
    @Published private(set) var activity: String?

    /// Identity of the thread on disk. A new UUID per "New chat" so reopening history shows the
    /// separate conversations the user actually had, not one endless log.
    private(set) var sessionId = UUID()

    var engine: IntelligenceEngine {
        IntelligenceEngine(rawValue: UserDefaults.standard.string(forKey: IntelligenceEngine.defaultsKey) ?? "")
            ?? .gigachat
    }

    // MARK: Thread management

    func newChat() {
        messages.removeAll()
        sessionId = UUID()
    }

    func append(_ message: ChatMessage) {
        messages.append(message)
    }

    /// Each engine answers on its own and remembers nothing of the others' turns, so a switch
    /// starts a separate thread rather than implying a continuity that does not exist.
    func engineChanged() {
        persist()
        newChat()
    }

    // MARK: Asking

    /// Ask the current engine, appending both the question and the answer to the thread.
    /// `spokenNote` is what the glasses assistant shows while it works ("Taking a photo…").
    @discardableResult
    func ask(text: String, image: UIImage?, spokenNote: String? = nil) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || image != nil else { return nil }

        let imageFile = image.flatMap { ConversationStore.shared.storeImage($0, session: sessionId) }
        append(ChatMessage(role: .user, text: trimmed, image: image, imageFile: imageFile))

        isAsking = true
        activity = spokenNote
        defer {
            isAsking = false
            activity = nil
        }

        // Snapshot before the new question is appended, so the model sees the conversation up to
        // but not including what it is being asked right now.
        let history = Array(conversationHistory.dropLast())
        let backend = DirectAIBackendRouter.backend(for: engine)
        do {
            let answer = try await backend.ask(
                text: trimmed,
                imageData: image?.jpegData(compressionQuality: 0.85),
                history: history)
            append(ChatMessage(role: .assistant, text: answer))
            persist()
            return answer
        } catch {
            append(ChatMessage(role: .failure, text: error.localizedDescription))
            persist()
            return nil
        }
    }

    /// What the backend gets as context. Errors are dropped -- they are notes to the user, not
    /// turns in the conversation -- and the window is capped by the user's own setting, because
    /// these APIs are stateless and re-charge for the whole window on every single request.
    private var conversationHistory: [ChatTurn] {
        messages.compactMap { message -> ChatTurn? in
            switch message.role {
            case .user: return ChatTurn(role: .user, text: message.text)
            case .assistant: return ChatTurn(role: .assistant, text: message.text)
            case .failure: return nil
            }
        }
        .suffix(SettingsManager.shared.memoryTurns)
        .map { $0 }
    }

    // MARK: History

    /// Mirror the thread into the history store. Called after every exchange rather than on exit:
    /// a conversation abandoned mid-answer is exactly the one worth keeping, and an app killed in
    /// the background never gets a closing callback.
    func persist() {
        guard !messages.isEmpty else { return }
        let stored: [StoredMessage] = messages.map { message in
            let role: StoredMessage.Role
            switch message.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .failure: role = .note
            }
            return StoredMessage(id: message.id, role: role, text: message.text,
                                 imageFile: message.imageFile)
        }
        ConversationStore.shared.save(id: sessionId, kind: .chat,
                                      subtitle: engine.label, messages: stored)
    }
}
