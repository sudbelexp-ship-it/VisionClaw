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
    @StateObject private var fastVLM = FastVLMService.shared

    @State private var questionText = ""
    @State private var attachedImage: UIImage?
    @State private var showCameraCapture = false
    @State private var isAsking = false
    @State private var isCapturingGlassesPhoto = false
    @State private var reply = ""
    @State private var errorMessage: String?
    @State private var showSettings = false

    private var captureSource: CaptureSource {
        CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera
    }
    private var engine: IntelligenceEngine {
        IntelligenceEngine(rawValue: intelligenceRaw) ?? .openai
    }
    private var canAsk: Bool {
        !isAsking && (!questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedImage != nil)
    }
    /// Every direct engine (see IntelligenceEngine.isDirect) -- what the top-bar switcher offers.
    /// Never openai/gemini: picking either of those from here would need to also hand up the
    /// LiveKit call, which this screen has no connection to at all.
    private var directEngines: [IntelligenceEngine] {
        IntelligenceEngine.allCases.filter(\.isDirect)
    }

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {
                topBar

                if reply.isEmpty && errorMessage == nil && attachedImage == nil && !isAsking {
                    emptyState
                    Spacer()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
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

                            if isAsking {
                                HStack(spacing: 10) {
                                    ProgressView().tint(.white)
                                    // First question on the local model spends tens of seconds
                                    // parsing weights and compiling Metal shaders before any
                                    // generation starts -- say so, or it reads as a hang.
                                    Text(fastVLM.isLoadingModel
                                         ? "Loading the model into memory — first run takes a minute…"
                                         : "Thinking…")
                                        .font(.subheadline)
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            if !reply.isEmpty {
                                Text(reply)
                                    .font(.body)
                                    .foregroundStyle(.white)
                                    .textSelection(.enabled)
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                            }

                            if let errorMessage {
                                errorCard(errorMessage)
                            }
                        }
                        .padding()
                    }
                }

                inputBar
            }
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
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onChange(of: speechRecognizer.transcript) { newValue in
            questionText = newValue
        }
        // A dictation attempt that produced nothing used to end in silence — red mic off, empty
        // field, no explanation. The recognizer now says which of the distinct failures happened.
        .onChange(of: speechRecognizer.lastError) { newValue in
            if let newValue { errorMessage = newValue }
        }
        .onDisappear {
            speechRecognizer.stop()
            speechSynthesizer.stop()
        }
    }

    // MARK: - Chrome

    /// Same placement/style as the gear button on the LiveKit call screen (LiveKitStreamView) --
    /// this screen replaces that one for a direct engine, so it needs the same way back to
    /// Settings. The engine name doubles as a menu so switching backends doesn't require a trip
    /// through Settings at all.
    private var topBar: some View {
        HStack {
            Menu {
                ForEach(directEngines, id: \.rawValue) { option in
                    Button {
                        intelligenceRaw = option.rawValue
                    } label: {
                        if option == engine {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(engine.label)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.white.opacity(0.15), in: Capsule())
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(10)
                    .background(.black.opacity(0.35), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: engine == .localMLX ? "cpu" : "text.bubble")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.4))
            Text("Ask \(engine.label) something")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.8))
            Text("Type below, tap the mic to speak, or attach a photo first.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await capturePhoto() }
            } label: {
                if isCapturingGlassesPhoto {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "camera.fill")
                }
            }
            .disabled(isAsking || isCapturingGlassesPhoto)

            TextField("", text: $questionText, prompt: Text("Ask something…").foregroundStyle(.white.opacity(0.4)), axis: .vertical)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                .lineLimit(1...4)

            Button {
                Task { await toggleListening() }
            } label: {
                Image(systemName: speechRecognizer.isListening ? "mic.fill" : "mic")
                    .foregroundStyle(speechRecognizer.isListening ? .red : .white)
            }
            .disabled(isAsking)

            Button {
                Task { await ask() }
            } label: {
                if isAsking {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canAsk ? .white : .white.opacity(0.3))
                }
            }
            .disabled(!canAsk)
        }
        .font(.system(size: 18))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.4))
    }

    // MARK: - Actions

    private func toggleListening() async {
        if speechRecognizer.isListening {
            speechRecognizer.stop()
            return
        }
        errorMessage = nil
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
