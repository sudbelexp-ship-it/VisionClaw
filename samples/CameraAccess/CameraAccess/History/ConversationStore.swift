// VisionClaw - ConversationStore.swift
// Everything the app remembers between launches: chat threads with their photos, and recordings of
// live-interpreting sessions.
//
// Retention uses BOTH limits rather than picking one, because each fails on its own. An age limit
// alone can't stop a heavy week from filling the phone; a size limit alone keeps a single ancient
// conversation forever if nothing new arrives. So: drop anything past `retentionDays`, then, if the
// folder is still over `maxBytes`, keep dropping the oldest until it isn't.
//
// Layout on disk, one folder per session so a delete is one `removeItem` and a corrupt session
// can't take the index down with it:
//
//   Application Support/History/<session-id>/session.json
//   Application Support/History/<session-id>/<photo-id>.jpg
//
// Photos are re-encoded on the way in (long side capped, JPEG quality reduced) — a full-resolution
// camera frame is several megabytes and the history would blow through its budget in a day.

import Foundation
import UIKit

// MARK: - Model

struct StoredMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant, note }

    let id: UUID
    let role: Role
    let text: String
    /// File name (not a path) of the photo inside the session folder, when there is one. Stored as
    /// a name rather than a URL because the container path changes between app launches and
    /// installs -- an absolute URL saved today is invalid tomorrow.
    let imageFile: String?
    let at: Date

    init(id: UUID = UUID(), role: Role, text: String, imageFile: String? = nil, at: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.imageFile = imageFile
        self.at = at
    }
}

struct StoredSession: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case chat, interpreter }

    let id: UUID
    var kind: Kind
    var startedAt: Date
    var updatedAt: Date
    /// Engine or language pair, shown under the title in the list.
    var subtitle: String
    var messages: [StoredMessage]

    /// First thing actually said, trimmed. Computed rather than stored so it stays right when the
    /// opening message is edited or the session is reopened.
    var title: String {
        let firstText = messages.first { !$0.text.isEmpty }?.text ?? ""
        if firstText.isEmpty { return kind == .chat ? "Photo" : "Conversation" }
        return String(firstText.prefix(80))
    }
}

// MARK: - Store

@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published private(set) var sessions: [StoredSession] = []
    /// Bytes currently on disk, for the settings screen. Refreshed after every write.
    @Published private(set) var usedBytes: Int64 = 0

    static let retentionDaysKey = "historyRetentionDays"
    static let maxMegabytesKey = "historyMaxMegabytes"

    var retentionDays: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.retentionDaysKey)
        return stored > 0 ? stored : 7
    }
    var maxMegabytes: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.maxMegabytesKey)
        return stored > 0 ? stored : 500
    }
    private var maxBytes: Int64 { Int64(maxMegabytes) * 1_000_000 }

    private let root: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Loading

    func load() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var loaded: [StoredSession] = []
        for folder in folders {
            let file = folder.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: file),
                  let session = try? JSONDecoder.history.decode(StoredSession.self, from: data) else {
                continue
            }
            loaded.append(session)
        }
        sessions = loaded.sorted { $0.updatedAt > $1.updatedAt }
        prune()
    }

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func imageURL(session: UUID, file: String) -> URL {
        folder(for: session).appendingPathComponent(file)
    }

    // MARK: Writing

    /// Create or update a session. Called after every exchange rather than only when a screen
    /// closes: a conversation the user walks away from mid-answer is exactly the one they come
    /// back for, and an app killed in the background gets no closing callback.
    func save(id: UUID, kind: StoredSession.Kind, subtitle: String, messages: [StoredMessage]) {
        guard !messages.isEmpty else { return }
        let now = Date()
        var session: StoredSession
        if var existing = sessions.first(where: { $0.id == id }) {
            existing.messages = messages
            existing.updatedAt = now
            existing.subtitle = subtitle
            session = existing
        } else {
            session = StoredSession(id: id, kind: kind, startedAt: now, updatedAt: now,
                                    subtitle: subtitle, messages: messages)
        }

        let dir = folder(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.history.encode(session) {
            try? data.write(to: dir.appendingPathComponent("session.json"), options: .atomic)
        }

        sessions.removeAll { $0.id == id }
        sessions.insert(session, at: 0)
        sessions.sort { $0.updatedAt > $1.updatedAt }
        prune()
    }

    /// Write a photo into a session's folder and return the file name to store on the message.
    /// Returns nil rather than throwing: a history photo that fails to save must never take down
    /// the conversation it belongs to.
    func storeImage(_ image: UIImage, session id: UUID) -> String? {
        let dir = folder(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = Self.compress(image) else { return nil }
        let name = "\(UUID().uuidString).jpg"
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// Long side capped at 1280 and quality 0.6: still clearly readable when reviewing what was
    /// asked about, roughly 150 KB instead of several megabytes.
    static func compress(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 1280
        let longSide = max(image.size.width, image.size.height)
        guard longSide > maxSide else { return image.jpegData(compressionQuality: 0.6) }
        let scale = maxSide / longSide
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return scaled.jpegData(compressionQuality: 0.6)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
        sessions.removeAll { $0.id == id }
        refreshUsage()
    }

    func deleteAll() {
        for session in sessions {
            try? FileManager.default.removeItem(at: folder(for: session.id))
        }
        sessions.removeAll()
        refreshUsage()
    }

    // MARK: Retention

    /// Age first, then size. Both are needed — see the note at the top of this file.
    func prune() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
        for session in sessions where session.updatedAt < cutoff {
            try? FileManager.default.removeItem(at: folder(for: session.id))
        }
        sessions.removeAll { $0.updatedAt < cutoff }

        var total = directorySize(root)
        // Oldest first, so the newest conversation is the last thing to go.
        var oldestFirst = sessions.sorted { $0.updatedAt < $1.updatedAt }
        while total > maxBytes, let oldest = oldestFirst.first {
            let size = directorySize(folder(for: oldest.id))
            try? FileManager.default.removeItem(at: folder(for: oldest.id))
            sessions.removeAll { $0.id == oldest.id }
            oldestFirst.removeFirst()
            total -= size
        }
        usedBytes = total
    }

    func refreshUsage() {
        usedBytes = directorySize(root)
    }

    private func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}

private extension JSONEncoder {
    static let history: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let history: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
