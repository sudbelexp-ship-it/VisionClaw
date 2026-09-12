// VisionClaw - LocalMLXSettingsView.swift
// Download & manage the on-device FastVLM model.
//
// Single-model version of OpenVision's GemmaSettingsView — no model picker, since this app only
// offers the one on-device model proven stable on this device class (see FastVLMService.swift).

import SwiftUI

struct LocalMLXSettingsView: View {
    @ObservedObject private var fastVLM = FastVLMService.shared

    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var sizeBytes: Int64 = 0

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
    /// "Downloaded" means most of the weights are on disk — a snapshot holding only configs and
    /// a tokenizer (tens of MB) passing a `> 0` check would make a missing model look ready.
    private var isDownloaded: Bool {
        sizeBytes >= FastVLMService.expectedDownloadBytes / 2
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FastVLM 0.5B")
                        Text("~1.2 GB • fastest on-device vision model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isDownloaded {
                            Text("Downloaded • \(sizeText)")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else if sizeBytes > 0 {
                            Text("Incomplete — download again")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if fastVLM.isModelLoaded {
                        Text("ACTIVE")
                            .font(.caption2).fontWeight(.bold)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Runs entirely on-device via Apple MLX — no API key, no cloud, works offline. Requires a physical device.")
            }

            Section {
                if isDownloading {
                    VStack(alignment: .leading, spacing: 8) {
                        if fastVLM.isFinalizing {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Processing model… (loading into memory, can take a couple minutes)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView(value: fastVLM.downloadProgress)
                            Text("Downloading… \(Int(fastVLM.downloadProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button {
                        download()
                    } label: {
                        Label(isDownloaded ? "Re-download Model" : "Download FastVLM", systemImage: "arrow.down.circle")
                    }
                }

                if let downloadError {
                    Text(downloadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Download")
            } footer: {
                if isDownloaded {
                    Label("FastVLM is ready.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("The first download is over a gigabyte — keep the app open and use Wi-Fi.")
                }
            }

            if sizeBytes > 0 && !isDownloading {
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Label(isDeleting ? "Deleting…" : "Delete FastVLM", systemImage: "trash")
                            Spacer()
                            Text(sizeText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isDeleting)
                } footer: {
                    Text(isDownloaded
                         ? "Removes \(sizeText) from your phone. You can download it again anytime."
                         : "Removes \(sizeText) of incomplete download data.")
                }
            }
        }
        .navigationTitle("Local Model")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshSize() }
        .alert("Delete FastVLM?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { deleteModel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(sizeBytes > 0
                 ? "This frees up \(sizeText) of storage. You can re-download it anytime."
                 : "You can re-download it anytime.")
        }
    }

    /// Measure on-disk size off the main thread (walks a multi-hundred-MB tree).
    private func refreshSize() {
        Task.detached {
            let bytes = FastVLMService.downloadedSizeBytes()
            await MainActor.run { self.sizeBytes = bytes }
        }
    }

    private func deleteModel() {
        isDeleting = true
        Task {
            _ = await fastVLM.deleteDownloadedModel()
            refreshSize()
            isDeleting = false
        }
    }

    private func download() {
        downloadError = nil
        isDownloading = true
        Task {
            do {
                try await fastVLM.download { _ in }
                refreshSize()
            } catch {
                downloadError = error.localizedDescription
            }
            isDownloading = false
        }
    }
}

#Preview {
    NavigationStack { LocalMLXSettingsView() }
}
