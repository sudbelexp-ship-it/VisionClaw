// VisionClaw - AskAssistantView.swift
// Чат с выбранной моделью: GigaChat, YandexGPT или локальная FastVLM.
//
// Как работает вопрос с фотографией — это суть приложения, и раньше это было неочевидно: нажатие
// на камеру делает ОДИН снимок (с очков, если активны они, иначе с телефона), прикрепляет его к
// сообщению и отправляет вместе с текстом. Ответ приходит текстом и зачитывается вслух. Никакой
// трансляции не идёт, камера очков гаснет сразу после кадра.

import SwiftUI
import MWDATCore

struct AskAssistantView: View {
    /// Нужна только для съёмки кадра с очков. Nil на симуляторе и когда SDK не поднялся.
    let streamViewModel: StreamSessionViewModel?
    let glassesReady: Bool
    let onConnectGlasses: (() -> Void)?

    @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.automatic.rawValue
    @AppStorage(IntelligenceEngine.defaultsKey) private var intelligenceRaw = IntelligenceEngine.gigachat.rawValue

    @StateObject private var speechRecognizer = SpeechRecognizerOneShot.shared
    @StateObject private var speechSynthesizer = SpeechSynthesizer.shared
    @StateObject private var fastVLM = FastVLMService.shared
    @StateObject private var chat = ChatSession.shared

    @State private var draft = ""
    @State private var attachedImage: UIImage?
    @State private var showCameraCapture = false
    @State private var isCapturingGlassesPhoto = false
    /// Вопрос ждёт кадра с камеры телефона: снимок сделан — сразу отправляем, не заставляя
    /// нажимать «отправить» второй раз.
    @State private var sendAfterCapture = false
    @FocusState private var draftFocused: Bool

    private var engine: IntelligenceEngine {
        IntelligenceEngine(rawValue: intelligenceRaw) ?? .gigachat
    }
    private var activeSource: CaptureSource {
        (CaptureSource(rawValue: captureSourceRaw) ?? .automatic).resolved(glassesReady: glassesReady)
    }
    private var canSend: Bool {
        !chat.isAsking
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedImage != nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                composer
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { sourceButton }
                ToolbarItem(placement: .principal) { enginePicker }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(chat.messages.isEmpty)
                    .accessibilityLabel("Новый чат")
                }
            }
        }
        .sheet(isPresented: $showCameraCapture) {
            CameraCaptureView(
                onCaptured: { image in
                    attachedImage = image
                    showCameraCapture = false
                    if sendAfterCapture {
                        sendAfterCapture = false
                        Task { await send() }
                    }
                },
                onCancel: {
                    showCameraCapture = false
                    sendAfterCapture = false
                }
            )
            .ignoresSafeArea()
        }
        .onChange(of: speechRecognizer.transcript) { _, newValue in
            if !newValue.isEmpty { draft = newValue }
        }
        .onChange(of: speechRecognizer.lastError) { _, newValue in
            if let newValue { chat.append(.init(role: .failure, text: newValue)) }
        }
        // Модели не помнят реплик друг друга, поэтому оставлять чужой диалог на экране после
        // переключения значило бы обещать связность, которой нет.
        .onChange(of: intelligenceRaw) { _, _ in chat.engineChanged() }
    }

    // MARK: - Шапка

    private var enginePicker: some View {
        Menu {
            Picker("Модель", selection: $intelligenceRaw) {
                ForEach(IntelligenceEngine.allCases, id: \.rawValue) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(engine.label).font(.headline).foregroundStyle(.primary)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
        }
    }

    /// Какая камера сейчас активна — и способ сменить её одним тапом. В шапке, а не в настройках:
    /// в приложении про очки это самое полезное, что можно показать с одного взгляда.
    private var sourceButton: some View {
        Menu {
            Picker("Камера", selection: $captureSourceRaw) {
                ForEach(CaptureSource.allCases, id: \.rawValue) { source in
                    Label(source.label, systemImage: source.symbol).tag(source.rawValue)
                }
            }
            if let onConnectGlasses, !glassesReady {
                Divider()
                Button {
                    onConnectGlasses()
                } label: {
                    Label("Подключить очки", systemImage: "eyeglasses")
                }
            }
        } label: {
            Image(systemName: activeSource.symbol)
                .accessibilityLabel("Источник: \(activeSource.label)")
        }
    }

    // MARK: - Лента

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Metrics.small) {
                    if chat.messages.isEmpty && !chat.isAsking {
                        emptyState.padding(.top, 40)
                    }
                    ForEach(chat.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                    if chat.isAsking {
                        thinkingBubble.id(Self.thinkingAnchor)
                    }
                }
                .padding(.horizontal, Metrics.medium)
                .padding(.vertical, Metrics.medium)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: chat.isAsking) { _, _ in scrollToEnd(proxy) }
        }
    }

    private static let thinkingAnchor = "thinking"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if chat.isAsking {
                proxy.scrollTo(Self.thinkingAnchor, anchor: .bottom)
            } else if let last = chat.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    /// Готовые вопросы вместо пустого экрана: они заодно объясняют, что приложение умеет —
    /// раньше это приходилось угадывать.
    private static let suggestions = [
        "Что ты видишь?",
        "Прочитай текст на фото",
        "Что это за место?",
        "Переведи надпись",
    ]

    private var emptyState: some View {
        VStack(spacing: Metrics.medium) {
            Image(systemName: engine == .localMLX ? "cpu" : "sparkles")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.brand)
            VStack(spacing: Metrics.tight) {
                Text("Спросите \(engine.label)")
                    .font(.title3.weight(.semibold))
                Text(activeSource == .glasses
                     ? "Нажмите камеру — очки сделают снимок, ответ прозвучит вслух."
                     : "Нажмите камеру — телефон сделает снимок, ответ прозвучит вслух.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Metrics.large)

            FlowRow(spacing: Metrics.small) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        draft = suggestion
                        draftFocused = true
                    } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .padding(.horizontal, Metrics.medium)
                            .padding(.vertical, Metrics.small)
                            .background(Color.appSurface, in: Capsule())
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metrics.medium)
            .padding(.top, Metrics.tight)
        }
    }

    private var thinkingBubble: some View {
        HStack(spacing: Metrics.small) {
            ProgressView().controlSize(.small)
            // Ассистент очков отчитывается через ту же сессию, поэтому вопрос, заданный голосом,
            // показывает здесь свой ход, а не появляется из ниоткуда готовым ответом.
            Text(chat.activity
                 ?? (fastVLM.isLoadingModel
                     ? "Загружаю модель — первый запуск занимает минуту…"
                     : "Думаю…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Metrics.medium)
        .padding(.vertical, Metrics.small)
        .background(Color.appSurface,
                    in: RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Строка ввода

    private var composer: some View {
        VStack(spacing: Metrics.small) {
            if let attachedImage {
                attachmentChip(attachedImage)
            }

            HStack(alignment: .bottom, spacing: Metrics.small) {
                IconButton(systemName: "camera.fill",
                           isBusy: isCapturingGlassesPhoto,
                           accessibilityLabel: "Сделать снимок") {
                    Task { await capturePhoto() }
                }
                .disabled(chat.isAsking || isCapturingGlassesPhoto)

                HStack(alignment: .bottom, spacing: 4) {
                    TextField("Сообщение", text: $draft, axis: .vertical)
                        .focused($draftFocused)
                        .lineLimit(1...5)
                        .padding(.vertical, 13)
                        .padding(.leading, Metrics.medium)

                    IconButton(systemName: speechRecognizer.isListening ? "waveform" : "mic.fill",
                               tint: speechRecognizer.isListening ? .red : .secondary,
                               background: .clear,
                               size: 40,
                               accessibilityLabel: speechRecognizer.isListening ? "Остановить" : "Голосом") {
                        Task { await toggleListening() }
                    }
                    .disabled(chat.isAsking)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                }
                .background(Color.appSurface,
                            in: RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous))

                IconButton(systemName: "arrow.up",
                           tint: .white,
                           background: canSend ? .brand : .appSurface,
                           isBusy: chat.isAsking,
                           accessibilityLabel: "Отправить") {
                    Task { await send() }
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, Metrics.medium)
        .padding(.vertical, Metrics.small)
        .background(.bar)
    }

    /// Миниатюра над полем, как в любом мессенджере — прежний предпросмотр во всю ширину
    /// выталкивал разговор за экран.
    private func attachmentChip(_ image: UIImage) -> some View {
        HStack {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button {
                    attachedImage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .offset(x: 7, y: -7)
            }
            .padding(.top, Metrics.tight)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Действия

    private func newChat() {
        speechSynthesizer.stop()
        chat.persist()
        chat.newChat()
        attachedImage = nil
        draft = ""
    }

    private func toggleListening() async {
        if speechRecognizer.isListening {
            speechRecognizer.stop()
            return
        }
        // Ответ читается вслух, и синтезатор держит аудиосессию, пока говорит. Перенастраивать её
        // под запись прямо под ним нельзя — микрофон просто не включался.
        speechSynthesizer.stop()
        draftFocused = false
        do {
            try await speechRecognizer.start()
        } catch {
            chat.append(.init(role: .failure, text: error.localizedDescription))
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

    private func captureGlassesPhoto() async {
        guard let streamViewModel else {
            chat.append(.init(role: .failure, text: "Очки на этом устройстве недоступны."))
            return
        }
        isCapturingGlassesPhoto = true
        defer { isCapturingGlassesPhoto = false }

        if let photo = await GlassesCamera.singleFrame(from: streamViewModel) {
            attachedImage = photo
        } else {
            chat.append(.init(role: .failure,
                              text: "Не удалось снять кадр с очков. Они включены и разложены?"))
        }
    }

    private func send() async {
        guard canSend else { return }
        speechRecognizer.stop()

        // Вопрос про то, что перед глазами, без приложенного кадра — снимаем сами. Раньше он
        // уходил голым текстом, и модель справедливо отвечала, что ничего не видит; выглядело это
        // как сломанное зрение, а не как недостающий снимок.
        if attachedImage == nil, VisionIntent.needsPhoto(draft) {
            switch activeSource {
            case .glasses:
                await captureGlassesPhoto()
            case .iPhoneCamera, .automatic:
                // Камеру телефона нельзя открыть без участия человека, поэтому показываем её и
                // отправляем сразу после кадра.
                sendAfterCapture = true
                showCameraCapture = true
                return
            }
        }

        let text = draft
        let image = attachedImage
        // Поле очищается сразу: раньше вопрос висел в нём до прихода ответа, и это читалось как
        // «кнопка не сработала».
        draft = ""
        attachedImage = nil

        if let answer = await chat.ask(text: text, image: image) {
            speechSynthesizer.speak(answer)
        }
    }
}

// MARK: - Реплика

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }

            VStack(alignment: .leading, spacing: Metrics.small) {
                if let image = message.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 230, maxHeight: 230)
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
            .padding(.horizontal, Metrics.medium)
            .padding(.vertical, Metrics.small)
            .foregroundStyle(foreground)
            .background(background,
                        in: RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous))

            if message.role != .user { Spacer(minLength: 48) }
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
        case .user: return .brand
        case .assistant: return .appSurface
        case .failure: return .orange.opacity(0.15)
        }
    }
}

/// Chips that wrap onto the next line. SwiftUI has no such stack of its own, and an HStack would
/// push the last suggestion off the edge of a narrow phone.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
