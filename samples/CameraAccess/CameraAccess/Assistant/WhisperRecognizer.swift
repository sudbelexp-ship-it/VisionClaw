// VisionClaw - WhisperRecognizer.swift
// Speech recognition for languages Apple's on-device path won't cover -- starting with Russian.
//
// Apple Intelligence supports 16 languages, and Russian is not one of them; SpeechTranscriber's
// asset pipeline is gated to that list, which is the real cause behind the "Not Installing" error
// AudioCaptureHub already works around by resolving locales through supportedLocale(equivalentTo:)
// (see that file). That workaround can only surface the failure honestly -- it can't make Russian
// installable, because the model simply isn't offered for it. whisper.cpp sidesteps the allowlist
// entirely: it is a fully on-device, open-source (MIT) speech model with no per-language gate, and
// Whisper's multilingual training already covers Russian well.
//
// The binary comes straight from the project's own GitHub release, not a third-party mirror --
// build.gradle.kts's Android counterpart in this same fork pulls Vosk instead, but Vosk's iOS build
// is not publicly distributed (its own README says to email the maintainers for it), and the only
// public iOS binary found elsewhere was an unmaintained one-commit fork with no way to verify what
// it contains. whisper.cpp's release asset was downloaded and its SHA-256 checked by hand against
// the checksum in ggml-org/whisper.cpp's own README before it was vendored into Vendor/whisper.xcframework.
//
// The real tradeoff, and it is a real one: whisper.cpp has no volatile/final streaming contract the
// way SpeechAnalyzer does. It transcribes one already-finished chunk of audio at a time -- there is
// no live word-by-word preview. WhisperChannel in AudioCaptureHub.swift chunks speech by a pause
// (or a hard duration ceiling) and reports each chunk as a single final result; volatile callbacks
// simply never fire for a Russian listener. Confirmed acceptable for Russian specifically.

import Foundation
import whisper

/// Wraps one loaded ggml model and runs it against finished chunks of 16kHz mono float32 audio.
/// Not thread-safe for concurrent calls -- WhisperChannel serializes access through its own queue.
final class WhisperRecognizer {
    private let context: OpaquePointer

    init?(modelPath: String) {
        let params = whisper_context_default_params()
        guard let context = whisper_init_from_file_with_params(modelPath, params) else { return nil }
        self.context = context
    }

    deinit {
        whisper_free(context)
    }

    /// Blocking -- a several-second chunk can take real wall-clock time to decode. Call off the
    /// main thread.
    func transcribe(samples: [Float], languageCode: String) -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.translate = false
        // Each chunk is already one pause-delimited utterance, handed over independently: forcing
        // a single segment and refusing carry-over context keeps one chunk's transcription from
        // leaking words into the next.
        params.single_segment = true
        params.no_context = true
        params.suppress_blank = true
        params.n_threads = Int32(max(2, min(4, ProcessInfo.processInfo.activeProcessorCount)))

        return languageCode.withCString { languagePointer -> String in
            params.language = languagePointer
            let status = samples.withUnsafeBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return whisper_full(context, params, base, Int32(buffer.count))
            }
            guard status == 0 else { return "" }
            let segmentCount = whisper_full_n_segments(context)
            var text = ""
            for index in 0..<segmentCount {
                if let segment = whisper_full_get_segment_text(context, index) {
                    text += String(cString: segment)
                }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
