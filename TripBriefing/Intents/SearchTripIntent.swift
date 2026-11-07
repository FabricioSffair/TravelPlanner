//
//  SearchTripIntent.swift
//  TripBriefing
//
//  Test of the in-app search schema: a second way for Siri to reach the app, without an App
//  Shortcut phrase. Siri passes the search term, the app opens on Chat, and the Trip Assistant
//  answers there. The intent also returns the answer, to test whether Siri shows or speaks it.
//

import AppIntents

@available(iOS 27, macOS 27, visionOS 27, *)
@AppIntent(schema: .system.searchInApp)
struct SearchTripIntent: ShowInAppSearchResultsIntent {
    /// Shortcuts lists actions by title, and the schema does not provide one.
    static let title: LocalizedStringResource = "Search My Trip"
    static let searchScopes: [StringSearchScope] = [.general]

    var criteria: StringSearchCriteria

    @Dependency private var planner: TripPlannerViewModel
    @Dependency private var settings: ProviderSettings

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        AppLog.info("Siri in-app search received")
        planner.chatRequested = true
        return IntentAnswer.reply(await AskTravelAssistantIntent.answer(criteria.term, planner: planner, settings: settings))
    }
}

