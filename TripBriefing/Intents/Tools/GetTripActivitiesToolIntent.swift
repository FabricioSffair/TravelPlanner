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
        "Returns the activities planned in the user's latest trip briefing. Each activity has its date and start time, the time of day, the activity, the place, the area, details and the trip's destination, so it can be added to a calendar, a reminder or a message. Leave both filters empty to get the whole trip."
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
