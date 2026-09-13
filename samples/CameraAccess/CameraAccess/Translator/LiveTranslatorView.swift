// VisionClaw - LiveTranslatorView.swift
// The simultaneous-interpreter screen. The pipeline itself lives in SimultaneousInterpreter.swift;
// this is the part you look at and touch.
//
// Where the work happens
// ----------------------
// Listening and speaking are always on the device; only the translation itself may leave it. The
// two offline translators were tried first and neither was good enough, so a hosted model now does
// the job whenever the network allows and Qwen3 takes over the moment it doesn't -- a translator is
// most needed abroad, which is exactly where the signal is worst, so it can never simply stop.
//
//   речь -> текст    SpeechAnalyzer (iOS 26), целиком на устройстве
//   text -> text     GigaChat/YandexGPT when reachable, else Qwen3 through MLX, or Apple's
//                    Translation framework -- see TranslatorEngine and CloudTranslator
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
    /// Hosted model when the network allows, Qwen3 the instant it doesn't. The default: it is the
    /// only option that is both good enough in a cafe with Wi-Fi and still working on a mountain.
    case hybrid
    case localLLM
    case apple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hybrid: return "Облако + запас офлайн"
        case .localLLM: return "Только Qwen3 на устройстве"
        case .apple: return "Переводчик Apple"
        }
    }

    var blurb: String {
        switch self {
        case .hybrid:
            return "GigaChat или YandexGPT, пока есть сеть, и Qwen3 автоматически, когда её нет. "
                + "Лучшее качество; расходует токены всё время разговора."
        case .localLLM:
            return "Не покидает телефон и ничего не стоит. Слабее на идиомах и порядке слов."
        case .apple:
            return "Встроен, качать нечего. Переводит по предложениям и буквально — с обрывками, "
                + "которые даёт этот режим, справляется хуже всех."
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
    @AppStorage("translatorEngine") private var engineRaw = TranslatorEngine.hybrid.rawValue
    @AppStorage("translatorPace") private var paceRaw = InterpreterPace.balanced.rawValue

    @State private var configuration: TranslationSession.Configuration?
    @State private var isDownloadingModel = false
    @State private var showEngineSheet = false
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
    private var translationEngine: TranslatorEngine {
        TranslatorEngine(rawValue: engineRaw) ?? .hybrid
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
            // SwiftUI vends the Apple translation session only through this modifier, so the whole
            // chunk pump lives inside it regardless of which engine is selected.
            .translationTask(configuration) { session in
                do {
                    // Only Apple's path needs a language pack; preparing unconditionally asked a
                    // Qwen3 user to download one they will never use.
                    // Only Apple's path needs a language pack; preparing unconditionally asked
                    // everyone else to download one they will never use.
                    if translationEngine == .apple {
                        try await session.prepareTranslation()
                    }
                    for await id in interpreter.pending {
                        guard let chunk = interpreter.chunk(id) else { continue }
                        let context = interpreter.chunks.compactMap(\.translated).suffix(3).map { $0 }
                        let text: String
                        switch translationEngine {
                        case .apple:
                            text = try await session.translate(chunk.original).targetText
                        case .localLLM:
                            text = try await llm.translate(
                                chunk.original, from: source.name, to: target.name,
                                recentContext: context, isFragment: true)
                        case .hybrid:
                            text = try await cloud.translate(
                                chunk.original, from: source.name, to: target.name,
                                recentContext: context)
                        }
                        interpreter.complete(id, with: text, language: target.id, speak: speakAloud)
                        persist(force: false)
                    }
                } catch {
                    interpreter.errorText = error.localizedDescription
                }
            }
            .sheet(isPresented: $showEngineSheet) { engineSheet }
            .task(id: "\(sourceId)-\(targetId)") { await refreshConfiguration() }
            .onChange(of: paceRaw) { _, _ in applyPace() }
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
            // choosing languages, keeps it off the first chunk of a live conversation.
            .task(id: engineRaw) {
                if translationEngine != .apple, llm.isDownloaded, !llm.isModelLoaded {
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
                    if translationEngine == .hybrid, cloud.requestCount > 0 {
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
            Text("Направьте телефон на говорящего")
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
            Picker("Темп", selection: $paceRaw) {
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
                        Text("— не скачана").foregroundStyle(.orange)
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
                    Text("Чем переводить")
                }

                if translationEngine == .hybrid {
                    Section {
                        Picker("Сервис", selection: Binding(get: { cloud.service },
                                                             set: { cloud.service = $0 })) {
                            ForEach(CloudTranslator.Service.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        if !cloud.service.isConfigured {
                            Label("Ключ не задан — переводить будет Qwen3",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if let reason = cloud.lastFallbackReason {
                            // Silent fallback is the right behaviour mid-conversation, but the user
                            // still deserves to find out why the quality changed.
                            Label("Последний откат: \(reason)", systemImage: "arrow.uturn.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Облачный сервис")
                    } footer: {
                        Text("Ключи — в Настройках, раздел «Модель». Выбранный сервис переводит, "
                             + "пока доступен; любой сбой молча переключает на модель ниже, не "
                             + "прерывая разговор.")
                    }
                }

                if translationEngine != .apple {
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
                            Button {
                                isDownloadingModel = true
                                Task {
                                    do { try await llm.download { _ in } }
                                    catch { interpreter.errorText = error.localizedDescription }
                                    isDownloadingModel = false
                                }
                            } label: {
                                Label("Скачать \(llm.tier.sizeText)", systemImage: "arrow.down.circle")
                            }
                        }
                    } header: {
                        Text(translationEngine == .hybrid ? "Offline fallback model" : "On-device model")
                    } footer: {
                        Text(translationEngine == .hybrid
                             ? "Используется, когда облако недоступно. Без неё потеря сети означает "
                               + "потерю перевода целиком."
                             : "Скачивается один раз по Wi-Fi, дальше работает без сети вообще. "
                               + "Модель побольше переводит лучше, поменьше — отвечает быстрее.")
                    }
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
                    Text("Слушает всегда микрофон телефона — направьте его на говорящего. Звук "
                         + "идёт в очки или наушники в полном качестве, когда они подключены. На "
                         + "динамике телефона микрофон услышит часть перевода обратно, поэтому "
                         + "гарнитуру лучше надеть.")
                }
            }
            .navigationTitle("Движок перевода")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { showEngineSheet = false }
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
