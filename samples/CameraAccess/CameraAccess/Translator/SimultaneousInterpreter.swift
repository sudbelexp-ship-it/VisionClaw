// VisionClaw - SimultaneousInterpreter.swift
// Real simultaneous interpreting: the translation starts arriving in your ear a couple of seconds
// into a sentence, while the other person keeps talking. Not "wait for a pause, then translate".
//
// The three problems that separates from phrase-by-phrase translation, and how each is solved:
//
// 1. WHERE TO CUT THE STREAM.
//    Cutting every N words, which is what this did first, slices sentences in the middle of a
//    thought, and no translator recovers from half a clause. But speakers already mark their own
//    boundaries: they pause. So the cut is driven by silence in the microphone signal rather than
//    by the text -- the recogniser gives no timing at all, so loudness is measured directly off
//    the audio buffers, against a noise floor that tracks the room. Text accumulates freely and
//    goes out the moment the speaker draws breath, which is also the instant the next words are
//    still to come, so nothing is lost by leaving.
//
// 2. TRANSLATING FRAGMENTS.
//    Chunks now start and end mid-sentence, which a sentence-level translator handles badly. The
//    local LLM is told it is interpreting a continuous stream, is given what it has already said,
//    and is asked for the continuation only -- so the output joins up instead of restarting.
//
// 3. OUR OWN VOICE GOING BACK INTO THE MICROPHONE.
//    The whole point is that playback and capture overlap, which is a feedback loop. With the
//    glasses or headphones connected the separation is physical and nothing else is needed, so the
//    audio simply goes there at full quality. Only when it falls back to the phone's own speaker
//    is echo cancellation switched on: the synthesised speech is then rendered through this same
//    AVAudioEngine (rather than played by AVSpeechSynthesizer on its own path) so voice processing
//    has it as a reference signal and can subtract it from the microphone.

import AVFoundation
import Foundation
import Speech

// MARK: - Voice output rendered through our own engine

/// Speaks queued text through an AVAudioEngine player node instead of letting AVSpeechSynthesizer
/// play it independently. That indirection exists purely so echo cancellation can see the audio:
/// AEC can only subtract a signal it is given as a reference.
///
/// Falls back to plain playback if the engine path can't be set up -- losing echo cancellation is
/// much better than losing the translation.
final class InterpreterVoice {
    private let synthesizer = AVSpeechSynthesizer()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var usesEngine = false

    /// Attach to the shared engine. Safe whether or not it is already running: the node is
    /// connected with the mixer's own format, so no reconfiguration is needed.
    func attach(to engine: AVAudioEngine) {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        outputFormat = format
        usesEngine = true
    }

    func start() {
        guard usesEngine else { return }
        player.play()
    }

    /// Queue one translated fragment. Utterances play back to back in the order added --
    /// AVSpeechSynthesizer queues rather than interrupting, and so does the player node.
    func speak(_ text: String, language: String, rate: Float) {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = rate
        // A beat of leading silence would add up across dozens of fragments.
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        guard usesEngine, let outputFormat else {
            synthesizer.speak(utterance)
            return
        }
        synthesizer.write(utterance) { [weak self] buffer in
            guard let self,
                  let pcm = buffer as? AVAudioPCMBuffer,
                  pcm.frameLength > 0 else { return }
            guard let converted = self.convert(pcm, to: outputFormat) else { return }
            self.player.scheduleBuffer(converted, completionHandler: nil)
        }
    }

    /// AVSpeechSynthesizer hands back its own sample rate and layout; the mixer wants the engine's.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format.isEqual(format) { return buffer }
        if converter == nil || converter?.inputFormat.isEqual(buffer.format) == false {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        if usesEngine { player.play() }
    }
}

// MARK: - The pipeline

struct InterpretedChunk: Identifiable, Equatable {
    let id = UUID()
    let original: String
    var translated: String?
}

@MainActor
final class SimultaneousInterpreter: ObservableObject {
    @Published private(set) var isRunning = false
    /// Words heard but not yet settled enough to translate — shown greyed so the screen reacts
    /// immediately and the thing doesn't look frozen between commits.
    @Published private(set) var inFlight = ""
    @Published private(set) var chunks: [InterpretedChunk] = []
    @Published var errorText: String?
    /// Where the translation is actually coming out, mirrored from the hub. Surfaced because on a
    /// glasses app "why is it talking out of the phone" is the first thing anyone asks.
    var outputRouteName: String { AudioCaptureHub.shared.outputRouteName }

    /// Сколько ждать соседнюю фразу, чтобы отправить их вместе. 0 — отправлять сразу.
    var joinWindow: TimeInterval = 1.0
    /// Темп берётся из общей настройки — ползунок на экране меняет его на лету. По умолчанию
    /// 1.5x: переводчик всегда стартует позади говорящего и должен отыгрывать разрыв внутри
    /// каждого отрезка, иначе отставание копится весь разговор.
    var speechRate: Float { SpeechSynthesizer.shared.utteranceRate }

    private let voice = InterpreterVoice()
    private var listener: AudioCaptureHub.Listener?

    /// Законченные фразы, ждущие отправки.
    private var buffered: [String] = []
    private var flushTimer: Timer?
    /// How many words of the current recognition task have already been sent downstream.
    private var source = TranslatorLanguage.sources[0]

    private(set) lazy var pending: AsyncStream<UUID> = AsyncStream { self.pendingContinuation = $0 }
    private var pendingContinuation: AsyncStream<UUID>.Continuation?

    // MARK: Control

    func start(source: TranslatorLanguage) async {
        guard !isRunning else { return }
        errorText = nil
        self.source = source

        guard await Self.requestPermissions() else {
            errorText = "Нужны разрешения на микрофон и распознавание речи."
            return
        }

        do {
            voice.attach(to: AudioCaptureHub.shared.audioEngine)
            // requiresPhoneMic: true — переводчик обязан слышать собеседника непрерывно, включая
            // моменты, когда сам читает перевод вслух. Настройка «слушать очками, пока молчим» на
            // это время как раз отключила бы вход, а нам нужно ровно противоположное.
            listener = try await AudioCaptureHub.shared.addListener(
                locale: source.speechLocale,
                requiresPhoneMic: true,
                onFinal: { [weak self] text in self?.accept(final: text) },
                onVolatile: { [weak self] text in self?.inFlight = text })
            voice.start()
            isRunning = true
        } catch {
            errorText = error.localizedDescription
            stop()
        }
    }

    func stop() {
        flushTimer?.invalidate()
        flushTimer = nil
        voice.stop()
        AudioCaptureHub.shared.removeListener(listener)
        listener = nil
        inFlight = ""
        buffered = []
        isRunning = false
    }

    private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await withCheckedContinuation { c in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
    }

    func clear() {
        chunks.removeAll()
        inFlight = ""
    }

    func chunk(_ id: UUID) -> InterpretedChunk? { chunks.first { $0.id == id } }

    /// Вызывается, когда кусок переведён: сохраняет и сразу начинает читать вслух — это и есть та
    /// половина «синхронности», которую экран показать не может.
    func complete(_ id: UUID, with translation: String, language: String, speak: Bool) {
        guard let index = chunks.firstIndex(where: { $0.id == id }) else { return }
        chunks[index].translated = translation
        if speak { voice.speak(translation, language: language, rate: speechRate) }
    }

    // MARK: Склейка законченных фраз

    /// Границу фразы теперь проводит сама модель распознавания: закреплённый (final) результат —
    /// это и есть законченный кусок. Своя нарезка по громкости и индексам больше не нужна, и с ней
    /// ушёл целый класс ошибок.
    ///
    /// Остаётся один выбор: отправлять каждую фразу сразу или подождать соседнюю и склеить. Это и
    /// темп, и деньги: каждый запрос к облаку несёт одни и те же инструкции, поэтому две склеенные
    /// фразы стоят заметно дешевле двух отдельных.
    private func accept(final text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        inFlight = ""
        guard !trimmed.isEmpty else { return }
        buffered.append(trimmed)

        flushTimer?.invalidate()
        guard joinWindow > 0 else {
            flushBuffered()
            return
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: joinWindow, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushBuffered() }
        }
    }

    private func flushBuffered() {
        flushTimer?.invalidate()
        flushTimer = nil
        let text = buffered.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        buffered = []
        // Отрезок из одного короткого слова («да», «ага», «мм») стоит целого запроса с полным
        // набором инструкций ради трёх токенов смысла. Такие пропускаем.
        guard text.count >= 4 else { return }
        let chunk = InterpretedChunk(original: text, translated: nil)
        chunks.append(chunk)
        pendingContinuation?.yield(chunk.id)
    }

}
