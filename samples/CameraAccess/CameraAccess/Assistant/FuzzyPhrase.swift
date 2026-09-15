// VisionClaw - FuzzyPhrase.swift
// Matching a spoken trigger phrase against what the recognizer actually heard, with room for it
// being slightly wrong.
//
// "окей сбер" comes back as "окей збер"; "салют" comes back as "солют"; "очки" comes back as
// "точки". None of these are recognition failures in any useful sense -- the person said the right
// word, and the model heard almost the right phonemes. An exact substring/prefix match treats
// "almost" as "no", which is why a phrase that reliably worked in testing started missing on real
// speech: the exact text handed to Locale-based matching is never guaranteed to be exactly what was
// said, only what the recognizer's best guess was.
//
// The fix is an edit-distance budget, not a bigger dictionary of alternate spellings: there's no
// way to enumerate every way "сбер" can come back garbled, but there is a cheap way to ask "is this
// close enough to be the same word."

import Foundation

enum FuzzyPhrase {
    /// Classic dynamic-programming edit distance: how many single-character insertions, deletions,
    /// or substitutions turn `a` into `b`.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[b.count]
    }

    /// How many edits a phrase this long can absorb before it risks becoming a different phrase.
    /// A 2-3 letter word has no slack at all -- "да" misheard as "та" is a different word, not a
    /// typo of the same one. "очки"/"сбер"-length words (4-6 letters) get exactly one, which is the
    /// single-vowel substitution that motivated this file. Longer phrases scale up slowly: more
    /// letters means more chances for one of them to come back wrong, not a licence to match
    /// anything vaguely similar.
    private static func tolerance(forLength length: Int) -> Int {
        switch length {
        case 0...3: return 0
        case 4...6: return 1
        default: return length / 5
        }
    }

    /// Looks for `phrase` in `text` (both already run through GlassesAssistant.normalize) allowing
    /// for misheard letters, and returns whatever comes after the match, trimmed. `anchored`
    /// restricts the search to the very start of `text` -- hot commands must not fire from the
    /// middle of a sentence, but the wake phrase can be addressed after a filler word or two.
    ///
    /// Word count is allowed to be off by one either way along with the letter-level fuzzing: a
    /// word can be dropped or an extra one inserted by the recognizer independently of any single
    /// word being misheard, and conflating the two into one edit-distance budget on the whole
    /// phrase would either miss real word-count slips or let through much sloppier matches to
    /// compensate.
    static func matchAndConsume(_ phrase: String, in text: String, anchored: Bool) -> String? {
        let needleWords = phrase.split(separator: " ").map(String.init)
        guard !needleWords.isEmpty else { return nil }
        let textWords = text.split(separator: " ").map(String.init)
        guard textWords.count >= 1 else { return nil }

        let needleJoined = needleWords.joined(separator: " ")
        let budget = tolerance(forLength: needleJoined.count)
        let windowSizes = Set([needleWords.count - 1, needleWords.count, needleWords.count + 1])
            .filter { $0 > 0 && $0 <= textWords.count }
            .sorted()
        guard !windowSizes.isEmpty else { return nil }

        let starts = anchored ? [0] : Array(0..<textWords.count)
        for start in starts {
            for size in windowSizes {
                let end = start + size
                guard end <= textWords.count else { continue }
                let window = textWords[start..<end].joined(separator: " ")
                guard levenshtein(window, needleJoined) <= budget else { continue }
                return textWords[end...].joined(separator: " ")
            }
        }
        return nil
    }
}
