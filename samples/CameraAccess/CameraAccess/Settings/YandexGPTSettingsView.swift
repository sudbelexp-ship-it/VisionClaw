// VisionClaw - YandexGPTSettingsView.swift
// Settings for the YandexGPT (Yandex Cloud) backend.

import SwiftUI

struct YandexGPTSettingsView: View {
    private let settings = SettingsManager.shared

    @State private var apiKey: String = ""
    @State private var folderId: String = ""

    @State private var isChecking = false
    @State private var checkResult: CheckResult?

    enum CheckResult {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("Api-Key from Yandex Cloud", text: $apiKey)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Folder ID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("b1gxxxxxxxxxxxxxxxxx", text: $folderId)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }
            } header: {
                Text("Authorization")
            } footer: {
                if apiKey.isEmpty || folderId.isEmpty {
                    Label("Both fields are required for the YandexGPT backend", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange).font(.caption)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Configured", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green).font(.caption)
                        // The single most common mistake: typing a folder NAME (like "dev")
                        // where Yandex wants the folder's ID. The API rejects that with a 403,
                        // which reads like a broken key even though the key is fine.
                        Text("Folder ID is the b1g… identifier from the Yandex Cloud console — not the folder's name.")
                            .font(.caption)
                    }
                }
            }

            Section {
                Button {
                    checkConnection()
                } label: {
                    HStack {
                        if isChecking {
                            ProgressView().padding(.trailing, 4)
                        }
                        Text("Test connection")
                    }
                }
                .disabled(apiKey.isEmpty || folderId.isEmpty || isChecking)

                if let checkResult {
                    switch checkResult {
                    case .success:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .failure(let message):
                        VStack(alignment: .leading, spacing: 10) {
                            Label(message, systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                            // Yandex's 403 for a wrong folder names the CORRECT id in the same
                            // sentence ("does not match with service account folder ID 'b1g…'"),
                            // so the fix is one tap rather than a trip to the cloud console.
                            if let suggested = Self.suggestedFolderId(in: message), suggested != folderId {
                                Button {
                                    folderId = suggested
                                    saveSettings()
                                    checkConnection()
                                } label: {
                                    Label("Use \(suggested)", systemImage: "wand.and.stars")
                                }
                            }
                        }
                    }
                }
            }

            Section {
                Link(destination: URL(string: "https://aistudio.yandex.ru")!) {
                    HStack {
                        Text("Get an API key")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Help")
            } footer: {
                Text("YandexGPT is Yandex Cloud's text + vision backend, via an OpenAI-compatible API. Vision uses a hosted Qwen multimodal model.")
            }
        }
        .navigationTitle("YandexGPT")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = settings.yandexGPTApiKey
            folderId = settings.yandexGPTFolderId
        }
        .onDisappear { saveSettings() }
    }

    /// Pulls the correct folder id out of Yandex's own error text:
    /// "... does not match with service account folder ID 'b1gl3djn8rjbditqrul4' ...".
    /// Returns nil when the message isn't that specific error.
    static func suggestedFolderId(in message: String) -> String? {
        guard let range = message.range(of: "service account folder ID '") else { return nil }
        let rest = message[range.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        let candidate = String(rest[..<end])
        return candidate.isEmpty ? nil : candidate
    }

    private func saveSettings() {
        settings.yandexGPTApiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.yandexGPTFolderId = folderId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkConnection() {
        saveSettings()
        isChecking = true
        checkResult = nil
        Task {
            do {
                try await YandexGPTService.shared.checkConnection()
                await MainActor.run {
                    checkResult = .success
                    isChecking = false
                }
            } catch {
                await MainActor.run {
                    checkResult = .failure(error.localizedDescription)
                    isChecking = false
                }
            }
        }
    }
}

#Preview {
    NavigationStack { YandexGPTSettingsView() }
}
