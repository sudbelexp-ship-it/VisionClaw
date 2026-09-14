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
    /// Если смена сцены так и не обнаружена, гид всё равно пробует раз в столько секунд, а не
    /// молчит бесконечно. LiveFrameBuffer сравнивает яркость 32x32-отпечатка: в тёмной комнате
    /// или перед почти однотонным фоном эта разница может не превысить порог даже когда предмет
    /// перед камерой на самом деле другой — отличить "то же самое" от "просто темно" по одной
    /// яркости нельзя. Повтор одного и того же прикрывает сам промпт (список "уже рассказано" и
    /// слово "пропустить"), а не пиксельная эвристика.
    private static let forcedNarrationInterval: TimeInterval = 45

    /// Сколько ждать после ответа на вопрос, прежде чем гид сам возьмёт слово снова. Без этой
    /// паузы 15-секундный интервал рассказа мог истечь ровно во время разговора и перебить
    /// человека на середине уточняющего вопроса.
    private static let postAnswerQuietPeriod: TimeInterval = 8
    /// Не чаще одного захвата по пальцу в столько секунд — иначе продолжающий указывать палец
    /// переспрашивал бы об одном и том же на каждом тике.
    private static let pointingCooldown: TimeInterval = 6

    private weak var streamViewModel: StreamSessionViewModel?
    private var listener: AudioCaptureHub.Listener?
    private var ticker: Timer?
    private var isBusy = false
    private var lastNarration = Date.distantPast
    private var quietUntil = Date.distantPast
    private var wasPointing = false
    private var lastPointingTrigger = Date.distantPast
    private var sessionId = UUID()


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
        // .streaming specifically, not the looser isStreaming (`!= .stopped`, true for `.waiting`
        // too): `.waiting` is the state right after session.start() is called, well before `camera`
        // exists and frames start arriving. Gating on the loose check let onDecodedFrame get wired
        // up before there was anything to decode, which is indistinguishable from "camera never
        // came up" from here -- same race GlassesCamera.singleFrame had for photo capture.
        if streamViewModel.streamingStatus != .streaming {
            await streamViewModel.handleStartStreaming()
            for _ in 0..<40 {
                if streamViewModel.streamingStatus == .streaming { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard streamViewModel.streamingStatus == .streaming else {
            errorText = "Не удалось запустить камеру очков. Они включены и разложены?"
            status = nil
            return
        }

        streamViewModel.onDecodedFrame = { [weak self] pixelBuffer in
            self?.frames.ingest(pixelBuffer)
        }

        do {
            // Границу вопроса проводит сама модель распознавания: закреплённый результат и есть
            // законченная фраза. Своя нарезка по громкости и индексам больше не нужна.
            listener = try await AudioCaptureHub.shared.addListener(
                locale: SpeechRecognizerOneShot.activeLocale(),
                onFinal: { [weak self] text in self?.acceptQuestion(text) })
            isListening = true
        } catch {
            // Без микрофона эфир всё ещё полезен в режиме гида, поэтому это не фатально.
            errorText = error.localizedDescription
            isListening = false
        }

        startTicker()
        isRunning = true
        status = mode.narratesOnItsOwn ? "Смотрю по сторонам" : "Слушаю"
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
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

    /// Смена режима на лету. Тикер один на оба режима теперь (гид и пальцем-показ), перезапускать
    /// его не нужно — меняется только то, что он проверяет на каждом тике.
    func modeChanged() {
        guard isRunning else { return }
        status = mode.narratesOnItsOwn ? "Смотрю по сторонам" : "Слушаю"
    }

    // MARK: Речь

    /// Слова, после которых гид возобновляет рассказ немедленно, не дожидаясь paused-периода.
    /// Не вопрос вообще, поэтому проверяется раньше счётчика слов и не идёт в answer().
    private static let resumePhrases = [
        "продолжи", "продолжай", "продолжи рассказ", "продолжи экскурсию", "давай дальше",
    ]

    /// Пришла законченная фраза. Пока говорим сами — пропускаем: иначе гид услышит себя, посчитает
    /// это вопросом и ответит сам себе.
    private func acceptQuestion(_ text: String) {
        guard !SpeechSynthesizer.shared.isSpeaking, !isBusy else { return }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = GlassesAssistant.normalize(question)
        if Self.resumePhrases.contains(normalized) {
            quietUntil = .distantPast
            return
        }
        // Одно-два слова — почти всегда обрывок чужой фразы или шум, а не вопрос.
        guard question.split(separator: " ").count >= 2 else { return }
        Task { await answer(question: question) }
    }

    // MARK: Ответы

    private func answer(question: String) async {
        guard !isBusy, let image = frames.latest else { return }
        isBusy = true
        defer {
            isBusy = false
            status = mode.narratesOnItsOwn ? "Смотрю по сторонам" : "Слушаю"
            // Ответив, гид ненадолго придерживает свой собственный рассказ: 15-секундный интервал
            // мог истечь прямо посреди разговора, и без этой паузы гид перебил бы уточняющий
            // вопрос собственной репликой. "Продолжи" (см. acceptQuestion) снимает паузу раньше.
            quietUntil = Date().addingTimeInterval(Self.postAnswerQuietPeriod)
        }

        entries.append(LiveEntry(kind: .question, text: question, image: nil))
        status = "Думаю…"

        let prompt = """
            Человек смотрит на это через камеру очков и спрашивает: «\(question)»
            Если в кадре видна рука или палец — отвечай про предмет, на который указывают.
            Ответь одним-двумя предложениями, разговорно, без списков и заголовков: ответ читается вслух.
            """
        await send(prompt: prompt, image: image, kind: .answer)
    }

    private func startTicker() {
        ticker?.invalidate()
        // Раз в секунду проверяем условия и для рассказа гида, и для показа пальцем — сама отправка
        // происходит гораздо реже.
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.mode.narratesOnItsOwn { await self.guideTick() }
                await self.pointingTick()
            }
        }
    }

    private func guideTick() async {
        guard isRunning, mode.narratesOnItsOwn, !isBusy,
              !SpeechSynthesizer.shared.isSpeaking, Date() >= quietUntil,
              frames.isSteady, let image = frames.latest
        else { return }
        let sinceLastNarration = Date().timeIntervalSince(lastNarration)
        guard sinceLastNarration >= narrationInterval else { return }
        guard frames.hasChangedSinceSent || sinceLastNarration >= Self.forcedNarrationInterval
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

    /// A finger held up in frame is a question in itself -- see LiveFrameBuffer.isPointing for the
    /// detector. Edge-triggered, not level-triggered: firing again on every tick while the finger
    /// stays in view would ask about the same thing on a loop for as long as it's held there.
    private func pointingTick() async {
        let pointingNow = frames.isPointing
        defer { wasPointing = pointingNow }
        guard isRunning, !isBusy, !SpeechSynthesizer.shared.isSpeaking, Date() >= quietUntil,
              pointingNow, !wasPointing,
              Date().timeIntervalSince(lastPointingTrigger) >= Self.pointingCooldown,
              let image = frames.latest
        else { return }
        lastPointingTrigger = Date()

        isBusy = true
        defer {
            isBusy = false
            status = mode.narratesOnItsOwn ? "Смотрю по сторонам" : "Слушаю"
            quietUntil = Date().addingTimeInterval(Self.postAnswerQuietPeriod)
        }
        status = "Вижу палец…"
        entries.append(LiveEntry(kind: .question, text: "👉 показал пальцем", image: nil))

        let prompt = """
            Человек указывает пальцем в кадре камеры очков. Назови и коротко опиши именно то, на \
            что указывает палец, а не всю сцену целиком. Одно-два предложения, разговорно, без \
            списков и заголовков: ответ читается вслух.
            """
        await send(prompt: prompt, image: image, kind: .answer)
    }

    private func send(prompt: String, image: UIImage, kind: LiveEntry.Kind) async {
        frames.markSent()
        framesSent += 1

        let engine = IntelligenceEngine(
            rawValue: UserDefaults.standard.string(forKey: IntelligenceEngine.defaultsKey) ?? "") ?? .gigachat
        let backend = DirectAIBackendRouter.backend(for: engine)
        // Контекст нужен вопросам — без него «а это что?» не к чему привязать. Рассказу гида он
        // вреден: модель, видящая собственный предыдущий ответ, охотно повторяет его на новой
        // картинке. Запрет на повтор остаётся в самом промпте списком «уже рассказано».
        let history: [ChatTurn] = kind == .narration ? [] : entries.suffix(6).compactMap { entry in
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
                history: history)
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
