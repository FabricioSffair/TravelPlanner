//
//  TripActivityTransfer.swift
//  TripBriefing
//
//  How a trip activity moves to another app, when Siri passes one along or a shortcut shares
//  it: as a calendar event first, for Calendar, and as a sentence second, for Mail, Messages and
//  Notes. Export only. The receiving app picks the first representation it can read.
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension TripActivityEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .calendarEvent) { activity in
            Data(activity.calendarEvent().utf8)
        }
        ProxyRepresentation(exporting: \.summary)
    }
}

extension TripActivityEntity {
    /// "Thursday, November 12, 2026, morning: Tile workshop at Lisbon Tile Museum, Xabregas,
    /// Lisbon. Book the 10:00 session." The date is written in full so a reader, or a model,
    /// never has to work it out from a day number.
    var summary: String {
        let day = date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        var location = [place, area, destination].filter { !$0.isEmpty }.joined(separator: ", ")
        location = location.isEmpty ? "" : " at \(location)"
        let details = details.isEmpty ? "" : " \(details)"
        return "\(day), \(slot.lowercased()): \(title)\(location).\(details)"
    }

    /// How long the event lasts, by time of day: until noon, until 17:00, or three hours.
    private var durationHours: Int {
        switch slot.lowercased() {
        case "morning": 3
        case "afternoon": 4
        default: 3
        }
    }

    /// One VEVENT in an iCalendar file (RFC 5545). The times are floating (no time zone), as the
    /// activity's `date` is a local hour on the trip day. Lines are not folded at 75 octets:
    /// Calendar reads longer lines.
    func calendarEvent(stampedAt now: Date = .now) -> String {
        let end = Calendar.current.date(byAdding: .hour, value: durationHours, to: date) ?? date
        let location = [place, area, destination].filter { !$0.isEmpty }.joined(separator: ", ")
        let lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Railtown//Travel Assistant//EN",
            "BEGIN:VEVENT",
            "UID:\(id.replacingOccurrences(of: "|", with: "-"))@travel-assistant",
            "DTSTAMP:\(Self.utcFormatter.string(from: now))",
            "DTSTART:\(Self.localFormatter.string(from: date))",
            "DTEND:\(Self.localFormatter.string(from: end))",
            "SUMMARY:\(Self.escaped(title))",
            "LOCATION:\(Self.escaped(location))",
            "DESCRIPTION:\(Self.escaped(details))",
            "END:VEVENT",
            "END:VCALENDAR",
        ]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// iCalendar TEXT escaping: backslash, semicolon, comma and line breaks.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// "20261112T090000", in the device's time zone, like `date`.
    private static let localFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter
    }()

    /// "20261111T213000Z".
    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}
