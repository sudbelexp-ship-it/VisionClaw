// VisionClaw - LiveTranslatorView.swift
// Live interpreting: someone speaks English or Chinese at you, and a moment later you hear it in
// your own language through whatever you're wearing, with the running transcript on the phone.
//
// Why this uses no AI backend at all
// ----------------------------------
// The whole requirement is latency. A round trip to GigaChat, YandexGPT or any other hosted model
// costs roughly 1-3 seconds per phrase before the first word comes back, which is not interpreting
// -- it is subtitles arriving after the speaker has moved on. So all three stages run on the
// device instead:
//
//   speech -> text   SFSpeechRecognizer with requiresOnDeviceRecognition
//   text -> text     Apple's Translation framework (Core ML models, offline once the language
//                    pack is downloaded, free, no key)
//   text -> speech   AVSpeechSynthesizer
//
// Nothing leaves the phone, nothing needs a network, and the delay is dominated by how long we
// wait to be sure the speaker finished a phrase -- see `phraseGap`.
//
// Requires iOS 18 for TranslationSession, which is why the deployment target moved up from 17.2.

import AVFoundation
import Speech
import SwiftUI
import Translation

// MARK: - Model

struct TranslatedSegment: Identifiable, Equatable {
    let id = UUID()
    let original: String
    var translated: String?
}

/// A language pair the user can pick. Kept to a short list of what people actually need rather
/// than everything Apple supports -- a 30-item picker is worse than four buttons.
struct TranslatorLanguage: Identifiable, Hashable {
    let id: String        // BCP-47, e.g. "en-US"
    let name: String
    /// The locale SFSpeechRecognizer should listen in.
    var speechLocale: Locale { Locale(identifier: id) }
    /// The language Translation should treat as the source/target.
    var translationLanguage: Locale.Language { Locale.Language(identifier: String(id.prefix(2))) }

    static let sources: [TranslatorLanguage] = [
        .init(id: "en-US", name: "English"),
        .init(id: "zh-CN", name: "中文 (Chinese)"),
        .init(id: "de-DE", name: "Deutsch"),
        .init(id: "fr-FR", name: "Français"),
        .init(id: "es-ES", name: "Español"),
        .init(id: "tr-TR", name: "Türkçe"),
    ]

    static let targets: [TranslatorLanguage] = [
        .init(id: "ru-RU", name: "Русский"),
        .init(id: "en-US", name: "English"),
    ]
}

// MARK: - Engine

/// Continuous recognition, chopped into phrases.
///
/// One long-lived recognition task rather than one per phrase: restarting the recognizer for every
/// sentence clips the first syllable of the next one. Instead the task keeps running and we emit
/// only the *new* text since the last flush, restarting solely when iOS ends the task on its own
/// (it caps a single request's duration) or when the user stops.
@MainActor
final class LiveTranslatorEngine: ObservableObject {
    @Published private(set) var isRunning = false
    /// What the speaker is saying right now, before the phrase is considered finished.
    @Published private(set) var partial = ""
    @Published private(set) var segments: [TranslatedSegment] = []
    @Published var errorText: String?

    /// How long a pause counts as "they finished a thought". The single knob that trades latency
    /// against chopping people off mid-sentence; 0.7s is about the length of a natural comma pause.
    private let phraseGap: TimeInterval = 0.7

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var flushWorkItem: DispatchWorkItem?
    /// Characters of the current task's transcript already turned into a segment.
    private var emittedPrefixLength = 0
    private var sourceLanguage: TranslatorLanguage = TranslatorLanguage.sources[0]

    /// Finished phrases waiting to be translated. The view pumps this into a TranslationSession,
    /// because Apple vends sessions only through a SwiftUI modifier.
    private(set) lazy var phrases: AsyncStream<UUID> = AsyncStream { self.phraseContinuation = $0 }
    private var phraseContinuation: AsyncStream<UUID>.Continuation?

    func start(source: TranslatorLanguage) async {
        guard !isRunning else { return }
        errorText = nil
        sourceLanguage = source
        _ = phrases   // force the lazy stream so the continuation exists before the first phrase

        guard await requestPermissions() else {
            errorText = "Microphone and speech-recognition permission are both needed."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: source.speechLocale), recognizer.isAvailable else {
            errorText = "This phone can't recognise \(source.name) speech. "
                + "Add the language under iOS Settings → General → Keyboard → Dictation."
            return
        }
        self.recognizer = recognizer

        do {
            let session = AVAudioSession.sharedInstance()
            // .allowBluetoothA2DP so the translation plays into the glasses or earbuds, while
            // capture stays on the phone's own microphone: HFP would give us the headset's mic at
            // telephone quality AND take over playback, which is exactly the combination that
            // sounded terrible before.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
            try startTask()
            isRunning = true
        } catch {
            errorText = error.localizedDescription
            stop()
        }
    }

    func stop() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        partial = ""
        emittedPrefixLength = 0
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func clear() {
        segments.removeAll()
        partial = ""
    }

    /// Called by the view once a phrase has been translated.
    func setTranslation(_ text: String, for id: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].translated = text
    }

    func segment(_ id: UUID) -> TranslatedSegment? {
        segments.first { $0.id == id }
    }

    // MARK: Recognition

    private func startTask() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device keeps the audio on the phone and, more to the point here, removes a network
        // round trip from every partial result.
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        emittedPrefixLength = 0

        let input = audioEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw TranslatorError.noMicrophone }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.handle(transcript: result.bestTranscription.formattedString,
                                isFinal: result.isFinal)
                }
                if error != nil || result?.isFinal == true {
                    self.restartIfRunning()
                }
            }
        }
    }

    private func handle(transcript: String, isFinal: Bool) {
        let full = transcript
        let start = full.index(full.startIndex, offsetBy: min(emittedPrefixLength, full.count))
        let fresh = String(full[start...]).trimmingCharacters(in: .whitespaces)
        partial = fresh

        flushWorkItem?.cancel()
        // A sentence-ending mark means they're done -- no reason to sit out the pause timer.
        if isFinal || fresh.hasSuffix(".") || fresh.hasSuffix("?") || fresh.hasSuffix("!")
            || fresh.hasSuffix("。") || fresh.hasSuffix("？") || fresh.hasSuffix("！") {
            flush(fresh, totalLength: full.count)
            return
        }
        guard !fresh.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.flush(fresh, totalLength: full.count)
        }
        flushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + phraseGap, execute: work)
    }

    private func flush(_ text: String, totalLength: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        emittedPrefixLength = totalLength
        partial = ""
        let segment = TranslatedSegment(original: trimmed, translated: nil)
        segments.append(segment)
        phraseContinuation?.yield(segment.id)
    }

    /// iOS ends a recognition request after a while on its own. Restart transparently so a long
    /// conversation doesn't quietly stop being translated halfway through.
    private func restartIfRunning() {
        guard isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request = nil
        task = nil
        do {
            try startTask()
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

    enum TranslatorError: LocalizedError {
        case noMicrophone
        var errorDescription: String? { "No usable microphone input." }
    }
}

// MARK: - Screen

struct LiveTranslatorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = LiveTranslatorEngine()
    @StateObject private var speech = SpeechSynthesizer.shared

    @AppStorage("translatorSource") private var sourceId = "en-US"
    @AppStorage("translatorTarget") private var targetId = "ru-RU"
    @AppStorage("translatorSpeaks") private var speakAloud = true

    @State private var configuration: TranslationSession.Configuration?
    @State private var downloadNeeded = false

    private var source: TranslatorLanguage {
        TranslatorLanguage.sources.first { $0.id == sourceId } ?? TranslatorLanguage.sources[0]
    }
    private var target: TranslatorLanguage {
        TranslatorLanguage.targets.first { $0.id == targetId } ?? TranslatorLanguage.targets[0]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                languageBar
                Divider().overlay(Color.white.opacity(0.08))
                transcript
                controls
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Live translator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        engine.stop()
                        speech.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        engine.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(engine.segments.isEmpty)
                }
            }
            // The session is vended by SwiftUI; the engine pushes finished phrases through the
            // stream below and each translation lands back on its own segment.
            .translationTask(configuration) { session in
                do {
                    try await session.prepareTranslation()
                    downloadNeeded = false
                    for await id in engine.phrases {
                        guard let segment = engine.segment(id) else { continue }
                        let response = try await session.translate(segment.original)
                        engine.setTranslation(response.targetText, for: id)
                        if speakAloud {
                            speech.speak(response.targetText)
                        }
                    }
                } catch {
                    engine.errorText = error.localizedDescription
                }
            }
            .task(id: "\(sourceId)-\(targetId)") { await refreshConfiguration() }
        }
    }

    private var languageBar: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("From", selection: $sourceId) {
                    ForEach(TranslatorLanguage.sources) { Text($0.name).tag($0.id) }
                }
            } label: {
                languageChip(source.name, caption: "They speak")
            }

            Image(systemName: "arrow.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)

            Menu {
                Picker("To", selection: $targetId) {
                    ForEach(TranslatorLanguage.targets) { Text($0.name).tag($0.id) }
                }
            } label: {
                languageChip(target.name, caption: "You hear")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func languageChip(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if engine.segments.isEmpty && !engine.isRunning {
                        idleHint.padding(.top, 50)
                    }
                    ForEach(engine.segments) { segment in
                        VStack(alignment: .leading, spacing: 4) {
                            // Translation first and largest: it is what the user is here for.
                            Text(segment.translated ?? "…")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(segment.translated == nil ? .secondary : .primary)
                            Text(segment.original)
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(segment.id)
                    }
                    if !engine.partial.isEmpty {
                        Text(engine.partial)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .id("partial")
                    }
                    if let errorText = engine.errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onChange(of: engine.segments.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(engine.segments.last?.id, anchor: .bottom)
                }
            }
        }
    }

    private var idleHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.and.person.filled")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Point the phone at whoever is talking")
                .font(.headline)
            Text("Everything runs on this phone — no network, no account. The first use of a "
                 + "language downloads its pack once.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Toggle(isOn: $speakAloud) {
                Label("Speak the translation aloud", systemImage: "ear")
                    .font(.subheadline)
            }
            .padding(.horizontal, 4)

            Button {
                Task {
                    if engine.isRunning {
                        engine.stop()
                        speech.stop()
                    } else {
                        await engine.start(source: source)
                    }
                }
            } label: {
                Label(engine.isRunning ? "Stop" : "Start listening",
                      systemImage: engine.isRunning ? "stop.fill" : "mic.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isRunning ? .red : .accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(.bar)
    }

    /// Rebuilds the translation configuration when either language changes, which is also what
    /// triggers the language-pack download prompt the first time a pair is used.
    private func refreshConfiguration() async {
        let availability = LanguageAvailability()
        let status = await availability.status(from: source.translationLanguage,
                                               to: target.translationLanguage)
        switch status {
        case .unsupported:
            engine.errorText = "\(source.name) → \(target.name) isn't a pair iOS can translate."
            configuration = nil
        case .supported:
            downloadNeeded = true
            fallthrough
        default:
            engine.errorText = nil
            configuration = TranslationSession.Configuration(
                source: source.translationLanguage,
                target: target.translationLanguage
            )
        }
    }
}
