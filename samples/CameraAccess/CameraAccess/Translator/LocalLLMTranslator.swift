// VisionClaw - LocalLLMTranslator.swift
// A stronger offline translator than Apple's, running Qwen3 on-device through MLX.
//
// Why Qwen3 and not something built for translation
// -------------------------------------------------
// The obvious candidate was Meta's NLLB-200, the standard "offline translation model". It was
// rejected on two checked facts, not on taste:
//
//   * It is an encoder-decoder (seq2seq) model. mlx-swift-lm — already in this project, already
//     shipping the FastVLM download — runs decoder-only models. NLLB would mean bringing in a
//     second inference runtime (CTranslate2 or ONNX, neither of which has a maintained iOS build)
//     for one feature.
//   * Its strength is breadth: 200 languages, most of them low-resource. For English, Chinese and
//     Russian — the languages actually asked for — a modern instruction-tuned LLM is at least as
//     good, and NLLB's published weights are fp32 (2.5 GB before any quantisation work).
//
// Qwen3, by contrast, is already supported by the exact mlx-swift-lm revision this project pins
// (its registry ships ModelConfigurations pointing at these very repos), is trained heavily on
// Chinese and Russian, and comes pre-quantised to 4-bit.
//
// The real quality advantage is not the parameter count, though: a sentence-level MT model
// translates each phrase in isolation, so it loses pronoun antecedents, grammatical gender,
// formality and topic the moment a conversation gets going. An LLM gets the last few exchanges as
// context — see `recentContext` — which is what fixes "it" becoming the wrong gender in Russian.

import Foundation
import UIKit
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace   // #hubDownloader() / #huggingFaceTokenizerLoader() macros
import HuggingFace
import Tokenizers

/// The two size tiers offered. Sizes are the measured repo sizes, not estimates.
enum TranslatorModelTier: String, CaseIterable, Identifiable {
    case qwen3_1_7b
    case qwen3_4b

    var id: String { rawValue }

    var modelId: String {
        switch self {
        case .qwen3_1_7b: return "mlx-community/Qwen3-1.7B-4bit"
        case .qwen3_4b: return "mlx-community/Qwen3-4B-4bit"
        }
    }

    var label: String {
        switch self {
        case .qwen3_1_7b: return "Qwen3 1.7B — fast"
        case .qwen3_4b: return "Qwen3 4B — best quality"
        }
    }

    var expectedBytes: Int64 {
        switch self {
        case .qwen3_1_7b: return 980_000_000
        case .qwen3_4b: return 2_280_000_000
        }
    }

    var sizeText: String {
        switch self {
        case .qwen3_1_7b: return "0.98 GB"
        case .qwen3_4b: return "2.3 GB"
        }
    }

    static let defaultsKey = "translatorModelTier"
}

@MainActor
final class LocalLLMTranslator: ObservableObject {
    static let shared = LocalLLMTranslator()
    private init() {}

    @Published private(set) var isModelLoaded = false
    @Published private(set) var isLoadingModel = false
    @Published var downloadProgress: Double = 0
    @Published var isFinalizing = false
    @Published private(set) var lastError: String?

    private var modelContainer: ModelContainer?
    /// Which tier the container in memory belongs to, so switching tiers reloads rather than
    /// silently keeping the old weights.
    private var loadedTier: TranslatorModelTier?

    var tier: TranslatorModelTier {
        get {
            TranslatorModelTier(rawValue: UserDefaults.standard.string(forKey: TranslatorModelTier.defaultsKey) ?? "")
                ?? .qwen3_1_7b
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: TranslatorModelTier.defaultsKey)
            if loadedTier != newValue { unload() }
        }
    }

    var isDownloaded: Bool {
        Self.downloadedSizeBytes(for: tier) >= tier.expectedBytes / 2
    }

    // MARK: - Download / load

    func download(onProgress: @escaping (Double) -> Void) async throws {
        let tier = self.tier
        downloadProgress = 0
        isFinalizing = false
        let started = Date()
        let poller = Task.detached { [weak self] in
            while !Task.isCancelled {
                let bytes = Self.inFlightDownloadBytes(for: tier, since: started)
                let estimate = min(0.99, Double(bytes) / Double(max(tier.expectedBytes, 1)))
                await MainActor.run {
                    self?.downloadProgress = max(self?.downloadProgress ?? 0, estimate)
                    if estimate >= 0.99 { self?.isFinalizing = true }
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        defer {
            poller.cancel()
            isFinalizing = false
        }

        // Same retry-to-resume shape as FastVLMService: HubClient resumes with a Range request
        // from the last successful position, but only when the app itself retries.
        var lastFailure: Error?
        for attempt in 1...5 {
            do {
                let container = try await loadContainer(for: tier, progress: onProgress)
                modelContainer = container
                loadedTier = tier
                isModelLoaded = true
                downloadProgress = 1
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = error
                NSLog("[VisionClaw] translator download attempt %d/5 failed: %@", attempt, "\(error)")
                guard attempt < 5 else { break }
                try? await Task.sleep(nanoseconds: UInt64(min(30.0, pow(2.0, Double(attempt))) * 1_000_000_000))
            }
        }
        throw lastFailure ?? URLError(.unknown)
    }

    private func loadContainer(for tier: TranslatorModelTier,
                               progress: @escaping (Double) -> Void) async throws -> ModelContainer {
        let handler: (Progress) -> Void = { p in Task { @MainActor in progress(p.fractionCompleted) } }
        return try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: tier.modelId), progressHandler: handler)
    }

    func connect() async throws {
        let tier = self.tier
        if modelContainer != nil, loadedTier == tier { return }
        // Materialising weights touches Metal, which iOS forbids in the background; doing it there
        // raises an exception that cannot be caught.
        guard UIApplication.shared.applicationState != .background else {
            throw TranslatorError.backgrounded
        }
        guard isDownloaded else { throw TranslatorError.notDownloaded }
        Memory.cacheLimit = 20 * 1024 * 1024
        isLoadingModel = true
        defer { isLoadingModel = false }
        do {
            modelContainer = try await loadContainer(for: tier) { _ in }
            loadedTier = tier
            isModelLoaded = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func unload() {
        modelContainer = nil
        loadedTier = nil
        isModelLoaded = false
        Memory.clearCache()
    }

    // MARK: - Translating

    /// Translate one phrase.
    ///
    /// `recentContext` is the last few already-translated phrases, newest last. It is what makes
    /// this better than a sentence-level model rather than merely bigger: with the preceding turns
    /// in the prompt the model keeps gender, formality and referents consistent across a
    /// conversation instead of resetting at every full stop.
    /// `isFragment` switches the instructions for simultaneous mode, where chunks are cut on a
    /// word count rather than a sentence and routinely start and end mid-clause. Without it the
    /// model tries to round every fragment off into a sentence, which reads as stuttering
    /// repetition once the fragments are spoken back to back.
    func translate(_ text: String,
                   from sourceName: String,
                   to targetName: String,
                   recentContext: [String] = [],
                   isFragment: Bool = false) async throws -> String {
        if modelContainer == nil || loadedTier != tier {
            try await connect()
        }
        guard let container = modelContainer else { throw TranslatorError.notDownloaded }

        var system = """
            You are a simultaneous interpreter. Translate the user's \(sourceName) into \(targetName).
            Output ONLY the translation: no explanations, no transliteration, no quotes, no notes, \
            no original text. Keep the speaker's register and tone.
            """
        if isFragment {
            system += """
                \n
                You are interpreting a live stream of speech, so each input is a FRAGMENT cut out \
                of a sentence in progress. Translate only this fragment and only once. It may begin \
                or end mid-clause: leave it unfinished rather than inventing an ending, and do not \
                repeat or restate anything you already translated. Your output is spoken aloud \
                immediately after the previous fragment, so it must read as the continuation of it.
                """
        } else {
            system += " If a phrase is cut off mid-sentence, translate the fragment as it stands "
                + "rather than completing it."
        }
        if !recentContext.isEmpty {
            system += "\n\n" + (isFragment ? "What you have already said, in order (do not repeat "
                               + "any of it):" : "Earlier in this conversation (context only — do "
                               + "not translate these again):")
                + "\n" + recentContext.suffix(3).joined(separator: "\n")
        }
        // Qwen3 ships a reasoning mode that is on by default and emits a long <think> block before
        // the answer. For interpreting that is fatal: it turns a sub-second translation into many
        // seconds of invisible deliberation. /no_think switches it off.
        system += "\n/no_think"

        let input = UserInput(chat: [
            .init(role: .system, content: system),
            .init(role: .user, content: text),
        ])

        let stream = try await container.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: input)
            // Temperature 0: a translation should be the same every time, and sampling only adds
            // opportunities to drift off the source. maxTokens scales with the input because a
            // translation is never many times longer than its source, and an unbounded cap lets a
            // confused model ramble for seconds.
            let parameters = GenerateParameters(maxTokens: max(64, text.count), temperature: 0)
            return try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context)
        }

        var full = ""
        var iterator = stream.makeAsyncIterator()
        while let item = await iterator.next() {
            if UIApplication.shared.applicationState == .background { break }
            if case .chunk(let piece) = item { full += piece }
        }
        Memory.clearCache()
        return Self.cleaned(full)
    }

    /// Strips the leftovers small models add even when told not to: an empty `<think>` block from
    /// Qwen3's reasoning scaffold, and wrapping quotes.
    static func cleaned(_ raw: String) -> String {
        var text = raw
        if let end = text.range(of: "</think>") {
            text = String(text[end.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 1, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - On-disk management

    nonisolated private static func dirSizeBytes(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) {
            for case let f as URL in en {
                let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    nonisolated private static func repoDirectories(for tier: TranslatorModelTier) -> [URL] {
        guard let repoName = tier.modelId.split(separator: "/").last.map(String.init) else { return [] }
        let fm = FileManager.default
        var found: [URL] = []
        for dir in [FileManager.SearchPathDirectory.documentDirectory, .cachesDirectory, .applicationSupportDirectory] {
            guard let base = fm.urls(for: dir, in: .userDomainMask).first else { continue }
            let hf = base.appendingPathComponent("huggingface", isDirectory: true)
            guard let en = fm.enumerator(at: hf, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for case let url as URL in en
            where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                && url.lastPathComponent.localizedCaseInsensitiveContains(repoName) {
                found.append(url)
                en.skipDescendants()
            }
        }
        return found
    }

    nonisolated static func downloadedSizeBytes(for tier: TranslatorModelTier) -> Int64 {
        repoDirectories(for: tier).reduce(0) { $0 + dirSizeBytes($1) }
    }

    nonisolated private static func inFlightDownloadBytes(for tier: TranslatorModelTier, since start: Date) -> Int64 {
        var total = downloadedSizeBytes(for: tier)
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        if let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.creationDateKey]) {
            for item in items where item.lastPathComponent.hasPrefix("CFNetworkDownload_") {
                let created = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if created >= start { total += dirSizeBytes(item) }
            }
        }
        return total
    }

    func deleteDownloadedModel() async -> Bool {
        let tier = self.tier
        unload()
        return await Task.detached {
            let fm = FileManager.default
            var removed = false
            for url in Self.repoDirectories(for: tier) where fm.fileExists(atPath: url.path) {
                if (try? fm.removeItem(at: url)) != nil { removed = true }
            }
            return removed
        }.value
    }

    enum TranslatorError: LocalizedError {
        case notDownloaded
        case backgrounded

        var errorDescription: String? {
            switch self {
            case .notDownloaded:
                return "The translation model isn't on this phone yet. Download it from the translator screen."
            case .backgrounded:
                return "The model can't load while the app is in the background."
            }
        }
    }
}
