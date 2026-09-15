// VisionClaw - LiveTranslatorView.swift
// The simultaneous-interpreter screen. The pipeline itself lives in SimultaneousInterpreter.swift;
// this is the part you look at and touch.
//
// Where the work happens
// ----------------------
// Listening and speaking are always on the device; only the translation itself may leave it.
//
//   речь -> текст    SpeechAnalyzer (iOS 26) / whisper.cpp for Russian, целиком на устройстве
//   text -> text     GigaChat, YandexGPT, or Qwen3 on-device -- see TranslatorModel below
//   text -> speech   AVSpeechSynthesizer, rendered through the interpreter's own audio engine
//
// Model choice used to be two menus deep (an engine, then a cloud service inside it) plus a
// separate offline toggle layered on top -- three controls for one decision. It's a straight
// three-way pick now, right on this screen: the user already knows whether they have signal and
// which cloud key they'd rather spend, and picking "Qwen" IS the offline choice, no separate
// switch needed. Apple's on-device Translation framework was the fourth original option; dropped
// because its own description here already called it the worst of the three at fragment-level
// speech, and a fourth choice would have undone the point of collapsing this to one picker.
// CloudTranslator still falls back from whichever cloud service is picked to Qwen3 on its own if
// that specific request fails -- this collapses the CHOICE, not the existing safety net.

import SwiftUI

// MARK: - Choices

/// The three things that can actually do the text-to-text step. Replaces the old two-level
/// engine+service split: whichever of these is picked IS what translates, not a category that
/// then needs a second picker to narrow down.
enum TranslatorModel: String, CaseIterable, Identifiable {
    case qwen
    case yandex
    case gigachat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .qwen: return "Qwen"
        case .yandex: return "Yandex"
        case .gigachat: return "GigaChat"
        }
    }

    /// nil for Qwen -- it isn't a cloud service, it's the on-device fallback everything else
    /// already falls back to.
    var cloudService: CloudTranslator.Service? {
        switch self {
        case .qwen: return nil
        case .yandex: return .yandexgpt
        case .gigachat: return .gigachat
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

/// How long a gap counts as the speaker finishing a thought. Named for what it feels like rather
/// than for the number of seconds, because nobody wants to tune milliseconds mid-conversation.
enum InterpreterPace: String, CaseIterable, Identifiable {
    case fastest
    case balanced
    case accurate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fastest: return "Быстро"
        case .balanced: return "Обычно"
        case .accurate: return "Точно"
        }
    }

    var detail: String {
        switch self {
        case .fastest: return "Отправляет каждую фразу сразу. Быстрее всех и дороже всех."
        case .balanced: return "Ждёт секунду и склеивает соседние фразы. По умолчанию."
        case .accurate: return "Ждёт дольше и переводит целыми мыслями. Точнее и вдвое дешевле."
        }
    }

    /// Сколько ждать соседнюю фразу, чтобы отправить их одним запросом.
    ///
    /// Границу фразы теперь проводит сама модель распознавания, поэтому выбирать длину паузы
    /// больше не нужно. Остаётся выбор между скоростью и ценой: каждый запрос к облаку несёт одни
    /// и те же инструкции, и две склеенные фразы стоят заметно дешевле двух отдельных.
    var joinWindow: TimeInterval {
        switch self {
        case .fastest: return 0
        case .balanced: return 1.0
        case .accurate: return 2.5
        }
    }
}

// MARK: - Screen

struct LiveTranslatorView: View {
    @StateObject private var interpreter = SimultaneousInterpreter()
    @StateObject private var llm = LocalLLMTranslator.shared
    @StateObject private var cloud = CloudTranslator.shared
    @StateObject private var control = TranslatorControl.shared

    @AppStorage("translatorSource") private var sourceId = "en-US"
    @AppStorage("translatorTarget") private var targetId = "ru-RU"
    @AppStorage("translatorSpeaks") private var speakAloud = true
    @AppStorage("translatorModel") private var modelRaw = TranslatorModel.gigachat.rawValue
    @AppStorage("translatorPace") private var paceRaw = InterpreterPace.balanced.rawValue

    @State private var isDownloadingModel = false
    @State private var showSettingsSheet = false
    @State private var sessionId = UUID()
    /// Chunks already written to disk, so a long session isn't rewritten from scratch every time
    /// one more line arrives -- that would be quadratic on a conversation of any length.
    @State private var persistedCount = 0

    private var source: TranslatorLanguage {
        TranslatorLanguage.sources.first { $0.id == sourceId } ?? TranslatorLanguage.sources[0]
    }
    private var target: TranslatorLanguage {
        TranslatorLanguage.targets.first { $0.id == targetId } ?? TranslatorLanguage.targets[0]
    }
    private var model: TranslatorModel {
        TranslatorModel(rawValue: modelRaw) ?? .gigachat
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
            .navigationTitle("Переводчик")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // Очистка начинает новую запись, а не стирает сохранённую: то, что уже
                        // на диске, — свидетельство состоявшегося разговора.
                        persist(force: true)
                        interpreter.clear()
                        sessionId = UUID()
                        persistedCount = 0
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(interpreter.chunks.isEmpty)
                    .accessibilityLabel("Очистить")
                }
            }
            .sheet(isPresented: $showSettingsSheet) { settingsSheet }
            // One task for the screen's whole lifetime rather than one per language pair or model
            // switch -- Apple's TranslationSession needed a session object rebuilt per pair, but
            // none of the three models here do, so the loop just reads `model` fresh each time
            // around, which already picks up a mid-conversation switch on the very next chunk.
            .task {
                for await id in interpreter.pending {
                    guard let chunk = interpreter.chunk(id) else { continue }
                    let context = interpreter.chunks.compactMap(\.translated).suffix(3).map { $0 }
                    do {
                        let text: String
                        switch model {
                        case .qwen:
                            text = try await llm.translate(
                                chunk.original, from: source.name, to: target.name,
                                recentContext: context, isFragment: true)
                        case .yandex, .gigachat:
                            text = try await cloud.translate(
                                chunk.original, service: model.cloudService!,
                                from: source.name, to: target.name, recentContext: context)
                        }
                        interpreter.complete(id, with: text, language: target.id, speak: speakAloud)
                        persist(force: false)
                    } catch {
                        // Per chunk, not around the whole loop: one failed segment (Qwen not
                        // downloaded, say) used to end the for-await entirely, silently translating
                        // nothing for the rest of the conversation until the interpreter restarted.
                        interpreter.errorText = error.localizedDescription
                    }
                }
            }
            .onChange(of: paceRaw) { _, _ in applyPace() }
            // Переключение модели посреди разговора — новый шанс для облака, а не продолжение
            // прежнего разочарования: если предыдущая модель была облачной и подвела, липкий откат
            // CloudTranslator не должен цепляться за только что выбранную.
            .onChange(of: modelRaw) { _, _ in CloudTranslator.shared.beginSession() }
            // "включи переводчик" / "выключи переводчик", said without touching the phone.
            .onChange(of: control.startTicket) { _, _ in
                Task { if !interpreter.isRunning { await interpreter.start(source: source) } }
            }
            .onChange(of: control.stopTicket) { _, _ in
                if interpreter.isRunning {
                    interpreter.stop()
                    persist(force: true)
                }
            }
            .onAppear { applyPace() }
            // Loading multi-GB weights takes tens of seconds. Doing it now, while the user is still
            // choosing languages, keeps it off the first chunk of a live conversation -- worth doing
            // regardless of which model is picked, since Qwen is also the fallback target for the
            // other two, not just its own separate choice.
            .task {
                if llm.isDownloaded, !llm.isModelLoaded {
                    try? await llm.connect()
                }
            }
        }
    }

    /// Write the session to history. Throttled while interpreting -- every tenth line is often
    /// enough to survive a crash, and a full rewrite per line would cost more than the translation.
    private func persist(force: Bool) {
        let chunks = interpreter.chunks.filter { $0.translated != nil }
        guard !chunks.isEmpty else { return }
        guard force || chunks.count - persistedCount >= 10 else { return }
        persistedCount = chunks.count
        let messages = chunks.flatMap { chunk -> [StoredMessage] in
            [
                StoredMessage(role: .user, text: chunk.original),
                StoredMessage(role: .assistant, text: chunk.translated ?? ""),
            ]
        }
        ConversationStore.shared.save(id: sessionId, kind: .interpreter,
                                      subtitle: "\(source.name) → \(target.name)",
                                      messages: messages)
    }

    private func applyPace() {
        interpreter.joinWindow = pace.joinWindow
    }

    // MARK: Language bar

    private var languageBar: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("С какого", selection: $sourceId) {
                    ForEach(TranslatorLanguage.sources) { Text($0.name).tag($0.id) }
                }
            } label: {
                languageChip(source.name, caption: "Собеседник")
            }

            Image(systemName: "arrow.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)

            Menu {
                Picker("На какой", selection: $targetId) {
                    ForEach(TranslatorLanguage.targets) { Text($0.name).tag($0.id) }
                }
            } label: {
                languageChip(target.name, caption: "Вы слышите")
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
                    if model != .qwen, cloud.requestCount > 0 {
                StatusLine(kind: .idle, text: "Запросов в облако за сеанс: \(cloud.requestCount)")
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            Text("Начните говорить")
                .font(.headline)
            Text("Перевод начинается через пару секунд после начала фразы и идёт, пока человек "
                 + "говорит, — ждать окончания не нужно.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Label("Наденьте очки или наушники — иначе телефон услышит собственный голос",
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
            HStack(spacing: 8) {
                Picker("Модель", selection: $modelRaw) {
                    ForEach(TranslatorModel.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)

                Button {
                    showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Настройки перевода")
            }

            modelStatusLine

            Picker("Темп", selection: $paceRaw) {
                ForEach(InterpreterPace.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .disabled(interpreter.isRunning)

            Text(pace.detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(isOn: $speakAloud) {
                Label("Читать вслух", systemImage: "ear")
                    .font(.subheadline)
            }

            if speakAloud {
                SpeechRateSlider()
            }

            Button {
                Task {
                    if interpreter.isRunning {
                        interpreter.stop()
                    } else {
                        await interpreter.start(source: source)
                    }
                    if !interpreter.isRunning { persist(force: true) }
                }
            } label: {
                Label(interpreter.isRunning ? "Стоп" : "Начать перевод",
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

    /// Line right under the model picker: whichever warning is actually relevant to the model
    /// that's picked right now, and nothing when there's nothing to say. Qwen not downloaded yet
    /// and "GigaChat has no key, so this is quietly translating on Qwen instead" used to be
    /// buried in a sheet the user had no reason to open until a translation had already gone
    /// wrong; both are exactly the kind of thing to see before pressing start, not after.
    @ViewBuilder
    private var modelStatusLine: some View {
        switch model {
        case .qwen:
            if !llm.isDownloaded {
                HStack(spacing: 8) {
                    Label("Модель не скачана", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    if isDownloadingModel {
                        ProgressView(value: llm.downloadProgress).frame(width: 60)
                    } else {
                        Button("Скачать \(llm.tier.sizeText)") { downloadModel() }
                            .font(.caption.weight(.semibold))
                    }
                }
            } else if llm.isLoadingModel {
                Label("Загружаю модель…", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .yandex, .gigachat:
            if let service = model.cloudService, !service.isConfigured {
                Label("Ключ \(service.label) не задан в Настройках — переводит Qwen",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let reason = cloud.lastFallbackReason {
                // Silent fallback is the right behaviour mid-conversation, but the user still
                // deserves to find out why the quality changed for the rest of this session.
                Label("Облако подвело, дальше на Qwen: \(reason)", systemImage: "arrow.uturn.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func downloadModel() {
        isDownloadingModel = true
        Task {
            do { try await llm.download { _ in } }
            catch { interpreter.errorText = error.localizedDescription }
            isDownloadingModel = false
        }
    }

    // MARK: Settings sheet

    /// What's left once model choice moved to the main screen: Qwen's size tier (relevant no
    /// matter which of the three is picked, since Qwen is also what the other two fall back to)
    /// and where the audio is actually going.
    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(TranslatorModelTier.allCases) { tier in
                        Button {
                            llm.tier = tier
                        } label: {
                            HStack {
                                Text("\(tier.label) · \(tier.sizeText)")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if llm.tier == tier {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }

                    if llm.isDownloaded {
                        Label("Скачана", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Удалить с телефона", role: .destructive) {
                            Task { _ = await llm.deleteDownloadedModel() }
                        }
                    } else if isDownloadingModel {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: llm.downloadProgress)
                            Text(llm.isFinalizing
                                 ? "Распаковываю…"
                                 : "Downloading \(Int(llm.downloadProgress * 100))%")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button { downloadModel() } label: {
                            Label("Скачать \(llm.tier.sizeText)", systemImage: "arrow.down.circle")
                        }
                    }
                } header: {
                    Text("Модель Qwen")
                } footer: {
                    Text("Скачивается один раз по Wi-Fi, дальше работает без сети вообще — и как "
                         + "свой собственный выбор, и как то, на что откатываются Yandex и GigaChat "
                         + "при сбое. Модель побольше переводит лучше, поменьше — отвечает быстрее.")
                }

                Section {
                    HStack {
                        Label("Звук идёт в", systemImage: "speaker.wave.2")
                        Spacer()
                        Text(interpreter.outputRouteName.isEmpty ? "—" : interpreter.outputRouteName)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                } footer: {
                    Text("Слушает микрофон очков, если они подключены, иначе — телефона. Звук "
                         + "перевода идёт в очки или наушники в полном качестве, когда они "
                         + "подключены; на динамике телефона микрофон услышит часть перевода "
                         + "обратно, поэтому гарнитуру лучше надеть.")
                }
            }
            .navigationTitle("Настройки перевода")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { showSettingsSheet = false }
                }
            }
        }
    }
}
