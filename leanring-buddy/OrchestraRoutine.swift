//
//  OrchestraRoutine.swift
//  leanring-buddy
//
//  Repeating jobs ("every weekday at 8:30, summarize my unread email").
//  Our own take on HeyClicky's routines tool. A routine is just a saved
//  brief + where it runs (Hermes or this Mac) + a simple schedule:
//
//    daily 08:30
//    weekdays 08:30
//    monday 09:00        (any weekday name)
//    every 2 hours
//    every 30 minutes    (minimum 15)
//
//  OrchestraJobManager checks once a minute and starts a normal job when
//  one is due, so results land in the Jobs list like any other job.
//

import Foundation

enum OrchestraJobPlace: String, Codable {
    case hermes
    case mac
}

struct OrchestraRoutine: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var brief: String
    var place: OrchestraJobPlace
    var scheduleText: String
    let createdAt: Date
    var lastRunAt: Date?
    var isPaused: Bool

    /// The next time this routine should run, or nil if the schedule can't be read.
    func nextRunDate(after referenceDate: Date, calendar: Calendar = .current) -> Date? {
        guard let parsedSchedule = OrchestraRoutineSchedule(text: scheduleText) else { return nil }
        return parsedSchedule.nextDate(after: referenceDate, calendar: calendar)
    }

    func isDue(now: Date = Date()) -> Bool {
        guard !isPaused else { return false }
        let referenceDate = lastRunAt ?? createdAt
        guard let nextRunDate = nextRunDate(after: referenceDate) else { return false }
        return nextRunDate <= now
    }
}

/// Parsed form of a routine's schedule text.
enum OrchestraRoutineSchedule {
    case daily(hour: Int, minute: Int)
    case weekdays(hour: Int, minute: Int)
    case weekly(weekday: Int, hour: Int, minute: Int)   // weekday: 1 = Sunday ... 7 = Saturday
    case interval(seconds: TimeInterval)

    private static let weekdayNumberByName: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
        "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7
    ]

    init?(text scheduleText: String) {
        let words = scheduleText.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .map(String.init)
        guard let firstWord = words.first else { return nil }

        if firstWord == "every", words.count >= 3, let amount = Double(words[1]) {
            let unit = words[2]
            var seconds: TimeInterval
            if unit.hasPrefix("min") {
                seconds = amount * 60
            } else if unit.hasPrefix("hour") || unit == "h" {
                seconds = amount * 3600
            } else if unit.hasPrefix("day") {
                seconds = amount * 86400
            } else {
                return nil
            }
            seconds = max(seconds, 15 * 60)
            self = .interval(seconds: seconds)
            return
        }

        guard words.count >= 2, let timeOfDay = Self.parseTimeOfDay(words[1...].joined(separator: " ")) else { return nil }
        if firstWord == "daily" || firstWord == "everyday" {
            self = .daily(hour: timeOfDay.hour, minute: timeOfDay.minute)
        } else if firstWord == "weekdays" {
            self = .weekdays(hour: timeOfDay.hour, minute: timeOfDay.minute)
        } else if let weekdayNumber = Self.weekdayNumberByName[firstWord]
                    ?? (firstWord.hasSuffix("s") ? Self.weekdayNumberByName[String(firstWord.dropLast())] : nil) {
            self = .weekly(weekday: weekdayNumber, hour: timeOfDay.hour, minute: timeOfDay.minute)
        } else {
            return nil
        }
    }

    /// "08:30", "8:30", "8am", "8:30pm", "20:15"
    private static func parseTimeOfDay(_ text: String) -> (hour: Int, minute: Int)? {
        let cleanedText = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "at", with: "")
        let isPM = cleanedText.hasSuffix("pm")
        let isAM = cleanedText.hasSuffix("am")
        let numberPart = cleanedText.replacingOccurrences(of: "pm", with: "").replacingOccurrences(of: "am", with: "")
        let pieces = numberPart.split(separator: ":").map(String.init)
        guard let rawHour = Int(pieces.first ?? "") else { return nil }
        let minute = pieces.count > 1 ? (Int(pieces[1]) ?? 0) : 0
        var hour = rawHour
        if isPM && hour < 12 { hour += 12 }
        if isAM && hour == 12 { hour = 0 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    func nextDate(after referenceDate: Date, calendar: Calendar) -> Date? {
        switch self {
        case .interval(let seconds):
            return referenceDate.addingTimeInterval(seconds)
        case .daily(let hour, let minute):
            return calendar.nextDate(after: referenceDate,
                                     matching: DateComponents(hour: hour, minute: minute),
                                     matchingPolicy: .nextTime)
        case .weekly(let weekday, let hour, let minute):
            return calendar.nextDate(after: referenceDate,
                                     matching: DateComponents(hour: hour, minute: minute, weekday: weekday),
                                     matchingPolicy: .nextTime)
        case .weekdays(let hour, let minute):
            // Earliest upcoming Monday–Friday at that time.
            return (2...6).compactMap { weekdayNumber in
                calendar.nextDate(after: referenceDate,
                                  matching: DateComponents(hour: hour, minute: minute, weekday: weekdayNumber),
                                  matchingPolicy: .nextTime)
            }.min()
        }
    }
}
