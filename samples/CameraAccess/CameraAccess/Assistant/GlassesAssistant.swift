// VisionClaw - GlassesAssistant.swift
// Hands-free: say your phrase, the glasses take a picture, and the answer comes back in your ear.
//
// This is the piece that makes the app a glasses app rather than a chat app that happens to accept
// photos. Everything it does lands in the same ChatSession the screen shows, so a question asked
// while walking is in the thread when you next look at the phone.
//
// On the microphone. The glasses' own array is beamformed onto the wearer and would hear a spoken
// command better than the phone does -- but iOS only reaches it over Bluetooth HFP, and selecting
// an HFP input drags playback onto the same link, so everything the user hears drops to call
// quality for as long as the assistant listens. Since it listens all day, that would mean
// call-quality audio all day. Capture therefore goes through AudioCaptureHub on the phone's own
// microphone, which also lets this run alongside the interpreter instead of fighting it for the
// single input iOS allows an app.
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
                onFinal: { [weak self] text in self?.consider(text) },
                onVolatile: { [weak self] text in self?.consider(text) })
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

    // MARK: Trigger

    /// Look for the phrase and take everything after it as the question.
    ///
    /// Dictation punctuates and capitalises unpredictably, and a phrase said quickly comes back
    /// with the words run together differently every time, so both sides are reduced to bare
    /// letters and digits before comparing.
    private func consider(_ transcript: String) {
        guard !isHandling else { return }
        // Каждый результат — самостоятельная фраза, а не продолжение прошлой, поэтому отслеживать
        // прочитанное больше не нужно. От повторного срабатывания на одном и том же черновике
        // защищают флаг isHandling и отложенный запуск ниже.
        let fresh = transcript
        heard = fresh

        // Hot commands are checked first and need no trigger word, the way a smart speaker takes
        // "next track" without being addressed. They are anchored to the start of what is left of
        // the utterance, so they cannot fire from the middle of a sentence.
        if let hit = HotCommandStore.shared.match(in: fresh) {
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

        let needle = Self.normalize(Self.phrase)
        guard !needle.isEmpty else { return }
        let haystack = Self.normalize(fresh)
        guard let range = haystack.range(of: needle) else { return }

        let question = String(haystack[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        // Короткий отклик: без него невозможно отличить «фраза не распозналась» от «распозналась,
        // но дальше что-то сломалось», а это две совершенно разные починки.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        lastTriggerAt = Date()
        status = "Слышу вас…"

        // Wait a beat before acting: the words right after the phrase are still arriving, and
        // firing on the first partial would send "what do you" instead of "what do you see".
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.handle(question: question) }
        }
        pendingWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
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

        status = "Taking a photo…"
        let photo = await capturePhoto?()
        if photo == nil {
            // Still worth asking: plenty of questions need no picture, and refusing outright
            // because the glasses were folded would be worse than answering the words.
            NSLog("[VisionClaw] assistant: no photo available, asking without one")
        }

        status = "Asking \(ChatSession.shared.engine.label)…"
        let answer = await ChatSession.shared.ask(text: text, image: photo,
                                                  spokenNote: "Glasses question")
        if let answer {
            SpeechSynthesizer.shared.speak(answer)
        }
    }

}
