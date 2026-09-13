// VisionClaw - AudioCaptureHub.swift
// Один микрофон, один аудиодвижок и распознавание речи для всех, кто слушает.
//
// Почему не SFSpeechRecognizer
// ---------------------------
// Раньше здесь был он, и это была ошибка в основании. У Apple задокументировано: одна минута аудио
// на запрос и 1000 запросов в час на устройство, и прямо сказано, что этот API не предназначен для
// постоянного прослушивания и не поддерживает ключевые фразы. У нас три одновременных слушателя, и
// каждый перезапускался после каждой законченной фразы — лимит выжигался за минуты, после чего
// распознавание МОЛЧА переставало работать. Отсюда росли сразу три жалобы: переводчик замолкал
// после пары фраз, эфир переставал слышать вопросы, фраза-триггер не срабатывала вовсе.
//
// Замена — SpeechAnalyzer из iOS 26: длинное аудио без ограничения в минуту, целиком на устройстве,
// со скачиваемой моделью языка. Он же снимает второй костыль: результаты приходят разделёнными на
// volatile (черновик, который ещё будет переписан) и final (закреплённый кусок). Раньше границу
// фраз приходилось вычислять самим по громкости и индексам в транскрипте; теперь её проводит сама
// модель, а вместе с индексами исчезает целый класс ошибок рассинхронизации.
//
// Один вход на всех
// -----------------
// iOS даёт приложению один активный вход: «only one physical input is active at a time». Два
// AVAudioEngine означали, что второй молча не получал ничего. Захват всегда с микрофона телефона,
// воспроизведение всегда остаётся на A2DP в полном качестве, а модули распознавания читают общий
// поток буферов — по одному каналу на язык.

import AVFoundation
import Foundation
import Speech

@MainActor
final class AudioCaptureHub: ObservableObject {
    static let shared = AudioCaptureHub()
    private init() {}

    @Published private(set) var outputRouteName = ""
    @Published private(set) var isRunning = false
    /// Микрофон отдан системе, потому что звук занят другим приложением.
    @Published private(set) var isSuspended = false
    /// Языковая модель скачивается — первый запуск на новом языке требует сети.
    @Published private(set) var isPreparingModel = false

    /// Один слушатель: язык плюс то, что он хочет получать.
    ///
    /// Контракт намеренно построен на volatile/final, а не на «вот весь текст, разбирайся сам».
    /// Каждый закреплённый кусок приходит РОВНО ОДИН РАЗ, поэтому потребителю не нужно помнить,
    /// сколько он уже прочитал, — а именно это забывание и ломало всё раньше.
    final class Listener {
        let id = UUID()
        let locale: Locale
        /// Закреплённый кусок речи. Приходит один раз и больше не меняется.
        let onFinal: (String) -> Void
        /// Черновой хвост: текст, который модель ещё может переписать. Показывать можно,
        /// принимать по нему решения — нет.
        let onVolatile: ((String) -> Void)?
        /// Громкость и длительность буфера — для тех, кому нужна собственная пауза.
        let onLevel: ((Float, Double) -> Void)?

        init(locale: Locale,
             onFinal: @escaping (String) -> Void,
             onVolatile: ((String) -> Void)? = nil,
             onLevel: ((Float, Double) -> Void)? = nil) {
            self.locale = locale
            self.onFinal = onFinal
            self.onVolatile = onVolatile
            self.onLevel = onLevel
        }
    }

    /// Распознавание для одного языка. Слушатели с одним языком делят канал.
    private final class Channel {
        let locale: Locale
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
        /// Формат, которого ждёт анализатор: сам он вход не пересэмплирует.
        let analysisFormat: AVAudioFormat
        var resultsTask: Task<Void, Never>?
        var listeners: [Listener] = []
        var converter: AVAudioConverter?

        init(locale: Locale, transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer,
             inputBuilder: AsyncStream<AnalyzerInput>.Continuation, analysisFormat: AVAudioFormat) {
            self.locale = locale
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.inputBuilder = inputBuilder
            self.analysisFormat = analysisFormat
        }
    }

    private let engine = AVAudioEngine()
    private var channels: [Channel] = []
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var otherAudioTimer: Timer?

    /// Движок, чтобы переводчик мог подключить к нему воспроизведение.
    var audioEngine: AVAudioEngine { engine }

    // MARK: Слушатели

    @discardableResult
    func addListener(locale: Locale,
                     onFinal: @escaping (String) -> Void,
                     onVolatile: ((String) -> Void)? = nil,
                     onLevel: ((Float, Double) -> Void)? = nil) async throws -> Listener {
        // Резолв через SpeechTranscriber, а не сырой Locale(identifier:). Это не формальность:
        // без него скачивание может тихо кончиться состоянием "Not Installing" — assetInstallationRequest
        // берёт «поддерживаемый» локаль за чистую монету, а сервер потом не находит под него
        // готового ассета. supportedLocale(equivalentTo:) сверяется с реально доступными сборками
        // и подбирает совпадающий вариант (например, другой региональный код) вместо этого.
        let resolved = try await ensureLanguageModel(for: locale)

        let listener = Listener(locale: resolved, onFinal: onFinal,
                                onVolatile: onVolatile, onLevel: onLevel)
        if !isRunning {
            try startEngine()
        }
        // Один язык — один канал: эфир и фраза-триггер слушают одно и то же и не должны
        // резервировать языковую модель дважды.
        if let existing = channels.first(where: { $0.locale.identifier == resolved.identifier }) {
            existing.listeners.append(listener)
        } else {
            let channel = try await makeChannel(locale: resolved)
            channel.listeners.append(listener)
            channels.append(channel)
        }
        return listener
    }

    func removeListener(_ listener: Listener?) {
        guard let listener else { return }
        for channel in channels {
            channel.listeners.removeAll { $0.id == listener.id }
        }
        // Канал без слушателей закрывается: языковая модель — ограниченный ресурс, держать её
        // занятой «на всякий случай» мешает другому языку получить свою.
        for channel in channels where channel.listeners.isEmpty { close(channel) }
        channels.removeAll { $0.listeners.isEmpty }
        if channels.isEmpty { stopEngine() }
    }

    // MARK: Языковая модель

    /// Резолвит `locale` в реально поддерживаемый и скачивает его модель, если её ещё нет.
    ///
    /// Отдельный метод, а не часть makeChannel: кнопка «Скачать» в настройках должна уметь
    /// подготовить язык заранее, до первого включения микрофона, без запуска аудиодвижка —
    /// минутное скачивание не должно всплывать сюрпризом посреди разговора или срывать первую
    /// попытку что-то спросить.
    ///
    /// Резолв через SpeechTranscriber.supportedLocale(equivalentTo:), а не сырой
    /// Locale(identifier:), — не формальность: без него скачивание может тихо кончиться
    /// состоянием "Not Installing", потому что assetInstallationRequest берёт «поддерживаемый»
    /// локаль за чистую монету, а сервер потом не находит под него готового ассета.
    /// supportedLocale(equivalentTo:) сверяется с реально доступными сборками и подбирает
    /// совпадающий вариант вместо этого.
    @discardableResult
    func ensureLanguageModel(for locale: Locale) async throws -> Locale {
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw HubError.unsupportedLanguage(locale.identifier)
        }

        let alreadyInstalled = await SpeechTranscriber.installedLocales
        if alreadyInstalled.contains(where: { $0.identifier == resolved.identifier }) {
            return resolved
        }

        let transcriber = SpeechTranscriber(locale: resolved, preset: .progressiveTranscription)
        // nil здесь означает «уже установлена между проверками выше и этой строкой», а не ошибку.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            isPreparingModel = true
            defer { isPreparingModel = false }
            try await request.downloadAndInstall()
        }

        // На форуме Apple разработчики (подтверждено их же сотрудником) сообщают, что
        // supportedLocale() иногда называет язык поддерживаемым, а установка после этого тихо
        // проваливается — install-заявка зависает в "Not Installing", и downloadAndInstall() не
        // бросает исключение. Проверяем итог явно, чтобы получить понятную ошибку вместо
        // молчаливо неработающего микрофона.
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier == resolved.identifier }) else {
            throw HubError.assetNotInstalled(resolved.identifier)
        }
        return resolved
    }

    // MARK: Канал распознавания

    private func makeChannel(locale: Locale) async throws -> Channel {
        // Модель уже гарантированно установлена вызывающей стороной (ensureLanguageModel).
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        let naturalFormat = engine.inputNode.inputFormat(forBus: 0)
        // Частоту дискретизации нельзя задавать самим: анализатор её не приводит, а маршрут
        // (динамик, гарнитура, очки) меняет её без предупреждения.
        guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: naturalFormat
        ) else {
            throw HubError.noCompatibleFormat
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: analysisFormat)
        try await analyzer.start(inputSequence: inputSequence)

        let channel = Channel(locale: locale, transcriber: transcriber, analyzer: analyzer,
                              inputBuilder: inputBuilder, analysisFormat: analysisFormat)

        channel.resultsTask = Task { [weak channel] in
            guard let channel else { return }
            do {
                for try await result in channel.transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run {
                        for listener in channel.listeners {
                            if isFinal {
                                listener.onFinal(text)
                            } else {
                                listener.onVolatile?(text)
                            }
                        }
                    }
                }
            } catch {
                NSLog("[VisionClaw] распознавание %@ остановилось: %@", locale.identifier, "\(error)")
            }
        }
        return channel
    }

    private func close(_ channel: Channel) {
        // Порядок важен: сначала перестаём подавать аудио, потом закрываем поток, потом ждём
        // финализации. Иначе финализация повиснет, ожидая вход, которого уже никто не даёт.
        channel.inputBuilder.finish()
        let analyzer = channel.analyzer
        let task = channel.resultsTask
        Task {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            task?.cancel()
        }
    }

    // MARK: Движок

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        // Без .defaultToSpeaker: он прибивает вывод к встроенному динамику на всю категорию и
        // перебивает очки. Без .allowBluetooth: HFP отдал бы нам микрофон гарнитуры и утащил бы
        // туда же воспроизведение. .mixWithOthers — сессия открыта весь день, приглушать чужое
        // всё это время незачем.
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
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Буфер из аудиоколбэка нельзя считать неизменным после возврата: он вернётся в пул и
            // будет перезаписан. Поэтому громкость считается здесь, синхронно, а дальше уходит уже
            // собственная копия.
            let seconds = Double(buffer.frameLength) / format.sampleRate
            var rms: Float = 0
            if let channelData = buffer.floatChannelData?[0] {
                var sum: Float = 0
                let count = Int(buffer.frameLength)
                for i in 0..<count { sum += channelData[i] * channelData[i] }
                rms = count > 0 ? sqrt(sum / Float(count)) : 0
            }
            // Одна независимая копия прямо здесь. Дальше её уже можно безопасно передать через
            // границу актора: исходный буфер вернётся в пул и будет перезаписан сразу после
            // выхода из колбэка.
            guard let copy = Self.independentCopy(buffer) else { return }
            Task { @MainActor in self.dispatch(copy, rms: rms, seconds: seconds) }
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        isSuspended = false
    }

    /// Побайтовая копия буфера в его же формате, безопасная для передачи куда угодно.
    private nonisolated static func independentCopy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                          frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<Int(buffer.format.channelCount) {
                dst[ch].update(from: src[ch], count: frames)
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<Int(buffer.format.channelCount) {
                dst[ch].update(from: src[ch], count: frames)
            }
        } else {
            return nil
        }
        return copy
    }

    /// Раздать копию каналам, приведя её к формату каждого. Конвертация здесь, а не на очереди
    /// аудио: у каждого канала свой AVAudioConverter, а он не потокобезопасен.
    private func dispatch(_ buffer: AVAudioPCMBuffer, rms: Float, seconds: Double) {
        for channel in channels {
            guard let converted = Self.convert(buffer, to: channel.analysisFormat,
                                               using: &channel.converter) else { continue }
            channel.inputBuilder.yield(AnalyzerInput(buffer: converted))
            for listener in channel.listeners {
                listener.onLevel?(rms, seconds)
            }
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                to format: AVAudioFormat,
                                using converter: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        if buffer.format.isEqual(format) {
            guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else {
                return nil
            }
            copy.frameLength = buffer.frameLength
            if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                for ch in 0..<Int(format.channelCount) {
                    dst[ch].update(from: src[ch], count: Int(buffer.frameLength))
                }
            }
            return copy
        }
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
        // Молча проглоченный сбой конвертации выглядит как «микрофон не слышит», поэтому он в лог.
        if let error {
            NSLog("[VisionClaw] не удалось преобразовать аудио: %@", "\(error)")
            return nil
        }
        return out.frameLength > 0 ? out : nil
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

    // MARK: Уступить микрофон чужому звуку

    /// Отдать микрофон, пока играет что-то другое, и забрать обратно потом.
    ///
    /// Две причины, и первая неочевидна. A2DP односторонний и не может нести звук в обе стороны,
    /// поэтому на многих устройствах ЛЮБОЙ активный вход роняет Bluetooth до HFP 8 кГц — музыка,
    /// подкаст или звонок звучали бы в телефонном качестве всё время, пока приложение слушает.
    /// Вторая проще: под музыку распознаватель транскрибирует слова песни, и рано или поздно
    /// строчка совпадёт с командой.
    private func observeOtherAudio() {
        guard otherAudioTimer == nil else { return }
        otherAudioTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcileWithOtherAudio() }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                if type == .began { self?.suspend() } else { self?.reconcileWithOtherAudio() }
            }
        }
    }

    private func reconcileWithOtherAudio() {
        guard !channels.isEmpty else { return }
        let othersPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying
        if othersPlaying, !isSuspended {
            suspend()
        } else if !othersPlaying, isSuspended {
            resume()
        }
    }

    /// Приостановка снимает только подачу аудио. Каналы остаются живыми: пересоздавать их значило
    /// бы заново резервировать языковую модель на каждую паузу в музыке.
    private func suspend() {
        guard !isSuspended else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false
        isSuspended = true
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resume() {
        guard isSuspended, !channels.isEmpty else { return }
        do {
            try startEngine()
        } catch {
            NSLog("[VisionClaw] не удалось вернуть микрофон: %@", "\(error)")
        }
    }

    // MARK: Маршрут

    nonisolated static func hasExternalOutput(_ session: AVAudioSession) -> Bool {
        session.currentRoute.outputs.contains {
            $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
        }
    }

    private func applyOutputRoute() {
        let session = AVAudioSession.sharedInstance()
        if Self.hasExternalOutput(session) {
            try? session.overrideOutputAudioPort(.none)
        } else {
            try? session.overrideOutputAudioPort(.speaker)
        }
        outputRouteName = session.currentRoute.outputs.first?.portName ?? ""
    }

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
        case noCompatibleFormat
        case unsupportedLanguage(String)
        case assetNotInstalled(String)

        var errorDescription: String? {
            switch self {
            case .noMicrophone:
                return "Нет доступного микрофона."
            case .noCompatibleFormat:
                return "Не удалось подобрать формат звука для распознавания."
            case .unsupportedLanguage(let id):
                return "Распознавание \(id) на этом телефоне недоступно."
            case .assetNotInstalled(let id):
                return "Не удалось установить языковую модель \(id). Попробуйте ещё раз позже — "
                    + "иногда сервер Apple временно не отдаёт пакет для этого языка."
            }
        }
    }
}
