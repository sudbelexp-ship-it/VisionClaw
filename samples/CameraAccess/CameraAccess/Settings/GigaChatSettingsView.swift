// VisionClaw - GigaChatSettingsView.swift
// Settings for the GigaChat (Sber) backend.
//
// Adapted from OpenVision's GigaChatSettingsView — same fields, ported to VisionClaw's settings
// convention (`SettingsManager.shared` plain properties + a NavigationLink push instead of a
// sheet with an EnvironmentObject).

import SwiftUI

struct GigaChatSettingsView: View {
    private let settings = SettingsManager.shared

    @State private var authKey: String = ""
    @State private var visionModel: String = "GigaChat-2-Max"
    @State private var textModel: String = "GigaChat-2-Pro"
    @State private var systemPrompt: String = ""

    @State private var isChecking = false
    @State private var checkResult: CheckResult?

    enum CheckResult {
        case success(modelCount: Int)
        case failure(String)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Authorization Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("key from your developers.sber.ru account", text: $authKey)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Authorization")
            } footer: {
                if authKey.isEmpty {
                    Label("Required for the GigaChat backend", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange).font(.caption)
                } else {
                    Label("Key set", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green).font(.caption)
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
                .disabled(authKey.isEmpty || isChecking)

                if let checkResult {
                    switch checkResult {
                    case .success(let modelCount):
                        Label("Connected (\(modelCount) models available)", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
            }

            Section {
                TextField("Vision model", text: $visionModel)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                TextField("Text model", text: $textModel)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            } header: {
                Text("Models")
            } footer: {
                Text("Defaults: GigaChat-2-Max for photos, GigaChat-2-Pro for text.")
            }

            Section {
                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 100)
            } header: {
                Text("System prompt")
            } footer: {
                Text("Sent before every request. Keep it short — the reply is spoken aloud.")
            }

            Section {
                Link(destination: URL(string: "https://developers.sber.ru/studio")!) {
                    HStack {
                        Text("Get an Authorization Key")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Help")
            } footer: {
                Text("GigaChat is Sber's cloud text + vision backend. Requests are serialized — the Freemium tier serves one at a time.")
            }
        }
        .navigationTitle("GigaChat")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            authKey = settings.gigaChatAuthKey
            visionModel = settings.gigaChatVisionModel
            textModel = settings.gigaChatTextModel
            systemPrompt = settings.gigaChatSystemPrompt
        }
        .onDisappear { saveSettings() }
    }

    private func saveSettings() {
        settings.gigaChatAuthKey = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVision = visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.gigaChatVisionModel = trimmedVision.isEmpty ? "GigaChat-2-Max" : trimmedVision
        let trimmedText = textModel.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.gigaChatTextModel = trimmedText.isEmpty ? "GigaChat-2-Pro" : trimmedText
        settings.gigaChatSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkConnection() {
        let key = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isChecking = true
        checkResult = nil
        Task {
            do {
                let count = try await GigaChatService.shared.checkConnection(authKey: key)
                await MainActor.run {
                    checkResult = .success(modelCount: count)
                    isChecking = false
                }
            } catch {
                await MainActor.run {
                    // The most common TLS-error cause spelled out explicitly — a build/bundling
                    // bug (the Минцифры certificate missing from the bundle), not a settings
                    // problem — plus the exact SecTrust failure reason when the delegate did see
                    // a certificate challenge at all (nil means the failure happened even earlier
                    // in the TLS handshake — see GigaChatTrustDelegate's doc comment).
                    let certHint = GigaChatTrustDelegate.bundledCertificateCount() < 2
                        ? " (the Минцифры certificate is missing from this build)"
                        : ""
                    let trustDetail = GigaChatTrustDelegate.lastTrustEvaluationError
                        .map { " [TLS detail: \($0)]" } ?? ""
                    checkResult = .failure(error.localizedDescription + certHint + trustDetail)
                    isChecking = false
                }
            }
        }
    }
}

#Preview {
    NavigationStack { GigaChatSettingsView() }
}
