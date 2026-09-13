// VisionClaw - AskAssistantView.swift
// The app's only screen: a chat with whichever engine is selected (GigaChat, YandexGPT, or the
// on-device FastVLM model -- see DirectAIBackend.swift).
//
// How a question with a photo works, since it is the whole point of the app and was not obvious:
// tapping the camera takes ONE still frame -- from the glasses if they're the active source, from
// the phone otherwise -- attaches it to the message you're writing, and sends both together. The
// answer comes back as text and is spoken aloud. Nothing is streamed anywhere and the glasses
// camera is switched off again the moment the frame is in hand.

import SwiftUI
import MWDATCore

/// One turn in the transcript. Photos live on the message that carried them, so scrolling back
/// shows what was actually asked about rather than just the words.
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, failure }

    let id = UUID()
    let role: Role
    var text: String
    var image: UIImage?

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool { lhs.id == rhs.id }
}

struct AskAssistantView: View {
    /// Drives the DAT SDK; needed only to grab a glasses frame. Nil on the Simulator or when the
    /// Wearables SDK didn't initialize.
    let streamViewModel: StreamSessionViewModel?
    /// Whether the glasses are paired and usable, which is what "Automatic" keys off.
    let glassesReady: Bool
    /// Opens the pairing flow. Nil when there is no wearables stack to pair with at all.
    let onConnectGlasses: (() -> Void)?

    @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.automatic.rawValue
    @AppStorage(IntelligenceEngine.defaultsKey) private var intelligenceRaw = IntelligenceEngine.gigachat.rawValue

    @StateObject private var speechRecognizer = SpeechRecognizerOneShot.shared
    @StateObject private var speechSynthesizer = SpeechSynthesizer.shared
    @StateObject private var fastVLM = FastVLMService.shared

    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var attachedImage: UIImage?
    @State private var showCameraCapture = false
    @State private var isAsking = false
    @State private var isCapturingGlassesPhoto = false
    @State private var showSettings = false
    @FocusState private var draftFocused: Bool

    private var engine: IntelligenceEngine {
        IntelligenceEngine(rawValue: intelligenceRaw) ?? .gigachat
    }
    private var sourcePreference: CaptureSource {
        CaptureSource(rawValue: captureSourceRaw) ?? .automatic
    }
    /// Where a photo would come from if the camera were tapped right now.
    private var activeSource: CaptureSource {
        sourcePreference.resolved(glassesReady: glassesReady)
    }
    private var canSend: Bool {
        !isAsking && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedImage != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            transcript
            composer
        }
        .background(Color.appBackground.ignoresSafeArea())
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
            if !newValue.isEmpty { draft = newValue }
        }
        .onChange(of: speechRecognizer.lastError) { newValue in
            if let newValue { append(.init(role: .failure, text: newValue)) }
        }
        // Each engine answers on its own, with no memory of the others' turns -- so leaving the
        // previous conversation on screen after a switch implied a continuity that does not exist.
        .onChange(of: intelligenceRaw) { _ in newChat() }
        .onDisappear {
            speechRecognizer.stop()
            speechSynthesizer.stop()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            sourceButton

            Spacer(minLength: 4)

            Menu {
                Picker("Engine", selection: $intelligenceRaw) {
                    ForEach(IntelligenceEngine.allCases, id: \.rawValue) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(engine.label)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            Menu {
                Button {
                    newChat()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .disabled(messages.isEmpty)

                if let onConnectGlasses {
                    Button {
                        onConnectGlasses()
                    } label: {
                        Label(glassesReady ? "Glasses" : "Connect glasses", systemImage: "eyeglasses")
                    }
                }

                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Which camera is live, and a one-tap way to change it. In the header rather than buried in
    /// Settings because on a glasses app it is the single most useful thing to see at a glance.
    private var sourceButton: some View {
        Menu {
            Picker("Camera", selection: $captureSourceRaw) {
                ForEach(CaptureSource.allCases, id: \.rawValue) { source in
                    Label(source.label, systemImage: source.symbol).tag(source.rawValue)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: activeSource.symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(activeSource.label)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.appSurface, in: Capsule())
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if messages.isEmpty && !isAsking {
                        emptyState.padding(.top, 60)
                    }
                    ForEach(messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                    if isAsking {
                        thinkingBubble.id(Self.thinkingAnchor)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _ in scrollToEnd(proxy) }
            .onChange(of: isAsking) { _ in scrollToEnd(proxy) }
        }
    }

    private static let thinkingAnchor = "thinking"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if isAsking {
                proxy.scrollTo(Self.thinkingAnchor, anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: engine == .localMLX ? "cpu" : "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Ask \(engine.label)")
                .font(.title3.weight(.semibold))
            Text("Type a question, hold the mic to speak, or tap the camera to ask about what "
                 + "\(activeSource == .glasses ? "your glasses see" : "your phone sees").")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var thinkingBubble: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            // The local model spends tens of seconds parsing weights and compiling Metal shaders
            // before the first token -- say so, or it reads as a hang.
            Text(fastVLM.isLoadingModel ? "Loading the model — the first run takes a minute…" : "Thinking…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if let attachedImage {
                attachmentChip(attachedImage)
            }

            HStack(alignment: .bottom, spacing: 8) {
                CircleButton(
                    systemName: "camera.fill",
                    isBusy: isCapturingGlassesPhoto,
                    accessibilityLabel: "Take a photo"
                ) {
                    Task { await capturePhoto() }
                }
                .disabled(isAsking || isCapturingGlassesPhoto)

                HStack(alignment: .bottom, spacing: 6) {
                    TextField("Message", text: $draft, axis: .vertical)
                        .focused($draftFocused)
                        .lineLimit(1...5)
                        .padding(.vertical, 8)
                        .padding(.leading, 14)

                    CircleButton(
                        systemName: speechRecognizer.isListening ? "waveform" : "mic.fill",
                        tint: speechRecognizer.isListening ? .red : .secondary,
                        filled: false,
                        accessibilityLabel: speechRecognizer.isListening ? "Stop dictating" : "Dictate"
                    ) {
                        Task { await toggleListening() }
                    }
                    .disabled(isAsking)
                    .padding(.trailing, 4)
                    .padding(.bottom, 2)
                }
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                CircleButton(
                    systemName: "arrow.up",
                    tint: .white,
                    background: canSend ? Color.accentColor : Color.appSurface,
                    isBusy: isAsking,
                    accessibilityLabel: "Send"
                ) {
                    Task { await send() }
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    /// The pending photo as a small thumbnail above the field, the way every messaging app does
    /// it -- the previous full-width preview pushed the conversation off screen.
    private func attachmentChip(_ image: UIImage) -> some View {
        HStack {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button {
                    attachedImage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .offset(x: 6, y: -6)
            }
            .padding(.top, 6)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Actions

    private func newChat() {
        speechSynthesizer.stop()
        messages.removeAll()
        attachedImage = nil
        draft = ""
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
    }

    private func toggleListening() async {
        if speechRecognizer.isListening {
            speechRecognizer.stop()
            return
        }
        // The answer is spoken aloud and AVSpeechSynthesizer holds the audio session while it
        // talks; reconfiguring that session for capture underneath it fails silently.
        speechSynthesizer.stop()
        draftFocused = false
        do {
            try await speechRecognizer.start()
        } catch {
            append(.init(role: .failure, text: error.localizedDescription))
        }
    }

    private func capturePhoto() async {
        switch activeSource {
        case .iPhoneCamera, .automatic:
            showCameraCapture = true
        case .glasses:
            await captureGlassesPhoto()
        }
    }

    /// "Click and go": start the glasses stream only if it isn't already running, take one frame,
    /// then stop it again if we were the ones who started it -- so the camera light never stays on
    /// longer than the shot needs.
    private func captureGlassesPhoto() async {
        guard let streamViewModel else {
            append(.init(role: .failure, text: "Glasses aren't available on this device."))
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
            append(.init(role: .failure, text: "Couldn't start the glasses camera. Are they on and unfolded?"))
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
            append(.init(role: .failure, text: "Couldn't capture a photo from the glasses."))
        }

        if !wasStreaming {
            await streamViewModel.stopSession()
        }
    }

    private func send() async {
        guard canSend else { return }
        speechRecognizer.stop()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = attachedImage

        // Post the question before the request starts. It used to sit in the input field until
        // the answer arrived, which looked like the send button had not registered at all.
        append(.init(role: .user, text: text, image: image))
        draft = ""
        attachedImage = nil

        isAsking = true
        defer { isAsking = false }

        let backend = DirectAIBackendRouter.backend(for: engine)
        do {
            let answer = try await backend.ask(text: text, imageData: image?.jpegData(compressionQuality: 0.85))
            append(.init(role: .assistant, text: answer))
            speechSynthesizer.speak(answer)
        } catch {
            append(.init(role: .failure, text: error.localizedDescription))
        }
    }
}

// MARK: - Pieces

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 8) {
                if let image = message.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if !message.text.isEmpty {
                    if message.role == .failure {
                        Label(message.text, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                    } else {
                        Text(message.text)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var foreground: Color {
        switch message.role {
        case .user: return .white
        case .assistant: return .primary
        case .failure: return .orange
        }
    }

    private var background: Color {
        switch message.role {
        case .user: return .accentColor
        case .assistant: return .appSurface
        case .failure: return .orange.opacity(0.15)
        }
    }
}

/// One consistent tap target for every control on the composer. They were previously bare glyphs
/// of assorted sizes sitting directly on the background, which is what made the bottom bar look
/// unfinished and made the small ones awkward to hit.
private struct CircleButton: View {
    let systemName: String
    var tint: Color = .secondary
    var background: Color = .clear
    var filled: Bool = true
    var isBusy: Bool = false
    var accessibilityLabel: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                if filled {
                    Circle().fill(background == .clear ? Color.appSurface : background)
                }
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 38, height: 38)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

extension Color {
    /// One surface colour for bubbles, chips and buttons, so the screen reads as a single design
    /// rather than a pile of one-off opacities. Both adapt to light and dark automatically.
    static let appSurface = Color(uiColor: .secondarySystemBackground)
    static let appBackground = Color(uiColor: .systemBackground)
}
