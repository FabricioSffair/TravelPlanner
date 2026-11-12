//
//  AskTravelAssistantToolIntent.swift
//  TripBriefing
//
//  Ask Travel Assistant as a tool Siri's model can call (27.3). Shares `AskTravelAssistantIntent.answer`;
//  in its own file so it can be dropped without touching the other intents.
//

import AppIntents

@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct AskTripToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Answer a Trip Question"
    static let description = IntentDescription(
        "Answers a question about the user's planned trip from the trip plan. Returns the answer as plain text that gives each trip day with its full date, for example \"Thursday, November 12, 2026\", and the town or city for that day."
    )

    @Parameter(title: "Question", description: "The question about the user's planned trip.")
    var question: String

    @Dependency private var planner: TripPlannerViewModel
    @Dependency private var settings: ProviderSettings

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        IntentAnswer.reply(await AskTravelAssistantIntent.answer(question, planner: planner, settings: settings))
    }
}
