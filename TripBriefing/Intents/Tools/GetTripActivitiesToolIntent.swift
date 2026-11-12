//
//  GetTripActivitiesToolIntent.swift
//  TripBriefing
//
//  Get Trip Activities as a tool Siri's model can call (27.3). It returns entities, not a
//  sentence, so Siri can pass an activity's date, place and details to another app, for example
//  "add Day 2's morning to my calendar". Shares `GetTripActivitiesIntent.result`; in its own file
//  so it can be dropped without touching the other intents.
//

import AppIntents

@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct GetTripActivitiesToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Planned Trip Activities"
    static let description = IntentDescription(
        "Returns the activities planned in the user's latest trip briefing. Use it only to add activities to a calendar, a reminder or a message. To answer a question about the trip, including the schedule, use Answer a Trip Question instead. Each activity has its date and start time, the time of day, the activity, the place, the area, details and the trip's destination, so it can be added to a calendar, a reminder or a message. Leave both filters empty to get the whole trip. When you show the result, write each day on its own line with no bullet, list that day's activities under it with a bullet character (•) instead of a dash, and leave an empty line between days."
    )

    @Parameter(
        title: "Day",
        description: "The day of the trip, starting at 1. Empty for every day.",
        inclusiveRange: (1, 60)
    )
    var day: Int?

    @Parameter(
        title: "Place",
        description: "Part of the place, activity or area name, for example \"museum\". Empty for every activity."
    )
    var place: String?

    func perform() async throws -> some IntentResult & ReturnsValue<[TripActivityEntity]> & ProvidesDialog {
        GetTripActivitiesIntent.result(day: day, place: place)
    }
}
