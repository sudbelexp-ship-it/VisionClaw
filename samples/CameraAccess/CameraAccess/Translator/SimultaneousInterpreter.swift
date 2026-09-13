// VisionClaw - SimultaneousInterpreter.swift
// Real simultaneous interpreting: the translation starts arriving in your ear a couple of seconds
// into a sentence, while the other person keeps talking. Not "wait for a pause, then translate".
//
// The three problems that separates from phrase-by-phrase translation, and how each is solved:
//
// 1. WHEN TO COMMIT TEXT THAT ISN'T FINISHED.
//    A streaming recogniser constantly revises its guess: "I want to buy" can become "I want to
//    bike". Translating every revision would babble. The fix is local agreement: keep the last two
//    hypotheses and treat their common word prefix as settled, because a word that survived one
//    revision almost never changes again. Everything past what we already sent, once it is both
//    settled and long enough to be worth a sentence of its own, goes out. This is the standard
//    trick from streaming-ASR research (LocalAgreement-2) and it is what buys a 2-3 second
//    ear-voice span instead of a whole-sentence one.
//
// 2. TRANSLATING FRAGMENTS.
//    Chunks now start and end mid-sentence, which a sentence-level translator handles badly. The
//    local LLM is told it is interpreting a continuous stream, is given what it has already said,
//    and is asked for the continuation only -- so the output joins up instead of restarting.
//
// 3. OUR OWN VOICE GOING BACK INTO THE MICROPHONE.
//    The whole point is that playback and capture overlap, which is a feedback loop. Two defences:
//    the synthesised speech is rendered through this same AVAudioEngine (rather than played by
//    AVSpeechSynthesizer on its own path), so the engine's voice processing has it as a reference
//    signal and can cancel it out of the microphone; and voice processing is switched on for both
//    the input and output nodes. Headphones or the glasses make it a non-issue; this makes the
//    phone's own speaker survivable.

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

    /// Attach to a running engine. Call before the engine starts.
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
    @Published var echoCancellationActive = false

    /// Words that must accumulate before a chunk is sent. Lower reacts sooner but gives the
    /// translator less to work with, which costs accuracy on languages that reorder heavily.
    var chunkWords = 6
    /// Hard ceiling on how long settled words may wait for company. This, not the speaker's
    /// pauses, is what bounds the delay.
    var maxHold: TimeInterval = 2.0
    /// Slightly quicker than default so the queue drains rather than falling further behind.
    var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.08

    private let engine = AVAudioEngine()
    private let voice = InterpreterVoice()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// The previous hypothesis, for the local-agreement comparison.
    private var lastHypothesis: [String] = []
    /// How many words of the current recognition task have already been sent downstream.
    private var committedCount = 0
    private var holdTimer: Timer?
    private var source = TranslatorLanguage.sources[0]

    private(set) lazy var pending: AsyncStream<UUID> = AsyncStream { self.pendingContinuation = $0 }
    private var pendingContinuation: AsyncStream<UUID>.Continuation?

    // MARK: Control

    func start(source: TranslatorLanguage) async {
        guard !isRunning else { return }
        errorText = nil
        self.source = source
        _ = pending

        guard await requestPermissions() else {
            errorText = "Microphone and speech-recognition permission are both needed."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: source.speechLocale), recognizer.isAvailable else {
            errorText = "This phone can't recognise \(source.name) speech. Add the language under "
                + "iOS Settings → General → Keyboard → Dictation."
            return
        }
        self.recognizer = recognizer

        do {
            let session = AVAudioSession.sharedInstance()
            // .allowBluetoothA2DP keeps playback in stereo on the glasses while capture stays on
            // the phone's own microphone. HFP would drag both down to telephone quality.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }

            // Voice processing must be enabled before the engine starts and before the formats are
            // read: turning it on changes the node's format. If the hardware refuses, carry on
            // without it -- with headphones it was never doing much anyway.
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                try engine.outputNode.setVoiceProcessingEnabled(true)
                echoCancellationActive = true
            } catch {
                echoCancellationActive = false
                NSLog("[VisionClaw] voice processing unavailable: %@", "\(error)")
            }

            voice.attach(to: engine)
            try startRecognition()
            voice.start()
            isRunning = true
        } catch {
            errorText = error.localizedDescription
            stop()
        }
    }

    func stop() {
        holdTimer?.invalidate()
        holdTimer = nil
        voice.stop()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        inFlight = ""
        lastHypothesis = []
        committedCount = 0
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func clear() {
        chunks.removeAll()
        inFlight = ""
    }

    func chunk(_ id: UUID) -> InterpretedChunk? { chunks.first { $0.id == id } }

    /// Called once a chunk has been translated: stores it and starts speaking immediately, which
    /// is the half of "simultaneous" that the screen can't show.
    func complete(_ id: UUID, with translation: String, language: String, speak: Bool) {
        guard let index = chunks.firstIndex(where: { $0.id == id }) else { return }
        chunks[index].translated = translation
        if speak { voice.speak(translation, language: language, rate: speechRate) }
    }

    // MARK: Recognition

    private func startRecognition() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        lastHypothesis = []
        committedCount = 0

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw InterpreterError.noMicrophone }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.ingest(result.bestTranscription.formattedString, isFinal: result.isFinal)
                }
                if error != nil || result?.isFinal == true {
                    self.restartIfRunning()
                }
            }
        }
    }

    /// The local-agreement step. Everything here runs on every partial result, which arrive several
    /// times a second, so it stays deliberately cheap.
    private func ingest(_ transcript: String, isFinal: Bool) {
        let words = transcript.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return }

        // Words both the previous and the current hypothesis agree on. A recogniser that has
        // revised a word once and left it alone has effectively settled it.
        var agreed = 0
        while agreed < words.count, agreed < lastHypothesis.count, words[agreed] == lastHypothesis[agreed] {
            agreed += 1
        }
        lastHypothesis = words

        let settled = words.prefix(agreed).dropFirst(committedCount).map { $0 }
        inFlight = words.dropFirst(max(committedCount, agreed)).joined(separator: " ")

        guard !settled.isEmpty else { return }
        let endsSentence = settled.last.map {
            $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!")
                || $0.hasSuffix("。") || $0.hasSuffix("？") || $0.hasSuffix("！")
        } ?? false

        if isFinal || endsSentence || settled.count >= chunkWords {
            emit(settled, advancingTo: agreed)
        } else {
            // Not enough yet — but don't let it wait indefinitely for a talker who trails off.
            scheduleHold(settled, agreed: agreed)
        }
    }

    private func scheduleHold(_ settled: [String], agreed: Int) {
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: maxHold, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.emit(settled, advancingTo: agreed) }
        }
    }

    private func emit(_ words: [String], advancingTo newCommitted: Int) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard newCommitted > committedCount else { return }
        let text = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        committedCount = newCommitted
        let chunk = InterpretedChunk(original: text, translated: nil)
        chunks.append(chunk)
        pendingContinuation?.yield(chunk.id)
    }

    /// iOS caps how long one recognition request may run. Restart transparently: a conversation
    /// that quietly stopped being translated halfway through would be worse than a visible failure.
    private func restartIfRunning() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        request = nil
        task = nil
        do {
            try startRecognition()
        } catch {
            errorText = error.localizedDescription
            stop()
        }
    }

    private func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await withCheckedContinuation { c in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
    }

    enum InterpreterError: LocalizedError {
        case noMicrophone
        var errorDescription: String? { "No usable microphone input." }
    }
}
