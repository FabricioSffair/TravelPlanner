//
//  TripActivityIntents.swift
//  TripBriefing
//
//  The latest trip's planned activities as App Intents entities, so Shortcuts can work with the
//  place and date instead of a sentence: Get Trip Activities → Adjust Date → Add New Reminder.
//  Read from the saved trip (`TripNotesArchive`), so no agent runs and the answer is immediate.
//

import AppIntents
import Foundation

// MARK: - Entity

struct TripActivityEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Trip Activity"
    static let defaultQuery = TripActivityQuery()

    /// "2026-11-12|Morning": stable while the same trip is kept, so a shortcut that picked one
    /// still finds it after the app restarts.
    let id: String

    @Property(title: "Date")
    var date: Date

    @Property(title: "Day")
    var dayNumber: Int

    @Property(title: "Time of Day")
    var slot: String

    @Property(title: "Activity")
    var title: String

    @Property(title: "Place")
    var place: String

    @Property(title: "Area")
    var area: String

    @Property(title: "Details")
    var details: String

    @Property(title: "Destination")
    var destination: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(place)",
            subtitle: "Day \(dayNumber) · \(slot) · \(title)"
        )
    }

    init(
        id: String,
        date: Date,
        dayNumber: Int,
        slot: String,
        title: String,
        place: String,
        area: String,
        details: String,
        destination: String
    ) {
        self.id = id
        self.date = date
        self.dayNumber = dayNumber
        self.slot = slot
        self.title = title
        self.place = place
        self.area = area
        self.details = details
        self.destination = destination
    }
}

extension TripActivityEntity {
    /// Every activity of the saved trip, in date and slot order. Empty when no finished briefing
    /// has been saved, or it was saved before the itinerary was kept with the notes.
    static func all() -> [TripActivityEntity] {
        guard let archive = TripNotesArchive.load(), let itinerary = archive.itinerary else { return [] }
        let dayNumbers = dayNumbers(from: archive.tripDays)
        return itinerary.days.enumerated().flatMap { index, day in
            day.activities.compactMap { activity -> TripActivityEntity? in
                guard let date = date(day.date, slot: activity.slot) else { return nil }
                return TripActivityEntity(
                    id: "\(day.date)|\(activity.slot)",
                    date: date,
                    dayNumber: dayNumbers[day.date] ?? index + 1,
                    slot: activity.slot,
                    title: activity.title,
                    place: activity.placeName,
                    area: activity.area,
                    details: activity.details,
                    destination: archive.destination
                )
            }
        }
    }

    /// "Day 1 = 2026-10-14" → ["2026-10-14": 1].
    private static func dayNumbers(from tripDays: [String]) -> [String: Int] {
        var numbers: [String: Int] = [:]
        for line in tripDays {
            let parts = line.components(separatedBy: " = ")
            guard parts.count == 2, let number = Int(parts[0].replacingOccurrences(of: "Day ", with: "")) else { continue }
            numbers[parts[1]] = number
        }
        return numbers
    }

    /// The day in the local time zone, at the slot's usual start (9:00, 13:00 or 18:00), so a
    /// reminder made from it, or from it moved by whole days, lands at a sensible hour.
    private static func date(_ day: String, slot: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let hour = switch slot.lowercased() {
        case "afternoon": 13
        case "evening": 18
        default: 9
        }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))
    }
}

// MARK: - Query

/// Finds activities by ID for Shortcuts and Siri, lists them as suggestions when a parameter asks
/// for one, and matches typed text against the place, the activity and the area.
struct TripActivityQuery: EntityStringQuery {
    func entities(for identifiers: [TripActivityEntity.ID]) async throws -> [TripActivityEntity] {
        let wanted = Set(identifiers)
        return TripActivityEntity.all().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [TripActivityEntity] {
        TripActivityEntity.all().filter { $0.matches(string) }
    }

    func suggestedEntities() async throws -> [TripActivityEntity] {
        TripActivityEntity.all()
    }
}

extension TripActivityEntity {
    func matches(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return [place, title, area].contains { $0.localizedCaseInsensitiveContains(text) }
    }
}

// MARK: - Get Trip Activities

struct GetTripActivitiesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Trip Activities"
    static let description = IntentDescription(
        "Lists the activities planned in your latest trip briefing, with each one's place, date and time of day. Leave the filters empty to get the whole trip."
    )

    @Parameter(title: "Day", description: "The day of the trip, starting at 1.", inclusiveRange: (1, 60))
    var day: Int?

    @Parameter(title: "Place", description: "Part of the place, activity or area name, e.g. \"museum\".")
    var place: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Get trip activities") {
            \.$day
            \.$place
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[TripActivityEntity]> & ProvidesDialog {
        let all = TripActivityEntity.all()
        guard !all.isEmpty else {
            return .result(
                value: [],
                dialog: "There is no planned trip yet. Plan a briefing in Travel Assistant first."
            )
        }
        let found = all.filter { activity in
            (day == nil || activity.dayNumber == day) && activity.matches(place ?? "")
        }
        return .result(value: found, dialog: IntentDialog(stringLiteral: Self.summary(found)))
    }

    /// "Day 2, Morning: Lisbon Tile Museum. Day 2, Afternoon: …"
    private static func summary(_ activities: [TripActivityEntity]) -> String {
        guard !activities.isEmpty else { return "No planned activity matches." }
        return activities
            .map { "Day \($0.dayNumber), \($0.slot): \($0.place)." }
            .joined(separator: " ")
    }
}
