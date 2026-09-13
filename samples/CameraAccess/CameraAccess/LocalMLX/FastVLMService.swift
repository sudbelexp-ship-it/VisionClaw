// VisionClaw - FastVLMService.swift
// On-device vision-capable model, running fully locally via Apple MLX. FastVLM 0.5B only — the
// one model proven stable, through extensive real-device testing on a sister project
// (OpenVision), on this exact class of iPhone. Other candidates (SmolVLM2, a larger Qwen3 text
// tier) were tried there and crashed on-device; this is deliberately NOT a multi-model picker.
//
// Trimmed port of OpenVision's GemmaLocalService.swift (D:\OpenVision\OpenVision\Services\
// GemmaLocal\GemmaLocalService.swift): dropped the Qwen/Gemma/Bonsai text-only tiers (out of
// scope here), the JSON-based agentic router (LocalAgent: face/web-search/native-tool routing —
// this app just answers a question, it doesn't run an agent), the ChatSession/KV-cache "routing
// session" (no persistent conversation memory needed for a one-shot "ask" button), and the
// FastVLM-1.5B community-checkpoint config patches (patchFastVLMProcessorConfig /
// patchFastVLMConfigJSON / injected vision_config) — those exist ONLY to fix a broken community
// conversion of the 1.5B size; the 0.5B model used here is "the factory's reference build
// (config matches out of the box)," so none of that patching applies.
//
// NOTE: Requires a physical device — MLX is unavailable on the Simulator.

import Foundation
import UIKit
import MLX
import MLXVLM
import MLXLMCommon
import MLXHuggingFace   // #hubDownloader() / #huggingFaceTokenizerLoader() macros
import HuggingFace      // the macros expand to HuggingFace.HubClient …
import Tokenizers       // … and Tokenizers.AutoTokenizer

@MainActor
final class FastVLMService: ObservableObject {
    static let shared = FastVLMService()
    private init() {}

    static let modelId = "mlx-community/FastVLM-0.5B-bf16"
    /// Real on-disk size of the repo's single `model.safetensors` (1,245,513,874 B) plus
    /// tokenizer/config files, confirmed via the HuggingFace API — used only to estimate download
    /// progress from bytes on disk (the hub's own progress callback counts FILES, useless for a
    /// model that's mostly one giant safetensors).
    static let expectedDownloadBytes: Int64 = 1_270_000_000

    // MARK: - Published state

    @Published private(set) var isModelLoaded = false
    /// True while weights are being parsed and Metal shaders compiled on first use. That takes
    /// tens of seconds and shows no network activity, so the UI has to say what's happening or it
    /// reads as a hang.
    @Published private(set) var isLoadingModel = false
    @Published var downloadProgress: Double = 0
    /// True once the bytes on disk have reached the expected size but `loadModelContainer` hasn't
    /// returned yet — the remaining time is weight parsing / first-run Metal shader compilation,
    /// not network. Without this the UI would show "Downloading… 99%" indefinitely, which reads
    /// as a hang even though nothing is actually stuck.
    @Published var isFinalizing = false
    @Published private(set) var lastError: String?

    private var modelContainer: ModelContainer?
    private var cancelRequested = false
    private var generationID = 0   // bumped per request; stale generations stay silent

    // MARK: - Model store bootstrap (call once at app launch, before any HubClient exists)

    /// Point the HuggingFace hub cache at Application Support (not purged under storage pressure,
    /// unlike the default `Library/Caches` location — downloaded weights would otherwise silently
    /// vanish and re-download on the next connect) and sweep orphaned download temp files left
    /// behind by an interrupted download (none can be in flight at launch).
    nonisolated static func bootstrapModelStore() {
        let fm = FileManager.default
        let store = modelStoreURL
        try? fm.createDirectory(at: store, withIntermediateDirectories: true)

        var storeURL = store
        var noBackup = URLResourceValues()
        noBackup.isExcludedFromBackup = true
        try? storeURL.setResourceValues(noBackup)

        // Read at HubClient init — hence "before any HubClient".
        setenv("HF_HUB_CACHE", store.path, 1)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        if let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix("CFNetworkDownload_") {
                try? fm.removeItem(at: item)
            }
        }
    }

    nonisolated static var modelStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/hub", isDirectory: true)
    }

    // MARK: - Download

    private func bumpDownloadProgress(_ p: Double) {
        if p > downloadProgress { downloadProgress = p }
    }

    /// Download the model snapshot to disk (idempotent — skipped if already cached).
    func download(onProgress: @escaping (Double) -> Void) async throws {
        downloadProgress = 0
        isFinalizing = false
        let expected = max(Self.expectedDownloadBytes, 1)
        let started = Date()
        let poller = Task.detached { [weak self] in
            while !Task.isCancelled {
                let bytes = Self.inFlightDownloadBytes(since: started)
                let est = min(0.99, Double(bytes) / Double(expected))
                await MainActor.run {
                    self?.bumpDownloadProgress(est)
                    if est >= 0.99 { self?.isFinalizing = true }
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        defer {
            poller.cancel()
            isFinalizing = false
        }

        // Mobile networks often drop mid-download. HubClient (swift-huggingface) resumes a file
        // with a Range request from wherever the last SUCCESSFUL attempt stopped, but only if the
        // app itself retries after a drop — it doesn't retry on its own. Each retry below resumes
        // from the last saved position rather than starting over.
        let maxAttempts = 5
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                // Keep what the download already loaded. loadModelContainer both fetches the
                // weights AND materializes them; throwing that container away meant a freshly
                // downloaded model still counted as "not loaded" until something called
                // connect() — which nothing did.
                let container = try await loadModelContainer { p in onProgress(p) }
                modelContainer = container
                isModelLoaded = true
                downloadProgress = 1
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                NSLog("[VisionClaw] FastVLM download attempt %d/%d failed: %@", attempt, maxAttempts, "\(error)")
                guard attempt < maxAttempts else { break }
                let delaySeconds = min(30.0, pow(2.0, Double(attempt)))
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private func loadModelContainer(progress: @escaping (Double) -> Void) async throws -> ModelContainer {
        let configuration = ModelConfiguration(id: Self.modelId)
        let handler: (Progress) -> Void = { p in Task { @MainActor in progress(p.fractionCompleted) } }
        return try await VLMModelFactory.shared.loadContainer(
            from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
            configuration: configuration, progressHandler: handler)
    }

    // MARK: - Connect / disconnect (load / unload)

    /// Load the model into memory. Throws if it hasn't been downloaded yet (a multi-GB download
    /// should never kick off silently on a "connect").
    func connect() async throws {
        if modelContainer != nil { return }
        // Loading materializes model weights on the GPU (Metal), which iOS forbids in the
        // background — doing so raises an uncatchable exception that kills the app.
        guard UIApplication.shared.applicationState != .background else {
            throw FastVLMError.backgrounded
        }
        Memory.cacheLimit = 20 * 1024 * 1024
        isLoadingModel = true
        defer { isLoadingModel = false }
        do {
            let container = try await loadModelContainer { _ in }
            modelContainer = container
            isModelLoaded = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func disconnect() {
        modelContainer = nil
        isModelLoaded = false
    }

    // MARK: - Generation

    /// Ask a question, optionally about a photo, with earlier turns of the same conversation for
    /// context. History is text only: FastVLM 0.5B has a small context window, and re-feeding old
    /// images would spend most of it on pictures it has already described.
    func ask(text: String, imageData: Data?, history: [ChatTurn] = []) async throws -> String {
        guard UIApplication.shared.applicationState != .background else { throw FastVLMError.backgrounded }
        // Load on first use. Nothing else in the app calls connect(), so requiring it here just
        // made every question fail with "model isn't loaded" on a model that was sitting fully
        // downloaded on disk. Loading is idempotent and cheap once the container exists.
        if modelContainer == nil {
            guard Self.downloadedSizeBytes() >= Self.expectedDownloadBytes / 2 else {
                throw FastVLMError.notDownloaded
            }
            try await connect()
        }
        guard let container = modelContainer else { throw FastVLMError.modelNotLoaded }
        cancelRequested = false

        var visionImage: CIImage?
        if let imageData {
            visionImage = CIImage(data: imageData)
        }

        var systemContent = "You are a helpful voice assistant. Reply in 2-4 natural sentences — enough detail to be genuinely useful, but brief enough to hear comfortably. Be specific and concrete, not vague. No lists, no markdown, no preamble; just answer."
        // Hallucination defense: small on-device VLMs confidently invent details they can't see.
        // Telling FastVLM 0.5B to refuse on ANY uncertainty makes it refuse almost every turn
        // ("I don't have enough information") — it's rarely fully certain about anything. Ask for
        // its best honest read of the obvious/general scene instead, reserving "I can't tell" for
        // when the frame is genuinely unusable (confirmed via real on-device testing).
        if visionImage != nil {
            systemContent += " You are looking through a camera right now. Describe the general scene and the most obvious objects as your best honest read of this exact image — it's fine if some small details are uncertain, just don't confidently invent specifics you can't actually make out. Only say you can't tell if the image is genuinely too dark or blurry to describe at all."
        }

        var chat: [Chat.Message] = [.init(role: .system, content: systemContent)]
        // Only the last few turns: this model's context window is small enough that a long history
        // would crowd out the image tokens that matter most.
        for turn in history.suffix(4) {
            chat.append(.init(role: turn.role == .user ? .user : .assistant, content: turn.text))
        }
        if let visionImage {
            chat.append(.init(role: .user, content: text, images: [.ciImage(visionImage)]))
        } else {
            chat.append(.init(role: .user, content: text))
        }
        // No pre-shrink: FastVLM's FastViTHD encoder is built to ingest high-res frames cheaply
        // (few visual tokens), so downscaling would throw away its main advantage.
        let userInput = UserInput(chat: chat)

        generationID &+= 1
        let myID = generationID

        let stream = try await container.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            let parameters = GenerateParameters(maxTokens: 170, temperature: 0.4)
            return try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context)
        }

        var full = ""
        var iterator = stream.makeAsyncIterator()
        while true {
            if cancelRequested || myID != generationID { break }
            if UIApplication.shared.applicationState == .background { break }
            guard let item = await iterator.next() else { break }
            if case .chunk(let piece) = item { full += piece }
        }

        // Release the MLX buffer cache so vision memory doesn't pile up toward the jetsam limit.
        Memory.clearCache()

        if cancelRequested || myID != generationID { throw CancellationError() }
        return full.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Barge-in: stop streaming the current reply as soon as possible.
    func interrupt() {
        cancelRequested = true
    }

    // MARK: - On-disk model management

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

    /// Directories on disk belonging to the model's snapshot. The hub cache nests the repo id in
    /// the path, so match directories whose name contains the repo's own name.
    nonisolated private static func repoDirectories() -> [URL] {
        guard let repoName = Self.modelId.split(separator: "/").last.map(String.init) else { return [] }
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

    /// On-disk size in bytes for the model's snapshot.
    nonisolated static func downloadedSizeBytes() -> Int64 {
        repoDirectories().reduce(0) { $0 + dirSizeBytes($1) }
    }

    /// Bytes on disk attributable to an in-progress download: the partial snapshot plus
    /// CFNetwork's in-flight temp files. Only temps created after `start` count — stale orphans
    /// from a previously interrupted download would otherwise jump the progress bar to 99%.
    nonisolated private static func inFlightDownloadBytes(since start: Date) -> Int64 {
        var total = downloadedSizeBytes()
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

    /// Delete the model's snapshot from disk. Unloads it from memory first if it's loaded.
    func deleteDownloadedModel() async -> Bool {
        modelContainer = nil
        isModelLoaded = false
        Memory.clearCache()

        return await Task.detached {
            let fm = FileManager.default
            var removedAny = false
            for url in Self.repoDirectories() where fm.fileExists(atPath: url.path) {
                if (try? fm.removeItem(at: url)) != nil { removedAny = true }
            }
            return removedAny
        }.value
    }

    enum FastVLMError: LocalizedError {
        case notDownloaded
        case modelNotLoaded
        case backgrounded

        var errorDescription: String? {
            switch self {
            case .notDownloaded:
                return "The local model isn't on this phone yet. Download it in Settings → Local Model."
            case .modelNotLoaded:
                return "The local model failed to load into memory. Try again, or re-download it in Settings → Local Model."
            case .backgrounded:
                return "On-device AI can't run while the app is in the background. Bring VisionClaw to the foreground."
            }
        }
    }
}
