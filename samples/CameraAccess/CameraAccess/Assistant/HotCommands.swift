// VisionClaw - HotCommands.swift
// Phrases that act on their own, without the trigger word in front of them.
//
// The trigger phrase ("окей клод, что ты видишь") is deliberate: you address the assistant, then
// ask. A hot command is the opposite — you just say it, the way you would say "следующий трек" at
// a smart speaker without naming it first. That convenience is exactly what makes it risky, since
// anything said near the phone is now a potential command, so:
//
//   * matching is on the WHOLE remaining utterance, not a substring of a longer sentence, so
//     "потом включи переводчик кому-нибудь" does not fire "включи переводчик";
//   * longer phrases are tested first, so "выключи переводчик" can never be swallowed by a
//     shorter "переводчик";
//   * every command is editable and removable, because the right words are the user's, not ours.
//
// Music control is deliberately absent. iOS gives an app no way to drive another app's playback:
// Apple Music is reachable through MPMusicPlayerController, Spotify only through Spotify's own SDK
// and an explicit sign-in, and Yandex Music not at all. A "next track" that silently worked for one
// player out of three would be worse than not having it.

import Foundation

struct HotCommand: Codable, Identifiable, Equatable {
    enum Action: String, Codable, CaseIterable, Identifiable {
        case translatorOn
        case translatorOff
        case weather
        case ask
        case reminder
        case calendarEvent

        var id: String { rawValue }

        var label: String {
            switch self {
            case .translatorOn: return "Включить переводчик"
            case .translatorOff: return "Выключить переводчик"
            case .weather: return "Погода"
            case .ask: return "Спросить модель"
            case .reminder: return "Напоминание"
            case .calendarEvent: return "Событие в календаре"
            }
        }

        /// Whether the words after the phrase are the command's argument rather than noise.
        /// "какая погода" + "в Белгороде" is one command; "включи переводчик" takes nothing.
        var takesArgument: Bool {
            switch self {
            case .weather, .ask, .reminder, .calendarEvent: return true
            case .translatorOn, .translatorOff: return false
            }
        }
    }

    var id: UUID
    var phrase: String
    var action: Action
    var isEnabled: Bool

    init(id: UUID = UUID(), phrase: String, action: Action, isEnabled: Bool = true) {
        self.id = id
        self.phrase = phrase
        self.action = action
        self.isEnabled = isEnabled
    }
}

@MainActor
final class HotCommandStore: ObservableObject {
    static let shared = HotCommandStore()

    @Published var commands: [HotCommand] {
        didSet { save() }
    }

    private static let key = "hotCommands"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([HotCommand].self, from: data) {
            commands = decoded
        } else {
            commands = Self.defaults
        }
    }

    /// Russian by default because that is the language the phone and the user are in; every one of
    /// them is editable, and several spellings of the same intent are listed separately rather than
    /// guessed at, since dictation transcribes each differently.
    static let defaults: [HotCommand] = [
        .init(phrase: "включи переводчик", action: .translatorOn),
        .init(phrase: "включи синхронный перевод", action: .translatorOn),
        .init(phrase: "выключи переводчик", action: .translatorOff),
        .init(phrase: "выключи синхронный перевод", action: .translatorOff),
        .init(phrase: "какая сегодня погода", action: .weather),
        .init(phrase: "какая погода", action: .weather),
        .init(phrase: "напомни", action: .reminder),
        .init(phrase: "поставь напоминание", action: .reminder),
        .init(phrase: "добавь в календарь", action: .calendarEvent),
        .init(phrase: "запланируй", action: .calendarEvent),
    ]

    private func save() {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func resetToDefaults() {
        commands = Self.defaults
    }

    // MARK: Matching

    struct Match {
        let command: HotCommand
        /// Whatever followed the phrase — the city for a weather command, the question for an ask.
        let argument: String
    }

    /// Find a command at the start of `utterance`.
    ///
    /// Anchored to the beginning rather than searched for anywhere inside: a phrase that merely
    /// occurs in the middle of a sentence is almost always someone talking about it, not issuing it.
    func match(in utterance: String) -> Match? {
        let text = GlassesAssistant.normalize(utterance)
        guard !text.isEmpty else { return nil }

        // Longest first: "выключи переводчик" must win over a shorter phrase that is its prefix.
        let candidates = commands
            .filter(\.isEnabled)
            .sorted { $0.phrase.count > $1.phrase.count }

        for command in candidates {
            let needle = GlassesAssistant.normalize(command.phrase)
            // Fuzzy, not an exact prefix: the recognizer misspells a phrase often enough ("окей
            // сбер" as "окей збер") that requiring an exact match made commands that worked in
            // testing silently stop firing on real speech. See FuzzyPhrase.
            guard !needle.isEmpty,
                  let rest = FuzzyPhrase.matchAndConsume(needle, in: text, anchored: true)
            else { continue }
            // A command that takes no argument must be the whole utterance, or "выключи переводчик
            // а потом позвони маме" would hang up the translator and swallow the rest.
            if !command.action.takesArgument, !rest.isEmpty { continue }
            return Match(command: command, argument: rest)
        }
        return nil
    }
}
