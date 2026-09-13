// VisionClaw - HistoryView.swift
// Past conversations: chat threads and recordings of live-interpreting sessions, in one list.
//
// Both kinds live together deliberately. From the user's side there is no difference worth a tab:
// "what did we talk about on Tuesday" is the same question whether the answer came from GigaChat
// or from someone speaking Chinese across a table.

import SwiftUI

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ConversationStore.shared
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    empty
                } else {
                    List {
                        ForEach(store.sessions) { session in
                            NavigationLink {
                                SessionDetailView(session: session)
                            } label: {
                                row(session)
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { store.sessions[$0].id }.forEach(store.delete)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                }
            }
            .sheet(isPresented: $showSettings) { HistorySettingsView() }
            .onAppear { store.load() }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing saved yet").font(.headline)
            Text("Chats and interpreting sessions are kept on this phone for \(store.retentionDays) days.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func row(_ session: StoredSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: session.kind == .chat ? "bubble.left.and.bubble.right" : "character.bubble")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(session.subtitle)
                    Text("·")
                    Text(session.updatedAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - One session

private struct SessionDetailView: View {
    let session: StoredSession
    private let store = ConversationStore.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(session.messages) { message in
                    VStack(alignment: .leading, spacing: 6) {
                        if let file = message.imageFile,
                           let image = UIImage(contentsOfFile: store.imageURL(session: session.id, file: file).path) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        if !message.text.isEmpty {
                            Text(message.text)
                                .font(message.role == .user ? .subheadline : .body)
                                .foregroundStyle(foreground(for: message.role))
                                .textSelection(.enabled)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(background(for: message.role),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .frame(maxWidth: .infinity,
                           alignment: message.role == .user ? .trailing : .leading)
                }
            }
            .padding(16)
        }
        .navigationTitle(session.subtitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func foreground(for role: StoredMessage.Role) -> Color {
        switch role {
        case .user: return .white
        case .assistant: return .primary
        case .note: return .orange
        }
    }

    private func background(for role: StoredMessage.Role) -> Color {
        switch role {
        case .user: return .accentColor
        case .assistant: return .appSurface
        case .note: return .orange.opacity(0.15)
        }
    }
}

// MARK: - Retention settings

struct HistorySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ConversationStore.shared
    @AppStorage(ConversationStore.retentionDaysKey) private var days = 7
    @AppStorage(ConversationStore.maxMegabytesKey) private var megabytes = 500
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Keep for", selection: $days) {
                        Text("3 days").tag(3)
                        Text("1 week").tag(7)
                        Text("2 weeks").tag(14)
                        Text("1 month").tag(30)
                    }
                    Picker("Size limit", selection: $megabytes) {
                        Text("100 MB").tag(100)
                        Text("250 MB").tag(250)
                        Text("500 MB").tag(500)
                        Text("1 GB").tag(1000)
                    }
                } header: {
                    Text("Retention")
                } footer: {
                    // Both limits apply, and saying so matters: someone who sets a month and then
                    // finds a fortnight-old conversation gone would otherwise think it a bug.
                    Text("Whichever comes first. Conversations past the age are removed; if what's "
                         + "left is still over the size limit, the oldest go until it fits.")
                }

                Section {
                    HStack {
                        Text("Used")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: store.usedBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    Button("Delete all history", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Photos are saved at reduced size — roughly 150 KB each rather than the "
                         + "several megabytes the camera produces.")
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
            .alert("Delete all history?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { store.deleteAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every saved chat and interpreting session is removed from this phone. This can't be undone.")
            }
            .onChange(of: days) { _, _ in store.prune() }
            .onChange(of: megabytes) { _, _ in store.prune() }
            .onAppear { store.refreshUsage() }
        }
    }
}
