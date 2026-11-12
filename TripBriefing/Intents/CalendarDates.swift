//
//  CalendarDates.swift
//  TripBriefing
//
//  Writes the dates in a Siri answer one way, in full, so that Siri can read the date when the
//  user asks it to add the day to the calendar. The model's wording varies ("November 12th",
//  "2026-11-12"), and an answer such as "Day 3 is a day trip" has no date at all, so this runs on
//  the finished text and does not depend on the model.
//

import Foundation

enum CalendarDates {
    private static let months = [
        "January", "February", "March", "April", "May", "June", "July",
        "August", "September", "October", "November", "December",
    ]

    /// `text` with each date as "Thursday, November 12, 2026". A date with no year takes it from
    /// the trip. When the answer has no date but names a day, the first "Day 3" gets its date.
    /// - Parameter tripDays: "Day 1 = 2026-10-14", one per day.
    static func normalized(_ text: String, tripDays: [String]) -> String {
        let days = parse(tripDays)
        var result = text.replacing(#/\b\d{4}-\d{2}-\d{2}\b/#) { match in
            date(iso: String(match.output)).map(fullText) ?? String(match.output)
        }
        var found = false
        let named = #/(?:(?:Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day,?\s+)?(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s+(\d{4})\b)?/#
        result = result.replacing(named) { match in
            let original = String(match.output.0)
            guard let monthNumber = months.firstIndex(where: { $0.hasPrefix(match.output.1.prefix(3)) }).map({ $0 + 1 }),
                  let day = Int(match.output.2)
            else { return original }
            let date: Date?
            if let year = match.output.3.flatMap({ Int($0) }) {
                date = Self.date(year: year, month: monthNumber, day: day)
            } else {
                date = days.values.first { sameDay($0, month: monthNumber, day: day) }
            }
            guard let date else { return original }
            found = true
            return fullText(date)
        }
        guard !found else { return result }
        guard let match = result.firstMatch(of: #/\bDay (\d+)\b/#),
              let number = Int(match.output.1),
              let date = days[number]
        else { return result }
        return result.replacingCharacters(in: match.range, with: "Day \(number) (\(fullText(date)))")
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func parse(_ tripDays: [String]) -> [Int: Date] {
        var days: [Int: Date] = [:]
        for line in tripDays {
            guard let match = line.firstMatch(of: #/Day (\d+) = (\d{4}-\d{2}-\d{2})/#),
                  let number = Int(match.output.1),
                  let date = date(iso: String(match.output.2))
            else { continue }
            days[number] = date
        }
        return days
    }

    private static func date(iso: String) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        return parts.count == 3 ? date(year: parts[0], month: parts[1], day: parts[2]) : nil
    }

    private static func date(year: Int, month: Int, day: Int) -> Date? {
        let components = DateComponents(calendar: calendar, year: year, month: month, day: day)
        return components.isValidDate ? components.date : nil
    }

    private static func sameDay(_ date: Date, month: Int, day: Int) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return parts.month == month && parts.day == day
    }

    private static func fullText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: date)
    }
}
