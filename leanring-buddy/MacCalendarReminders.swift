//
//  MacCalendarReminders.swift
//  leanring-buddy
//
//  "remind me at 5 to study" goes straight into Apple Reminders, and
//  events go straight into Apple Calendar — no Hermes trip. Uses EventKit;
//  macOS asks once for Reminders access and once for Calendar access.
//
//  Voice surface:
//    push-to-talk tags  [REMINDER: title | yyyy-MM-dd HH:mm]
//                       [EVENT: title | start | end]
//                       [SCHEDULE: today | tomorrow | yyyy-MM-dd]
//    Live tools         add_reminder, add_calendar_event, my_schedule
//
//  Creating a reminder or event is additive and local (nothing is sent to
//  other people), so it runs right away when the user asks. Deleting or
//  changing existing items is not implemented — that stays with the user.
//

import Combine
import EventKit
import Foundation

@MainActor
final class MacCalendarReminders: ObservableObject {
    static let shared = MacCalendarReminders()

    private let eventStore = EKEventStore()

    private init() {}

    // MARK: - Access

    private func ensureAccess(to entityType: EKEntityType) async -> Bool {
        let currentStatus = EKEventStore.authorizationStatus(for: entityType)
        if currentStatus == .fullAccess { return true }
        guard currentStatus == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in
            if entityType == .reminder {
                eventStore.requestFullAccessToReminders { isGranted, _ in
                    continuation.resume(returning: isGranted)
                }
            } else {
                eventStore.requestFullAccessToEvents { isGranted, _ in
                    continuation.resume(returning: isGranted)
                }
            }
        }
    }

    private static func accessDeniedMessage(for entityType: EKEntityType) -> String {
        entityType == .reminder
            ? "reminders access is off for orchestra. turn it on in system settings, privacy and security, reminders"
            : "calendar access is off for orchestra. turn it on in system settings, privacy and security, calendars"
    }

    // MARK: - Creating

    /// Adds a reminder (with an alarm at the due time, so it actually
    /// notifies). `whenText` may be empty for a reminder with no due date.
    func addReminder(title: String, whenText: String) async -> (succeeded: Bool, message: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return (false, "the reminder needs a title") }
        guard await ensureAccess(to: .reminder) else { return (false, Self.accessDeniedMessage(for: .reminder)) }
        guard let remindersCalendar = eventStore.defaultCalendarForNewReminders() else {
            return (false, "there's no reminders list set up on this mac")
        }
        let dueDate = Self.parseWhenText(whenText)
        if !whenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && dueDate == nil {
            return (false, "i couldn't read the time \"\(whenText)\"; use yyyy-MM-dd HH:mm")
        }
        let newReminder = EKReminder(eventStore: eventStore)
        newReminder.title = trimmedTitle
        newReminder.calendar = remindersCalendar
        if let dueDate {
            newReminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
            newReminder.addAlarm(EKAlarm(absoluteDate: dueDate))
        }
        do {
            try eventStore.save(newReminder, commit: true)
        } catch {
            OrchestraLog.write("⏰ Reminder save failed: \(error.localizedDescription)")
            return (false, "couldn't save the reminder: \(error.localizedDescription)")
        }
        let confirmation = dueDate.map { " for \(Self.spokenDateFormatter.string(from: $0))" } ?? ""
        OrchestraLog.write("⏰ Reminder added: \(trimmedTitle)\(confirmation)")
        return (true, "reminder \"\(trimmedTitle)\" added\(confirmation)")
    }

    /// Adds a calendar event. End defaults to one hour after the start.
    func addEvent(title: String, startText: String, endText: String) async -> (succeeded: Bool, message: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return (false, "the event needs a title") }
        guard let startDate = Self.parseWhenText(startText) else {
            return (false, "i couldn't read the start time \"\(startText)\"; use yyyy-MM-dd HH:mm")
        }
        let endDate = Self.parseWhenText(endText) ?? startDate.addingTimeInterval(3600)
        guard endDate > startDate else { return (false, "the event's end has to be after its start") }
        guard await ensureAccess(to: .event) else { return (false, Self.accessDeniedMessage(for: .event)) }
        guard let eventsCalendar = eventStore.defaultCalendarForNewEvents else {
            return (false, "there's no calendar set up on this mac")
        }
        let newEvent = EKEvent(eventStore: eventStore)
        newEvent.title = trimmedTitle
        newEvent.startDate = startDate
        newEvent.endDate = endDate
        newEvent.calendar = eventsCalendar
        do {
            try eventStore.save(newEvent, span: .thisEvent, commit: true)
        } catch {
            OrchestraLog.write("📅 Event save failed: \(error.localizedDescription)")
            return (false, "couldn't save the event: \(error.localizedDescription)")
        }
        let confirmation = "\(Self.spokenDateFormatter.string(from: startDate)) to \(Self.spokenDateFormatter.string(from: endDate))"
        OrchestraLog.write("📅 Event added: \(trimmedTitle) (\(confirmation))")
        return (true, "event \"\(trimmedTitle)\" added, \(confirmation)")
    }

    // MARK: - Reading the day

    /// Events and due reminders for one day, as plain text for the model to
    /// turn into a spoken answer.
    func scheduleSummary(dayText: String) async -> String {
        let dayStart = Self.startOfDay(forDayText: dayText)
        let dayEnd = dayStart.addingTimeInterval(86_400)
        let hasEventAccess = await ensureAccess(to: .event)
        let hasReminderAccess = await ensureAccess(to: .reminder)
        guard hasEventAccess || hasReminderAccess else {
            return "calendar and reminders access are both off for orchestra; turn them on in system settings, privacy and security"
        }
        var summaryLines: [String] = []
        if hasEventAccess {
            let eventsPredicate = eventStore.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
            let dayEvents = eventStore.events(matching: eventsPredicate).sorted { $0.startDate < $1.startDate }
            for dayEvent in dayEvents {
                let timeText = dayEvent.isAllDay
                    ? "all day"
                    : "\(Self.timeOnlyFormatter.string(from: dayEvent.startDate))–\(Self.timeOnlyFormatter.string(from: dayEvent.endDate))"
                let locationText = (dayEvent.location?.isEmpty == false) ? " @ \(dayEvent.location!)" : ""
                summaryLines.append("event \(timeText): \(dayEvent.title ?? "(busy)")\(locationText)")
            }
        } else {
            summaryLines.append("(calendar access is off, so events can't be read)")
        }
        if hasReminderAccess {
            let remindersPredicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: dayStart, ending: dayEnd, calendars: nil)
            let dueReminders = await withCheckedContinuation { (continuation: CheckedContinuation<[EKReminder], Never>) in
                eventStore.fetchReminders(matching: remindersPredicate) { fetchedReminders in
                    continuation.resume(returning: fetchedReminders ?? [])
                }
            }
            for dueReminder in dueReminders {
                let dueTimeText = dueReminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                    .map { Self.timeOnlyFormatter.string(from: $0) } ?? "no time"
                summaryLines.append("reminder \(dueTimeText): \(dueReminder.title ?? "(untitled)")")
            }
        } else {
            summaryLines.append("(reminders access is off, so reminders can't be read)")
        }
        let dayLabel = Self.dayLabelFormatter.string(from: dayStart)
        guard !summaryLines.isEmpty else { return "nothing on the mac's calendar or reminders for \(dayLabel)" }
        return "the user's mac calendar and reminders for \(dayLabel):\n" + summaryLines.joined(separator: "\n")
    }

    // MARK: - Date parsing

    /// Accepts what the model is told to emit ("yyyy-MM-dd HH:mm"), plus a
    /// few forgiving variants: ISO with T/seconds, date-only (09:00),
    /// "today 17:00", "tomorrow 09:00" and bare "HH:mm" (today).
    static func parseWhenText(_ whenText: String) -> Date? {
        let trimmedText = whenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }
        let normalizedText = trimmedText.lowercased()
        let calendar = Calendar.current

        var dayOffset = 0
        var timePartText = normalizedText
        if normalizedText.hasPrefix("today ") {
            timePartText = String(normalizedText.dropFirst("today ".count))
        } else if normalizedText.hasPrefix("tomorrow ") {
            dayOffset = 1
            timePartText = String(normalizedText.dropFirst("tomorrow ".count))
        }

        let dateTimeFormats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"]
        for dateFormat in dateTimeFormats {
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.dateFormat = dateFormat
            if let parsedDate = dateFormatter.date(from: timePartText) {
                return calendar.date(byAdding: .day, value: dayOffset, to: parsedDate)
            }
        }
        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        if let parsedDate = dateOnlyFormatter.date(from: timePartText) {
            let nineAMDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: parsedDate) ?? parsedDate
            return calendar.date(byAdding: .day, value: dayOffset, to: nineAMDate)
        }
        let timeOnlyFormatter = DateFormatter()
        timeOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeOnlyFormatter.dateFormat = "HH:mm"
        if let parsedTime = timeOnlyFormatter.date(from: timePartText) {
            let todayComponents = calendar.dateComponents([.year, .month, .day], from: Date())
            let timeComponents = calendar.dateComponents([.hour, .minute], from: parsedTime)
            var mergedComponents = DateComponents()
            mergedComponents.year = todayComponents.year
            mergedComponents.month = todayComponents.month
            mergedComponents.day = todayComponents.day
            mergedComponents.hour = timeComponents.hour
            mergedComponents.minute = timeComponents.minute
            return calendar.date(from: mergedComponents).flatMap { calendar.date(byAdding: .day, value: dayOffset, to: $0) }
        }
        return nil
    }

    private static func startOfDay(forDayText dayText: String) -> Date {
        let normalizedText = dayText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let calendar = Calendar.current
        if normalizedText == "tomorrow" {
            return calendar.startOfDay(for: Date().addingTimeInterval(86_400))
        }
        if let parsedDate = parseWhenText(normalizedText), normalizedText != "today" {
            return calendar.startOfDay(for: parsedDate)
        }
        return calendar.startOfDay(for: Date())
    }

    private static let spokenDateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE MMM d 'at' HH:mm"
        return dateFormatter
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm"
        return dateFormatter
    }()

    private static let dayLabelFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMM d"
        return dateFormatter
    }()
}
