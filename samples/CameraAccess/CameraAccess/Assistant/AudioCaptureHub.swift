// VisionClaw - AudioCaptureHub.swift
// One microphone, one audio engine, shared by everything that listens.
//
// Why it exists
// -------------
// The interpreter and the hands-free assistant both need the microphone, and iOS gives an app
// exactly one active input: "only one physical input is active at a time". Two AVAudioEngines
// fighting over it meant whichever started second silently got nothing. Worse, selecting a
// Bluetooth headset microphone drags playback onto the same HFP link, so the moment either feature
// reached for the glasses' microphones, everything the user heard dropped to call quality.
//
// So: capture is always the phone's own microphone, playback always stays on A2DP at full quality,
// and this object owns the single engine both features attach to.
//
// Two languages at once
// ---------------------
// The interpreter listens in the other person's language while the assistant listens for a trigger
// phrase in the user's own — and one SFSpeechRecognizer handles one locale. The way out is that
// the recogniser takes audio buffers pushed to it rather than opening the microphone itself, so a
// single tap can feed several independent recognition requests. Each listener here gets its own
// locale, its own request and its own task, all reading the same buffers.

import AVFoundation
import Foundation
import Speech

@MainActor
final class AudioCaptureHub: ObservableObject {
    static let shared = AudioCaptureHub()
    private init() {}

    /// Which output the audio is going to, for screens that need to explain themselves.
    @Published private(set) var outputRouteName = ""
    @Published private(set) var isRunning = false
    /// True while the microphone has been handed back because something else is using the audio.
    @Published private(set) var isSuspended = false

    /// One party interested in the microphone.
    final class Listener {
        let id = UUID()
        let locale: Locale
        /// Called with the running transcript, and whether iOS considers it final.
        let onTranscript: (String, Bool) -> Void
        /// Called with each buffer's loudness and duration, for pause detection.
        let onLevel: ((Float, Double) -> Void)?

        var recognizer: SFSpeechRecognizer?
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?

        init(locale: Locale,
             onTranscript: @escaping (String, Bool) -> Void,
             onLevel: ((Float, Double) -> Void)? = nil) {
            self.locale = locale
            self.onTranscript = onTranscript
            self.onLevel = onLevel
        }
    }

    private let engine = AVAudioEngine()
    private var listeners: [Listener] = []
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var otherAudioTimer: Timer?

    /// The engine, so the interpreter can attach its playback node to the same graph. Playing
    /// through it is what lets echo cancellation see the audio as a reference signal.
    var audioEngine: AVAudioEngine { engine }

    // MARK: Listeners

    /// Start listening in `locale`. The engine starts on the first listener and stops after the
    /// last one leaves, so neither feature has to know whether the other is running.
    @discardableResult
    func addListener(locale: Locale,
                     onTranscript: @escaping (String, Bool) -> Void,
                     onLevel: ((Float, Double) -> Void)? = nil) throws -> Listener {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw HubError.unsupportedLanguage(locale.identifier)
        }
        let listener = Listener(locale: locale, onTranscript: onTranscript, onLevel: onLevel)
        listener.recognizer = recognizer
        listeners.append(listener)

        if !isRunning {
            try startEngine()
        }
        startTask(for: listener)
        return listener
    }

    func removeListener(_ listener: Listener?) {
        guard let listener else { return }
        listener.request?.endAudio()
        listener.task?.cancel()
        listener.request = nil
        listener.task = nil
        listeners.removeAll { $0.id == listener.id }
        if listeners.isEmpty { stopEngine() }
    }

    // MARK: Engine

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        // No .defaultToSpeaker: it pins playback to the built-in speaker for the whole category and
        // overrides connected glasses. No .allowBluetooth either: HFP would hand us the headset's
        // microphone and take playback down with it. Capture stays on the phone, playback stays on
        // A2DP.
        // .mixWithOthers, not .duckOthers: this session is open all day, and ducking would leave
        // every other app quieter for the whole time. Nothing here needs the room to itself.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .allowBluetoothA2DP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
        applyOutputRoute()
        observeRouteChanges()
        observeOtherAudio()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw HubError.noMicrophone }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Fan the same buffer out to every recogniser. They are independent tasks reading a
            // shared copy; none of them consumes it from the others.
            let seconds = Double(buffer.frameLength) / format.sampleRate
            var rms: Float = 0
            if let channel = buffer.floatChannelData?[0] {
                var sum: Float = 0
                let count = Int(buffer.frameLength)
                for i in 0..<count { sum += channel[i] * channel[i] }
                rms = count > 0 ? sqrt(sum / Float(count)) : 0
            }
            Task { @MainActor in
                for listener in self.listeners {
                    listener.request?.append(buffer)
                    listener.onLevel?(rms, seconds)
                }
            }
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        isSuspended = false
    }

    // MARK: Yielding the microphone to other audio

    /// Give the microphone back while something else is playing, and take it again afterwards.
    ///
    /// Two reasons, and the first is not obvious. A2DP is output-only and cannot carry audio in
    /// both directions, so on many devices ANY active input forces the Bluetooth link down to HFP
    /// at 8 kHz -- music, a podcast or a call would play at telephone quality the whole time this
    /// app was listening, no matter which microphone was chosen. The second is simpler: with music
    /// playing, the recogniser transcribes the lyrics, and sooner or later a line of a song matches
    /// a command.
    ///
    /// The cost is real and worth stating: while other audio plays, nothing here can hear anything,
    /// including the trigger phrase.
    private func observeOtherAudio() {
        guard otherAudioTimer == nil else { return }
        // Polled rather than purely notification-driven: silenceSecondaryAudioHint only fires for
        // apps that opt in, and plenty of players never do.
        otherAudioTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcileWithOtherAudio() }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                // A call takes the session away whether we like it or not; the point of handling it
                // is coming back afterwards rather than staying silently dead.
                if type == .began {
                    self?.suspend()
                } else {
                    self?.reconcileWithOtherAudio()
                }
            }
        }
    }

    private func reconcileWithOtherAudio() {
        guard !listeners.isEmpty else { return }
        let othersPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying
        if othersPlaying, !isSuspended {
            suspend()
        } else if !othersPlaying, isSuspended {
            resume()
        }
    }

    private func suspend() {
        guard !isSuspended else { return }
        for listener in listeners {
            listener.request?.endAudio()
            listener.task?.cancel()
            listener.request = nil
            listener.task = nil
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false
        isSuspended = true
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resume() {
        guard isSuspended, !listeners.isEmpty else { return }
        do {
            try startEngine()
            for listener in listeners { startTask(for: listener) }
        } catch {
            // Leave it suspended and try again on the next tick rather than spinning.
            NSLog("[VisionClaw] hub could not resume: %@", "\(error)")
        }
    }

    private func stopEngine() {
        otherAudioTimer?.invalidate()
        otherAudioTimer = nil
        for observer in [routeObserver, interruptionObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        routeObserver = nil
        interruptionObserver = nil
        isSuspended = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTask(for listener: Listener) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device throughout: two simultaneous recognisers streaming everything heard to Apple
        // all day would be both a privacy problem and useless without a network.
        if listener.recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        listener.request = request
        listener.task = listener.recognizer?.recognitionTask(with: request) { [weak self, weak listener] result, error in
            guard let self, let listener else { return }
            Task { @MainActor in
                if let result {
                    listener.onTranscript(result.bestTranscription.formattedString, result.isFinal)
                }
                if error != nil || result?.isFinal == true {
                    // iOS caps how long one request may run. Restart transparently, or listening
                    // would quietly stop a minute in.
                    guard self.listeners.contains(where: { $0.id == listener.id }) else { return }
                    listener.request?.endAudio()
                    listener.task?.cancel()
                    self.startTask(for: listener)
                }
            }
        }
    }

    // MARK: Routing

    /// Anything that isn't the phone's own speaker or earpiece: headphones, the glasses, AirPods.
    nonisolated static func hasExternalOutput(_ session: AVAudioSession) -> Bool {
        session.currentRoute.outputs.contains {
            $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
        }
    }

    /// Headset if there is one, loudspeaker if there isn't. Without the override, .playAndRecord
    /// with no headset plays out of the earpiece, which is unusable with the phone on a table.
    private func applyOutputRoute() {
        let session = AVAudioSession.sharedInstance()
        if Self.hasExternalOutput(session) {
            try? session.overrideOutputAudioPort(.none)
        } else {
            try? session.overrideOutputAudioPort(.speaker)
        }
        outputRouteName = session.currentRoute.outputs.first?.portName ?? ""
    }

    /// Glasses that connect or fall asleep mid-conversation change the route underneath us.
    private func observeRouteChanges() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyOutputRoute() }
        }
    }

    enum HubError: LocalizedError {
        case noMicrophone
        case unsupportedLanguage(String)

        var errorDescription: String? {
            switch self {
            case .noMicrophone:
                return "No usable microphone input."
            case .unsupportedLanguage(let id):
                return "This phone can't recognise \(id) speech. Add the language under iOS "
                    + "Settings → General → Keyboard → Dictation."
            }
        }
    }
}
