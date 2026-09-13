// VisionClaw - LiveSession.swift
// Эфир: камера очков не выключается, и разговор идёт про то, что вы видите прямо сейчас.
//
// Почему не «настоящий» realtime, как в Gemini Live
// ------------------------------------------------
// AI-Smart-Glasses, на которое мы смотрели, держит WebSocket к Gemini Live и гонит туда ~1 кадр в
// секунду вместе со звуком в обе стороны. Это хорошо работает и требует ключа Gemini — ровно того
// пути, который здесь вырезан, потому что доступа к нему нет.
//
// Замена не хуже по ощущению: камера просто не выключается, свежий кадр всегда под рукой, и вопрос
// отвечается по нему без паузы на съёмку. Снаружи разницы почти нет — исчезает только возможность
// перебить модель на полуслове.
//
// Режим — это промпт и три флага. Добавить новый (переводчик вывесок, поиск предмета, что угодно)
// значит дописать один case.

import AVFoundation
import Foundation
import SwiftUI
import UIKit

enum LiveMode: String, CaseIterable, Identifiable {
    case conversation
    case guide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .conversation: return "Обычный"
        case .guide: return "Гид"
        }
    }

    var blurb: String {
        switch self {
        case .conversation:
            return "Спрашивайте вслух о том, что перед вами. Сам ничего не говорит."
        case .guide:
            return "Сам рассказывает про то, на что вы смотрите, и отвечает на вопросы."
        }
    }

    /// Рассказывает ли сам, без вопроса.
    var narratesOnItsOwn: Bool { self == .guide }
}

struct LiveEntry: Identifiable, Equatable {
    enum Kind { case question, answer, narration, failure }
    let id = UUID()
    let kind: Kind
    let text: String
    let image: UIImage?
    /// Имя файла в папке истории, присваивается один раз при создании реплики. Без этого каждое
    /// сохранение писало бы ту же картинку заново под новым именем, и лимит размера истории
    /// выбирался бы дубликатами, а не разговорами.
    var imageFile: String?
}

@MainActor
final class LiveSession: ObservableObject {
    static let shared = LiveSession()
    private init() {}

    @Published private(set) var isRunning = false
    @Published private(set) var entries: [LiveEntry] = []
    @Published private(set) var status: String?
    @Published var errorText: String?
    /// Сколько кадров ушло в модель за сеанс. На экране — чтобы расход не был сюрпризом.
    @Published private(set) var framesSent = 0
    /// Слышит ли сейчас микрофон. Выключается, пока говорит сам.
    @Published private(set) var isListening = false

    let frames = LiveFrameBuffer()

    @AppStorage(LiveSession.modeKey) var modeRaw = LiveMode.conversation.rawValue
    static let modeKey = "liveMode"
    var mode: LiveMode { LiveMode(rawValue: modeRaw) ?? .conversation }

    /// Не чаще одного рассказа в 15 секунд, и только если сцена сменилась. Подобрано под музей:
    /// подошёл к экспонату, остановился — услышал; стоишь на месте — молчит.
    var narrationInterval: TimeInterval = 15

    private weak var streamViewModel: StreamSessionViewModel?
    private var listener: AudioCaptureHub.Listener?
    private var guideTimer: Timer?
    private var isBusy = false
    private var lastNarration = Date.distantPast
    private var sessionId = UUID()

    // Накопление вопроса по паузе, как в переводчике: распознаватель не даёт времени,
    // поэтому тишина считается по громкости буферов.
    private var pendingWords: [String] = []
    private var consumedPrefix = 0
    private var silenceSeconds: Double = 0
    private var heardSpeech = false
    private var noiseFloor: Float = 0.01
    private let pauseSeconds: Double = 0.8

    // MARK: Запуск

    func start(streamViewModel: StreamSessionViewModel?) async {
        guard !isRunning else { return }
        errorText = nil
        self.streamViewModel = streamViewModel
        sessionId = UUID()
        frames.reset()
        framesSent = 0

        guard let streamViewModel else {
            errorText = "Очки на этом устройстве недоступны."
            return
        }

        status = "Запускаю камеру очков…"
        if !streamViewModel.isStreaming {
            await streamViewModel.handleStartStreaming()
            for _ in 0..<40 {
                if streamViewModel.isStreaming { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard streamViewModel.isStreaming else {
            errorText = "Не удалось запустить камеру очков. Они включены и разложены?"
            status = nil
            return
        }

        streamViewModel.onDecodedFrame = { [weak self] pixelBuffer in
            self?.frames.ingest(pixelBuffer)
        }

        do {
            listener = try AudioCaptureHub.shared.addListener(
                locale: SpeechRecognizerOneShot.activeLocale(),
                onTranscript: { [weak self] text, isFinal in self?.ingest(text, isFinal: isFinal) },
                onLevel: { [weak self] rms, seconds in self?.observeLevel(rms, seconds: seconds) })
            isListening = true
        } catch {
            // Без микрофона эфир всё ещё полезен в режиме гида, поэтому это не фатально.
            errorText = error.localizedDescription
            isListening = false
        }

        if mode.narratesOnItsOwn { startGuideTimer() }
        isRunning = true
        status = mode.narratesOnItsOwn ? "Смотрю по сторонам" : "Слушаю"
    }

    func stop() {
        guideTimer?.invalidate()
        guideTimer = nil
        AudioCaptureHub.shared.removeListener(listener)
        listener = nil
        isListening = false
        streamViewModel?.onDecodedFrame = nil
        SpeechSynthesizer.shared.stop()
        Task { [weak streamViewModel] in
            await streamViewModel?.stopSession()
        }
        persist()
        isRunning = false
        status = nil
        frames.reset()
    }

    func clear() {
        persist()
        entries.removeAll()
        sessionId = UUID()
        framesSent = 0
    }

    /// Смена режима на лету: таймер гида появляется и исчезает вместе с режимом.
    func modeChanged() {
        guard isRunning else { return }
        guideTimer?.invalidate()
        guideTimer = nil
        if mode.narratesOnItsOwn { startGuideTimer() }
        status = mode.narratesOnItsOwn ? "Смотрю по сторонам" : "Слушаю"
    }

    // MARK: Речь

    private func observeLevel(_ rms: Float, seconds: Double) {
        // Пока говорим сами, микрофон не слушаем: иначе гид услышит себя, посчитает это вопросом
        // и ответит сам себе — ровно та петля, что была с Gemma 3 в OpenVision.
        guard !SpeechSynthesizer.shared.isSpeaking, !isBusy else {
            silenceSeconds = 0
            heardSpeech = false
            return
        }
        noiseFloor = rms < noiseFloor ? (noiseFloor * 0.9 + rms * 0.1) : (noiseFloor * 0.999 + rms * 0.001)
        if rms > max(noiseFloor * 2.5, 0.008) {
            silenceSeconds = 0
            heardSpeech = true
        } else {
            silenceSeconds += seconds
            if heardSpeech, silenceSeconds >= pauseSeconds {
                flushQuestion()
            }
        }
    }

    private func ingest(_ transcript: String, isFinal: Bool) {
        guard !SpeechSynthesizer.shared.isSpeaking, !isBusy else { return }
        let words = transcript.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return }
        pendingWords = Array(words.dropFirst(min(consumedPrefix, words.count)))
        if isFinal { flushQuestion(totalWords: words.count) }
    }

    private func flushQuestion(totalWords: Int? = nil) {
        heardSpeech = false
        silenceSeconds = 0
        let question = pendingWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        pendingWords = []
        if let totalWords { consumedPrefix = totalWords } else { consumedPrefix += question.split(separator: " ").count }
        // Одно-два слова — почти всегда обрывок чужой фразы или шум, а не вопрос.
        guard question.split(separator: " ").count >= 2 else { return }
        Task { await answer(question: question) }
    }

    // MARK: Ответы

    private func answer(question: String) async {
        guard !isBusy, let image = frames.latest else { return }
        isBusy = true
        defer { isBusy = false; status = mode.narratesOnItsOwn ? "Смотрю по сторонам" : "Слушаю" }

        entries.append(LiveEntry(kind: .question, text: question, image: nil))
        status = "Думаю…"

        let prompt = """
            Человек смотрит на это через камеру очков и спрашивает: «\(question)»
            Если в кадре видна рука или палец — отвечай про предмет, на который указывают.
            Ответь одним-двумя предложениями, разговорно, без списков и заголовков: ответ читается вслух.
            """
        await send(prompt: prompt, image: image, kind: .answer)
    }

    private func startGuideTimer() {
        guideTimer?.invalidate()
        // Раз в секунду проверяем условия — сама отправка происходит гораздо реже.
        guideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.guideTick() }
        }
    }

    private func guideTick() async {
        guard isRunning, mode.narratesOnItsOwn, !isBusy,
              !SpeechSynthesizer.shared.isSpeaking,
              Date().timeIntervalSince(lastNarration) >= narrationInterval,
              frames.isSteady, frames.hasChangedSinceSent,
              let image = frames.latest
        else { return }

        isBusy = true
        lastNarration = Date()
        defer { isBusy = false; status = "Смотрю по сторонам" }
        status = "Разглядываю…"

        // Уже рассказанное передаётся, чтобы гид не пересказывал одно и то же на каждом кругу.
        let told = entries.filter { $0.kind == .narration }.suffix(4).map(\.text)
        var prompt = """
            Ты гид. Перед человеком — то, что на снимке. Расскажи ОДИН короткий интересный факт о \
            самом заметном предмете: что это, чем примечательно. Одно-два предложения, разговорно, \
            без списков — текст читается вслух.
            """
        if !told.isEmpty {
            prompt += "\n\nПро это ты уже рассказывал, не повторяйся:\n" + told.joined(separator: "\n")
        }
        // Пустая стена не заслуживает рассказа, и притворяться, что заслуживает, хуже молчания.
        prompt += "\n\nЕсли в кадре нет ничего примечательного, ответь ровно одним словом: пропустить"

        await send(prompt: prompt, image: image, kind: .narration)
    }

    private func send(prompt: String, image: UIImage, kind: LiveEntry.Kind) async {
        frames.markSent()
        framesSent += 1

        let engine = IntelligenceEngine(
            rawValue: UserDefaults.standard.string(forKey: IntelligenceEngine.defaultsKey) ?? "") ?? .gigachat
        let backend = DirectAIBackendRouter.backend(for: engine)
        // Предыдущие реплики как контекст — без них «а это что?» не к чему привязать.
        let history = entries.suffix(6).compactMap { entry -> ChatTurn? in
            switch entry.kind {
            case .question: return ChatTurn(role: .user, text: entry.text)
            case .answer, .narration: return ChatTurn(role: .assistant, text: entry.text)
            case .failure: return nil
            }
        }

        do {
            let answer = try await backend.ask(
                text: prompt,
                imageData: image.jpegData(compressionQuality: 0.6),
                history: Array(history))
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let skipped = trimmed.lowercased().hasPrefix("пропустить") || trimmed.lowercased().hasPrefix("skip")
            guard !skipped, !trimmed.isEmpty else { return }
            let keptImage = kind == .narration ? image : nil
            let file = keptImage.flatMap { ConversationStore.shared.storeImage($0, session: sessionId) }
            entries.append(LiveEntry(kind: kind, text: trimmed, image: keptImage, imageFile: file))
            SpeechSynthesizer.shared.speak(trimmed)
            persist()
        } catch {
            entries.append(LiveEntry(kind: .failure, text: error.localizedDescription, image: nil))
        }
    }

    // MARK: История

    private func persist() {
        guard !entries.isEmpty else { return }
        let messages: [StoredMessage] = entries.map { entry in
            let role: StoredMessage.Role
            switch entry.kind {
            case .question: role = .user
            case .answer, .narration: role = .assistant
            case .failure: role = .note
            }
            return StoredMessage(role: role, text: entry.text, imageFile: entry.imageFile)
        }
        ConversationStore.shared.save(id: sessionId, kind: .live,
                                      subtitle: "Эфир · \(mode.label)", messages: messages)
    }
}
