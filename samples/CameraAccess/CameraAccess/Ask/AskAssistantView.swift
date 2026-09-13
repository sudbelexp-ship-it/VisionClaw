// VisionClaw - AskAssistantView.swift
// The screen shown instead of the LiveKit call when a direct backend (GigaChat, YandexGPT, or
// the local FastVLM model) is selected — see DirectAIBackend.swift. Unlike the always-listening
// LiveKit call, this is a one-shot "ask" interaction: type or speak a question, optionally attach
// a photo, get a spoken + written reply back.

import SwiftUI
import MWDATCore

struct AskAssistantView: View {
    /// Needed only for the glasses capture path (StreamSessionViewModel drives the DAT SDK's
    /// streaming state machine that a photo capture requires). Nil on the Simulator or when the
    /// Wearables SDK didn't initialize — the iPhone-camera capture path doesn't need it at all.
    let streamViewModel: StreamSessionViewModel?

    @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
    @AppStorage(IntelligenceEngine.defaultsKey) private var intelligenceRaw = IntelligenceEngine.openai.rawValue

    @StateObject private var speechRecognizer = SpeechRecognizerOneShot.shared
    @StateObject private var speechSynthesizer = SpeechSynthesizer.shared

    @State private var questionText = ""
    @State private var attachedImage: UIImage?
    @State private var showCameraCapture = false
    @State private var isAsking = false
    @State private var isCapturingGlassesPhoto = false
    @State private var reply = ""
    @State private var errorMessage: String?

    private var captureSource: CaptureSource {
        CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera
    }
    private var engine: IntelligenceEngine {
        IntelligenceEngine(rawValue: intelligenceRaw) ?? .openai
    }
    private var canAsk: Bool {
        !isAsking && (!questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedImage != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(engine.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let attachedImage {
                        Image(uiImage: attachedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    self.attachedImage = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                        .font(.title2)
                                }
                                .padding(6)
                            }
                    }

                    if !reply.isEmpty {
                        Text(reply)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    Task { await capturePhoto() }
                } label: {
                    if isCapturingGlassesPhoto {
                        ProgressView()
                    } else {
                        Image(systemName: "camera.fill")
                    }
                }
                .disabled(isAsking || isCapturingGlassesPhoto)

                TextField("Ask something…", text: $questionText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)

                Button {
                    Task { await toggleListening() }
                } label: {
                    Image(systemName: speechRecognizer.isListening ? "mic.fill" : "mic")
                        .foregroundStyle(speechRecognizer.isListening ? .red : .primary)
                }
                .disabled(isAsking)

                Button {
                    Task { await ask() }
                } label: {
                    if isAsking {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .disabled(!canAsk)
            }
            .padding()
        }
        .sheet(isPresented: $showCameraCapture) {
            CameraCaptureView(
                onCaptured: { image in
                    attachedImage = image
                    showCameraCapture = false
                },
                onCancel: { showCameraCapture = false }
            )
            .ignoresSafeArea()
        }
        .onChange(of: speechRecognizer.transcript) { newValue in
            questionText = newValue
        }
        .onDisappear {
            speechRecognizer.stop()
            speechSynthesizer.stop()
        }
    }

    private func toggleListening() async {
        if speechRecognizer.isListening {
            speechRecognizer.stop()
            return
        }
        do {
            try await speechRecognizer.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func capturePhoto() async {
        errorMessage = nil
        switch captureSource {
        case .iPhoneCamera:
            showCameraCapture = true
        case .glasses:
            await captureGlassesPhoto()
        case .audioOnly:
            errorMessage = "No camera in Audio Only mode. Switch source in Settings to attach a photo."
        }
    }

    /// "Click and go": start the glasses stream only if it isn't already running, capture one
    /// frame, then stop it again if we're the ones who started it — mirrors OpenVision's
    /// currentGlassesImage(), the same "don't leave the camera LED on" pattern.
    private func captureGlassesPhoto() async {
        guard let streamViewModel else {
            errorMessage = "Glasses aren't available."
            return
        }
        isCapturingGlassesPhoto = true
        defer { isCapturingGlassesPhoto = false }

        let wasStreaming = streamViewModel.isStreaming
        if !wasStreaming {
            await streamViewModel.handleStartStreaming()
            for _ in 0..<40 {   // up to ~4s for the stream to actually come up
                if streamViewModel.isStreaming { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard streamViewModel.isStreaming else {
            errorMessage = "Couldn't start the glasses camera."
            return
        }

        streamViewModel.showPhotoPreview = false
        streamViewModel.capturedPhoto = nil
        streamViewModel.capturePhoto()
        for _ in 0..<50 {   // up to ~5s for a photo to arrive
            if let photo = streamViewModel.capturedPhoto {
                attachedImage = photo
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if attachedImage == nil {
            errorMessage = "Couldn't capture a photo from the glasses."
        }

        if !wasStreaming {
            await streamViewModel.stopSession()
        }
    }

    private func ask() async {
        guard let backend = DirectAIBackendRouter.backend(for: engine) else { return }
        errorMessage = nil
        reply = ""
        isAsking = true
        defer { isAsking = false }

        let text = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageData = attachedImage?.jpegData(compressionQuality: 0.85)
        do {
            let answer = try await backend.ask(text: text, imageData: imageData)
            reply = answer
            speechSynthesizer.speak(answer)
            questionText = ""
            attachedImage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
