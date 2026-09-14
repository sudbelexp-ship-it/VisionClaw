// VisionClaw - ScheduleService.swift
// Напоминания и события календаря по голосовой фразе.
//
// Разбор даты/времени — не своя эвристика, а NSDataDetector с типом .date: это встроенный в iOS
// распознаватель естественного языка для дат, который Apple обучает и поддерживает для десятков
// языков, включая русский, и он уже умеет «завтра в девять», «в пятницу», «через час» — то, что
// самому пришлось бы писать месяцами и всё равно хуже. Если дата не найдена, напоминание создаётся
// без срока — это лучше отказа: голосом сказанное «напомни купить молоко» без даты тоже осмысленно.

import EventKit
import Foundation

@MainActor
final class ScheduleService {
    static let shared = ScheduleService()
    private init() {}

    private let store = EKEventStore()

    // MARK: Доступ

    private func ensureReminderAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .fullAccess { return }
        guard try await store.requestFullAccessToReminders() else {
            throw ScheduleError.accessDenied
        }
    }

    private func ensureEventAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { return }
        guard try await store.requestFullAccessToEvents() else {
            throw ScheduleError.accessDenied
        }
    }

    // MARK: Разбор фразы

    /// Что удалось вытащить из фразы: заголовок и, если распознана, дата.
    struct Parsed {
        let title: String
        let date: Date?
    }

    /// Ищет в тексте упоминание даты/времени средствами системы и возвращает оставшийся текст как
    /// заголовок. "напомни купить молоко завтра в девять утра" → дата = завтра 9:00,
    /// заголовок = "купить молоко".
    nonisolated static func parse(_ text: String) -> Parsed {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Parsed(title: trimmed, date: nil) }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return Parsed(title: trimmed, date: nil)
        }
        let matches = detector.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        guard let match = matches.first, let date = match.date, let range = Range(match.range, in: trimmed) else {
            return Parsed(title: trimmed, date: nil)
        }

        var title = trimmed
        title.removeSubrange(range)
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return Parsed(title: cleaned.isEmpty ? trimmed : cleaned, date: date)
    }

    // MARK: Напоминания

    @discardableResult
    func addReminder(from text: String) async throws -> String {
        try await ensureReminderAccess()
        let parsed = Self.parse(text)
        guard !parsed.title.isEmpty else { throw ScheduleError.emptyTitle }

        let reminder = EKReminder(eventStore: store)
        reminder.title = parsed.title
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let date = parsed.date {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }
        try store.save(reminder, commit: true)

        if let date = parsed.date {
            return "Напомню «\(parsed.title)» \(Self.spoken(date))."
        }
        return "Добавил напоминание «\(parsed.title)»."
    }

    // MARK: События календаря

    @discardableResult
    func addEvent(from text: String) async throws -> String {
        try await ensureEventAccess()
        let parsed = Self.parse(text)
        guard !parsed.title.isEmpty else { throw ScheduleError.emptyTitle }
        guard let date = parsed.date else {
            // Событие без времени — не событие, а напоминание в другой форме; честнее попросить
            // время ещё раз, чем молча поставить на "сейчас".
            throw ScheduleError.noDate
        }

        let event = EKEvent(eventStore: store)
        event.title = parsed.title
        event.startDate = date
        event.endDate = date.addingTimeInterval(3600)
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)

        return "Добавил в календарь «\(parsed.title)» \(Self.spoken(date))."
    }

    nonisolated private static func spoken(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("d MMMM, HH:mm")
        return "на \(formatter.string(from: date))"
    }

    enum ScheduleError: LocalizedError {
        case accessDenied
        case emptyTitle
        case noDate

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Нет доступа к календарю или напоминаниям. Разрешите его в настройках iOS."
            case .emptyTitle:
                return "Не расслышал, о чём напомнить."
            case .noDate:
                return "Не расслышал время события. Скажите, например, «встреча завтра в три»."
            }
        }
    }
}
