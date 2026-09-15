// VisionClaw - GlassesAssistant.swift
// Hands-free: say your phrase, ask about what's in front of you, and the answer comes back in your
// ear -- a photo only for questions that are actually about that (see isVisualQuestion below).
// Taking one for every single question made the glasses chime and snap a picture even for "напомни
// мне позвонить маме", which has nothing to do with the camera.
//
// This is the piece that makes the app a glasses app rather than a chat app that happens to accept
// photos. Everything it does lands in the same ChatSession the screen shows, so a question asked
// while walking is in the thread when you next look at the phone.
//
// On the microphone: this listens through AudioCaptureHub, which defaults to the glasses'
// Bluetooth HFP mic for every listener (assistant, translator, live, chat dictation) and only
// falls back to the phone mic when the glasses aren't connected. The hub releases the mic solely
// while the phone itself is playing music, video or a voice message -- see AudioCaptureHub.swift
// for why. Nothing here needs to know which physical mic is in use.
//
// Listening never stops while the assistant is on, including with the app in the background --
// the app already declares the `audio` background mode for exactly this. Recognition runs
// on-device so no audio leaves the phone and no network is required to hear the trigger.

import AVFoundation
import Speech
import UIKit
import SwiftUI
import UIKit

@MainActor
final class GlassesAssistant: ObservableObject {
    static let shared = GlassesAssistant()
    private init() {}

    @Published private(set) var isListening = false
    @Published private(set) var status: String?
    @Published var lastError: String?
    /// Что распознаватель слышит прямо сейчас. Показывается в настройках: без этого «фраза не
    /// работает» невозможно отличить от «микрофон не слышит вообще» или «слышит, но другой язык».
    @Published private(set) var heard = ""
    /// Когда фраза сработала в последний раз.
    @Published private(set) var lastTriggerAt: Date?

    static let enabledKey = "glassesAssistantEnabled"
    static let phraseKey = "glassesAssistantPhrase"
    static let defaultPhrase = "окей клод"

    static var phrase: String {
        let stored = UserDefaults.standard.string(forKey: phraseKey) ?? ""
        return stored.isEmpty ? defaultPhrase : stored
    }
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Supplied by the view layer, which owns the DAT stream model. Returns one frame or nil.
    var capturePhoto: (() async -> UIImage?)?

    private var listener: AudioCaptureHub.Listener?
    private var isHandling = false
    private var pendingWorkItem: DispatchWorkItem?
    /// True from the moment the wake phrase is heard until the question is actually handled.
    /// Recognition delivers each finished phrase as its own independent result (see consider()),
    /// so a pause after just the wake phrase -- "окей сбер," <breath> "какая погода" -- arrives as
    /// TWO separate calls, not one. Without this, the first call alone (empty tail) fired the
    /// "what do you see" fallback and took a photo before the real question ever arrived, which is
    /// exactly what made the assistant answer a weather question with a picture of the room.
    private var isAwaitingQuestion = false
    private var collectedQuestion = ""

    // MARK: Control

    func start() async {
        guard !isListening else { return }
        lastError = nil

        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else {
            lastError = "Speech recognition permission is needed to listen for the phrase."
            return
        }
        let mic = await withCheckedContinuation { c in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        guard mic else {
            lastError = "Microphone permission is needed to listen for the phrase."
            return
        }

        let locale = SpeechRecognizerOneShot.activeLocale()
        do {
            listener = try await AudioCaptureHub.shared.addListener(
                locale: locale,
                // Черновой текст проверяется тоже: ждать закрепления фразы значит реагировать на
                // обращение через секунду после того, как человек уже задал вопрос.
                onFinal: { [weak self] text in self?.consider(text, isFinal: true) },
                onVolatile: { [weak self] text in self?.consider(text, isFinal: false) })
            isListening = true
            status = "Listening for \u{201C}\(Self.phrase)\u{201D}"
        } catch {
            lastError = error.localizedDescription
            stop()
        }
    }

    func stop() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        isAwaitingQuestion = false
        collectedQuestion = ""
        AudioCaptureHub.shared.removeListener(listener)
        listener = nil
        isListening = false
        status = nil
        heard = ""
    }

    /// Apply the enabled setting. Safe to call repeatedly.
    func refresh() async {
        if Self.isEnabled {
            await start()
        } else {
            stop()
        }
    }

    /// Re-applies the wake phrase to an already-running listener.
    ///
    /// start() alone won't do this: it guards on `!isListening` and is a no-op while already
    /// listening — exactly the state the toggle is in whenever someone edits the phrase field
    /// without switching it off first. Without this, the field's new text sat in UserDefaults doing
    /// nothing until the toggle was flipped off and back on by hand.
    func applyPhraseChange() async {
        guard isListening else { return }
        stop()
        await start()
    }

    // MARK: Trigger

    /// Look for the phrase and take everything after it as the question.
    ///
    /// Dictation punctuates and capitalises unpredictably, and a phrase said quickly comes back
    /// with the words run together differently every time, so both sides are reduced to bare
    /// letters and digits before comparing.
    /// Volatile revisions of a not-yet-finished phrase arrive as a growing rewrite of the SAME
    /// text ("окей сбер" -> "окей сбер как") -- appending those would double up the trigger phrase
    /// itself. Only a settled, final chunk can safely be treated as a continuation of the same
    /// address, since only then is it guaranteed to be genuinely new speech rather than a revision
    /// of what "consider" already looked at.
    private func consider(_ transcript: String, isFinal: Bool) {
        guard !isHandling else { return }
        let fresh = transcript
        heard = fresh

        // Hot commands are checked first and need no trigger word, the way a smart speaker takes
        // "next track" without being addressed. They are anchored to the start of what is left of
        // the utterance, so they cannot fire from the middle of a sentence.
        if let hit = HotCommandStore.shared.match(in: fresh) {
            isAwaitingQuestion = false
            collectedQuestion = ""
            pendingWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in await self?.run(hit) }
            }
            pendingWorkItem = work
            // An argument may still be arriving ("какая погода" ... "в Белгороде"); a command
            // without one is already complete and should not make the user wait.
            let settle = hit.command.action.takesArgument ? 1.2 : 0.3
            DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
            return
        }

        // Уже обратились фразой-триггером и ждём, что скажут дальше: финальный (не черновой) кусок
        // здесь — продолжение того же вопроса, а не что-то новое. Без этой ветки "окей сбер,"
        // <пауза> "какая погода" распадалось на два отдельных результата распознавания: первый
        // (пустой хвост) срабатывал сам по себе как "а что ты видишь?" с фото, а второй
        // ("какая погода") приходил уже ни к чему не привязанным и терялся — ассистент отвечал на
        // вопрос о погоде фотографией комнаты.
        if isAwaitingQuestion {
            guard isFinal else { return }
            let addition = fresh.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !addition.isEmpty else { return }
            collectedQuestion = collectedQuestion.isEmpty ? addition : collectedQuestion + " " + addition
            scheduleHandle(quickly: true)
            return
        }

        let needle = Self.normalize(Self.phrase)
        guard !needle.isEmpty else { return }
        let haystack = Self.normalize(fresh)
        // Fuzzy, not an exact substring: dictation hands back "окей сбер" as "окей збер" often
        // enough that requiring an exact match meant the phrase silently stopped working on real
        // speech despite testing fine. See FuzzyPhrase for the edit-distance budget.
        guard let question = FuzzyPhrase.matchAndConsume(needle, in: haystack, anchored: false)
        else { return }
        // Короткий отклик: без него невозможно отличить «фраза не распозналась» от «распозналась,
        // но дальше что-то сломалось», а это две совершенно разные починки.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        lastTriggerAt = Date()
        status = "Слышу вас…"
        // Переходить в режим накопления есть смысл только на закреплённой фразе: волатильный
        // "окей сбер" через мгновение сам перепишется в "окей сбер какая погода", безо всякого
        // накопления с нашей стороны -- это тот же растущий черновик, что и раньше, просто уже
        // включающий фразу-триггер целиком.
        isAwaitingQuestion = isFinal
        collectedQuestion = question
        // Пустой хвост на закреплённой фразе — самый неопределённый случай: возможно, дальше
        // ничего не будет ("окей сбер" само по себе — вопрос "что ты видишь"), а возможно, вопрос
        // придёт отдельным куском после паузы. Для Whisper (русский) это вообще единственный вид
        // кусков — там нет черновиков, и следующий кусок появится не раньше чем через паузу в
        // 0.6с плюс время распознавания, так что короткого таймаута может не хватить.
        scheduleHandle(quickly: !(isFinal && question.isEmpty))
    }

    /// (Re)starts the quiet-period timer that decides the wake phrase is done being followed up
    /// on. Called both right after the trigger and again for every extra chunk that arrives while
    /// isAwaitingQuestion is true, so a pause mid-question keeps pushing the deadline out instead
    /// of firing on whatever had arrived so far. `quickly` picks between the two timeouts: fast
    /// when there is already real text to act on (or this is just a volatile revision that will be
    /// superseded anyway), slow when the phrase came back with nothing after it and a follow-up
    /// chunk may still be on its way through a full silence-cut-then-transcribe cycle.
    private func scheduleHandle(quickly: Bool) {
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let question = self.collectedQuestion
            self.isAwaitingQuestion = false
            self.collectedQuestion = ""
            Task { @MainActor in await self.handle(question: question) }
        }
        pendingWorkItem = work
        let delay = quickly ? 1.2 : 3.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Lowercased letters and digits only. "Окей, Клод!" and "окей клод" must match.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Carry out a hot command.
    private func run(_ hit: HotCommandStore.Match) async {
        guard !isHandling else { return }
        isHandling = true
        defer {
            isHandling = false
            status = isListening ? "Listening for \u{201C}\(Self.phrase)\u{201D}" : nil
        }

        switch hit.command.action {
        case .translatorOn:
            TranslatorControl.shared.requestStart()
            speak(Self.acknowledgement("Переводчик включён", "Translator on"))
        case .translatorOff:
            TranslatorControl.shared.requestStop()
            speak(Self.acknowledgement("Переводчик выключен", "Translator off"))
        case .weather:
            await runWeather(city: hit.argument)
        case .ask:
            await handle(question: hit.argument)
        case .reminder:
            await runSchedule(hit.argument, add: ScheduleService.shared.addReminder)
        case .calendarEvent:
            await runSchedule(hit.argument, add: ScheduleService.shared.addEvent)
        }
    }

    /// Общий путь для напоминания и события: разница только в том, какой метод ScheduleService
    /// вызвать, а лента, озвучка и обработка ошибки одинаковые.
    private func runSchedule(_ text: String, add: @escaping (String) async throws -> String) async {
        status = "Добавляю…"
        do {
            let confirmation = try await add(text)
            ChatSession.shared.append(.init(role: .user, text: text))
            ChatSession.shared.append(.init(role: .assistant, text: confirmation))
            ChatSession.shared.persist()
            speak(confirmation)
        } catch {
            let message = error.localizedDescription
            ChatSession.shared.append(.init(role: .failure, text: message))
            speak(message)
        }
    }

    private func runWeather(city: String) async {
        // Dictation gives the city with its preposition attached ("в Белгороде"); the geocoder
        // wants the bare name and copes with the case ending itself.
        var name = city
        for prefix in ["в ", "во ", "in ", "at "] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        status = "Checking the weather…"
        let language = SpeechRecognizerOneShot.activeLocale().identifier
        do {
            let answer = try await WeatherService.shared.summary(for: name, language: language)
            ChatSession.shared.append(.init(role: .user, text: "Погода: \(name)"))
            ChatSession.shared.append(.init(role: .assistant, text: answer))
            ChatSession.shared.persist()
            speak(answer)
        } catch {
            let message = error.localizedDescription
            ChatSession.shared.append(.init(role: .failure, text: message))
            speak(message)
        }
    }

    private func speak(_ text: String) {
        SpeechSynthesizer.shared.speak(text)
    }

    private static func acknowledgement(_ russian: String, _ english: String) -> String {
        SpeechRecognizerOneShot.activeLocale().identifier.hasPrefix("ru") ? russian : english
    }

    /// Substrings that mark a question as being about what's in front of the camera. A keyword
    /// list, not an exact-phrase list: "что ты видишь", "опиши, что сейчас передо мной" and "что
    /// это стоит впереди меня" are all real variants of the same handful of intents, and a fixed
    /// phrase list would need to anticipate every rewording. Taking a photo for every single
    /// question -- the previous behaviour -- made the glasses chime and take a picture even for
    /// "напомни мне" or "как дела", which is what the user is actually addressing.
    private static let visualTriggers = [
        "видишь", "вижу", "видно",
        "передо мной", "перед тобой", "впереди",
        "что это", "что там", "что здесь",
        "опиши",
        "камер", "фото", "снимок", "картин",
    ]

    private static func isVisualQuestion(_ text: String) -> Bool {
        let normalized = Self.normalize(text)
        return Self.visualTriggers.contains { normalized.contains($0) }
    }

    private func handle(question: String) async {
        guard !isHandling else { return }
        isHandling = true
        defer {
            isHandling = false
            status = isListening ? "Listening for \u{201C}\(Self.phrase)\u{201D}" : nil
        }

        // Whatever was recognised after the phrase. Empty means the phrase was said on its own,
        // which is a reasonable way to ask "what am I looking at".
        let text = question.isEmpty ? "Что ты видишь?" : question

        let photo: UIImage?
        if question.isEmpty || Self.isVisualQuestion(question) {
            status = "Taking a photo…"
            photo = await capturePhoto?()
            if photo == nil {
                // Still worth asking: plenty of questions need no picture, and refusing outright
                // because the glasses were folded would be worse than answering the words.
                NSLog("[VisionClaw] assistant: no photo available, asking without one")
            }
        } else {
            photo = nil
        }

        status = "Asking \(ChatSession.shared.engine.label)…"
        let answer = await ChatSession.shared.ask(text: text, image: photo,
                                                  spokenNote: "Glasses question")
        if let answer {
            SpeechSynthesizer.shared.speak(answer)
        }
    }

}
