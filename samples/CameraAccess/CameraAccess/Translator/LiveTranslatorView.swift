// VisionClaw - LiveTranslatorView.swift
// The simultaneous-interpreter screen. The pipeline itself lives in SimultaneousInterpreter.swift;
// this is the part you look at and touch.
//
// Why nothing here talks to a server
// ----------------------------------
// A round trip to GigaChat, YandexGPT or any other hosted model costs roughly 1-3 seconds per
// chunk before the first word comes back, and this mode emits a chunk every couple of seconds --
// the queue would fall behind the speaker within one sentence and never recover. A translator is
// also most needed abroad, which is exactly where the network is worst. So all three stages run on
// the device:
//
//   speech -> text   SFSpeechRecognizer with requiresOnDeviceRecognition
//   text -> text     Apple's Translation framework or Qwen3 through MLX (see TranslatorEngine)
//   text -> speech   AVSpeechSynthesizer, rendered through the interpreter's own audio engine
//
// Requires iOS 18 for TranslationSession, which is why the deployment target moved up from 17.2.

import AVFoundation
import Speech
import SwiftUI
import Translation

// MARK: - Choices

/// Which translator does the text-to-text step.
///
/// Apple's is instant to set up and costs nothing, but it translates each chunk in isolation and
/// is noticeably literal -- and in this mode the chunks are sentence fragments, which it handles
/// worst of all. The local LLM has to be downloaded once and costs a few hundred milliseconds per
/// chunk, but it is told what it has already said, so fragments join up into running speech. Both
/// are fully offline; the trade is setup cost against quality, so the choice is the user's.
enum TranslatorEngine: String, CaseIterable, Identifiable {
    case apple
    case localLLM

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: return "Apple Translate"
        case .localLLM: return "Qwen3 (on-device)"
        }
    }

    var blurb: String {
        switch self {
        case .apple: return "Built in, nothing to download. Fast and literal; weaker on fragments."
        case .localLLM: return "Follows the thread across fragments. Needs a one-time download."
        }
    }
}

/// A language pair the user can pick. Deliberately a short list of what people actually need --
/// a 30-item picker is worse than six entries.
struct TranslatorLanguage: Identifiable, Hashable {
    let id: String        // BCP-47, e.g. "en-US"
    let name: String

    var speechLocale: Locale { Locale(identifier: id) }
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

/// How far behind the speaker the interpreter runs. Named for what the user experiences rather
/// than for the two numbers underneath, because "6 words or 2 seconds" is not a decision anyone
/// wants to make in a conversation.
enum InterpreterPace: String, CaseIterable, Identifiable {
    case fastest
    case balanced
    case accurate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fastest: return "Fastest"
        case .balanced: return "Balanced"
        case .accurate: return "Most accurate"
        }
    }

    var detail: String {
        switch self {
        case .fastest: return "Starts talking after ~1s. Choppier, and reorders badly in German."
        case .balanced: return "About 2 seconds behind. The default."
        case .accurate: return "Waits ~3.5s for whole clauses. Best wording, most lag."
        }
    }

    var chunkWords: Int {
        switch self {
        case .fastest: return 4
        case .balanced: return 6
        case .accurate: return 10
        }
    }

    var maxHold: TimeInterval {
        switch self {
        case .fastest: return 1.0
        case .balanced: return 2.0
        case .accurate: return 3.5
        }
    }
}

// MARK: - Screen

struct LiveTranslatorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var interpreter = SimultaneousInterpreter()
    @StateObject private var llm = LocalLLMTranslator.shared

    @AppStorage("translatorSource") private var sourceId = "en-US"
    @AppStorage("translatorTarget") private var targetId = "ru-RU"
    @AppStorage("translatorSpeaks") private var speakAloud = true
    @AppStorage("translatorEngine") private var engineRaw = TranslatorEngine.apple.rawValue
    @AppStorage("translatorPace") private var paceRaw = InterpreterPace.balanced.rawValue

    @State private var configuration: TranslationSession.Configuration?
    @State private var isDownloadingModel = false
    @State private var showEngineSheet = false

    private var source: TranslatorLanguage {
        TranslatorLanguage.sources.first { $0.id == sourceId } ?? TranslatorLanguage.sources[0]
    }
    private var target: TranslatorLanguage {
        TranslatorLanguage.targets.first { $0.id == targetId } ?? TranslatorLanguage.targets[0]
    }
    private var translationEngine: TranslatorEngine {
        TranslatorEngine(rawValue: engineRaw) ?? .apple
    }
    private var pace: InterpreterPace {
        InterpreterPace(rawValue: paceRaw) ?? .balanced
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
                        interpreter.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { interpreter.clear() } label: { Image(systemName: "trash") }
                        .disabled(interpreter.chunks.isEmpty)
                }
            }
            // SwiftUI vends the Apple translation session only through this modifier, so the whole
            // chunk pump lives inside it regardless of which engine is selected.
            .translationTask(configuration) { session in
                do {
                    // Only Apple's path needs a language pack; preparing unconditionally asked a
                    // Qwen3 user to download one they will never use.
                    if translationEngine == .apple {
                        try await session.prepareTranslation()
                    }
                    for await id in interpreter.pending {
                        guard let chunk = interpreter.chunk(id) else { continue }
                        let text: String
                        switch translationEngine {
                        case .apple:
                            text = try await session.translate(chunk.original).targetText
                        case .localLLM:
                            text = try await llm.translate(
                                chunk.original,
                                from: source.name, to: target.name,
                                recentContext: interpreter.chunks.compactMap(\.translated).suffix(3).map { $0 },
                                isFragment: true)
                        }
                        interpreter.complete(id, with: text, language: target.id, speak: speakAloud)
                    }
                } catch {
                    interpreter.errorText = error.localizedDescription
                }
            }
            .sheet(isPresented: $showEngineSheet) { engineSheet }
            .task(id: "\(sourceId)-\(targetId)") { await refreshConfiguration() }
            .onChange(of: paceRaw) { _, _ in applyPace() }
            .onAppear { applyPace() }
            // Loading multi-GB weights takes tens of seconds. Doing it now, while the user is still
            // choosing languages, keeps it off the first chunk of a live conversation.
            .task(id: engineRaw) {
                if translationEngine == .localLLM, llm.isDownloaded, !llm.isModelLoaded {
                    try? await llm.connect()
                }
            }
        }
    }

    private func applyPace() {
        interpreter.chunkWords = pace.chunkWords
        interpreter.maxHold = pace.maxHold
    }

    // MARK: Language bar

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
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
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

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if interpreter.chunks.isEmpty && !interpreter.isRunning {
                        idleHint.padding(.top, 40)
                    }
                    ForEach(interpreter.chunks) { chunk in
                        VStack(alignment: .leading, spacing: 4) {
                            // Translation first and largest: it is what the user is here for.
                            Text(chunk.translated ?? "…")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(chunk.translated == nil ? .secondary : .primary)
                            Text(chunk.original)
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(chunk.id)
                    }
                    // Words heard but not settled yet. Shown so the screen visibly reacts to speech
                    // between commits rather than looking stalled.
                    if !interpreter.inFlight.isEmpty {
                        Text(interpreter.inFlight)
                            .font(.footnote)
                            .foregroundStyle(.quaternary)
                            .id("inflight")
                    }
                    if let errorText = interpreter.errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onChange(of: interpreter.chunks.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(interpreter.chunks.last?.id, anchor: .bottom)
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
            Text("Translation starts a couple of seconds in and keeps going while they talk — you "
                 + "don't wait for them to finish. Everything runs on this phone, with no network.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Label("Wear the glasses or earphones — otherwise the phone hears its own voice",
                  systemImage: "ear.badge.waveform")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Pace", selection: $paceRaw) {
                ForEach(InterpreterPace.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .disabled(interpreter.isRunning)

            Text(pace.detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                showEngineSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: translationEngine == .apple ? "apple.logo" : "cpu")
                    Text(translationEngine.label)
                    if translationEngine == .localLLM && !llm.isDownloaded {
                        Text("— not downloaded").foregroundStyle(.orange)
                    } else if translationEngine == .localLLM && llm.isLoadingModel {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                }
                .font(.subheadline)
            }
            .buttonStyle(.plain)

            Toggle(isOn: $speakAloud) {
                Label("Speak into my ear", systemImage: "ear")
                    .font(.subheadline)
            }

            Button {
                Task {
                    if interpreter.isRunning {
                        interpreter.stop()
                    } else {
                        await interpreter.start(source: source)
                    }
                }
            } label: {
                Label(interpreter.isRunning ? "Stop" : "Start interpreting",
                      systemImage: interpreter.isRunning ? "stop.fill" : "mic.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(interpreter.isRunning ? .red : .accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(.bar)
    }

    // MARK: Engine sheet

    /// Engine picker plus the download the local model needs. It lives here rather than in Settings
    /// because it is only ever relevant while standing on this screen judging the translation.
    private var engineSheet: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(TranslatorEngine.allCases) { option in
                        Button {
                            engineRaw = option.rawValue
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: option == translationEngine
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(option == translationEngine ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).foregroundStyle(.primary)
                                    Text(option.blurb).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Translator")
                }

                if translationEngine == .localLLM {
                    Section {
                        Picker("Model", selection: Binding(get: { llm.tier }, set: { llm.tier = $0 })) {
                            ForEach(TranslatorModelTier.allCases) { tier in
                                Text("\(tier.label) · \(tier.sizeText)").tag(tier)
                            }
                        }
                        .pickerStyle(.inline)

                        if llm.isDownloaded {
                            Label("Downloaded", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("Delete from this phone", role: .destructive) {
                                Task { _ = await llm.deleteDownloadedModel() }
                            }
                        } else if isDownloadingModel {
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(value: llm.downloadProgress)
                                Text(llm.isFinalizing
                                     ? "Unpacking…"
                                     : "Downloading \(Int(llm.downloadProgress * 100))%")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Button {
                                isDownloadingModel = true
                                Task {
                                    do { try await llm.download { _ in } }
                                    catch { interpreter.errorText = error.localizedDescription }
                                    isDownloadingModel = false
                                }
                            } label: {
                                Label("Download \(llm.tier.sizeText)", systemImage: "arrow.down.circle")
                            }
                        }
                    } header: {
                        Text("On-device model")
                    } footer: {
                        Text("Downloads once over Wi-Fi, then works with no network at all. The "
                             + "larger model translates better; the smaller one answers sooner, "
                             + "which matters more here than in a chat.")
                    }
                }

                Section {
                    Label(interpreter.echoCancellationActive
                          ? "Echo cancellation on" : "Echo cancellation unavailable",
                          systemImage: interpreter.echoCancellationActive ? "checkmark.circle" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(interpreter.echoCancellationActive ? .green : .secondary)
                } footer: {
                    Text("The translation plays while the other person is still talking, so the "
                         + "microphone would otherwise pick up this phone's own voice. Wearing the "
                         + "glasses or earphones removes the problem entirely.")
                }
            }
            .navigationTitle("Translation engine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showEngineSheet = false }
                }
            }
        }
    }

    /// Rebuilds the Apple translation configuration when either language changes; building it is
    /// also what prompts for the language pack the first time a pair is used.
    private func refreshConfiguration() async {
        let status = await LanguageAvailability().status(from: source.translationLanguage,
                                                         to: target.translationLanguage)
        if status == .unsupported, translationEngine == .apple {
            interpreter.errorText = "\(source.name) → \(target.name) isn't a pair Apple Translate "
                + "handles. Switch the translator to Qwen3 below."
            configuration = nil
            return
        }
        interpreter.errorText = nil
        configuration = TranslationSession.Configuration(
            source: source.translationLanguage,
            target: target.translationLanguage
        )
    }
}
