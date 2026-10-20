//
//  TripBriefingWorkflow.swift
//  TripBriefing
//
//  The orchestrator node. Your code decides the control flow: three agents
//  run in parallel with `async let`, then the concierge runs on their results.
//  Every `context.call` is traced as a child of this node.
//

import Foundation
import RailtracksSwift

struct TripBriefingWorkflow: RTSOrchestratorNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let nodeName = TripAgents.Name.workflow

    let agents: TripAgents.Set
    /// The same agents on the cloud provider. When an on-device agent's prompt outgrows the
    /// context window, that agent alone runs again from here. `nil` means no fallback.
    var fallbackAgents: TripAgents.Set?
    /// Receives an agent's name when it falls back.
    var onFallback: @Sendable (String) -> Void = { _ in }
    /// Receives each agent's name and answer as soon as that agent finishes, so its section can
    /// show while the rest of the run continues. Itinerary repair calls report too.
    var onAgentResult: @Sendable (String, String) -> Void = { _, _ in }

    /// Resolves to the search tool over the destination's indexed Wikivoyage guide, or `nil`
    /// when grounding is off or indexing failed. Indexing starts before this node runs, so it
    /// overlaps the first phase.
    var guideTool: (@Sendable () async -> RTSKnowledgeSearchTool?)?

    enum OutputKey {
        static let briefing = "briefing"
        static let weather = "weather"
        static let itinerary = "itinerary"
        static let phrasebook = "phrasebook"
    }

    func run(_ input: RTSInput, context: RTSRunContext) async throws -> RTSOutput {
        guard case let .string(destination)? = input["destination"], !destination.isEmpty else {
            throw RTSError.missingInput("destination")
        }
        guard case let .string(start)? = input["startDate"] else { throw RTSError.missingInput("startDate") }
        guard case let .string(end)? = input["endDate"] else { throw RTSError.missingInput("endDate") }
        let dayCount: Int = {
            if case let .number(n)? = input["dayCount"] { return Int(n) }
            return 1
        }()
        let notes: String = {
            if case let .string(s)? = input["notes"] { return s }
            return ""
        }()
        let homeLanguage: String = {
            if case let .string(s)? = input["homeLanguage"] { return s }
            return "English"
        }()

        // Three independent tracks. They start together; the trace shows three
        // overlapping Agent Runs bars under this node.
        async let weather = reporting(TripAgents.Name.weather) { try await context.call(
            agents.weather,
            fallback: fallbackAgents?.weather,
            prompt: "Destination: \(destination). Dates: \(start) to \(end). Report the daily weather.",
            onFallback: onFallback
        ) }
        // Every date spelled out: given only a range, the on-device model returned one day of four.
        let dates = Self.dates(from: start, count: dayCount)
        async let itinerary = reporting(TripAgents.Name.itinerary) { try await context.call(
            agents.itinerary,
            fallback: fallbackAgents?.itinerary,
            prompt: """
            Plan \(dayCount) day(s) in \(destination) from \(start) to \(end).
            Return exactly one entry in `days` for each of these dates: \(dates.joined(separator: ", ")).
            Traveler notes: \(notes.isEmpty ? "none" : notes)
            """,
            onFallback: onFallback
        ) }
        async let phrasebook = reporting(TripAgents.Name.phrasebook) { try await context.call(
            agents.phrasebook,
            fallback: fallbackAgents?.phrasebook,
            prompt: "Destination: \(destination). The traveler speaks \(homeLanguage).",
            onFallback: onFallback
        ) }

        let (weatherReport, firstItinerary, phrases) = try await (weather, itinerary, phrasebook)
        let itineraryPlan = try await completeItinerary(
            firstItinerary, dates: dates, destination: destination, notes: notes, context: context
        )
        // Both answers are JSON now. The Concierge and its Packing List read one line per day
        // instead: shorter than the JSON and than the old Markdown, which keeps the on-device
        // prompt inside its context window. If either fails to decode, its raw text goes through.
        let weatherText = (try? WeatherReport.decode(from: weatherReport))?.compactText ?? weatherReport
        let itineraryText = (try? Itinerary.decode(from: itineraryPlan))?.compactText ?? itineraryPlan

        // The travel guide was indexing alongside the three tracks; usually it is ready by now.
        // Without it the concierge runs exactly as before.
        let travelGuideTool = await guideTool?()

        // Sequential tail: the concierge needs both texts, and calls the
        // Packing List agent through its tool (and searches the guide when it has one).
        // The fallback Concierge carries the cloud Packing List too: an overflow inside the
        // nested on-device agent surfaces here, and retrying it on-device would overflow again.
        let briefing = try await reporting(TripAgents.Name.concierge) { try await context.call(
            agents.concierge(guideTool: travelGuideTool),
            fallback: fallbackAgents?.concierge(guideTool: travelGuideTool),
            prompt: """
            Dates: \(start) to \(end) (\(dayCount) day(s)) in \(destination).

            WEATHER REPORT:
            \(weatherText)

            ITINERARY:
            \(itineraryText)
            """,
            onFallback: onFallback
        ) }

        return [
            OutputKey.briefing: .string(briefing),
            OutputKey.weather: .string(weatherReport),
            OutputKey.itinerary: .string(itineraryPlan),
            OutputKey.phrasebook: .string(phrases),
        ]
    }

    /// Asks the Local Guide again for any date its answer left out, one date per call, naming the
    /// places already planned so it picks others. Measured on-device: one run in three returned a
    /// single day of four. Costs nothing when the first answer is complete; text that does not
    /// decode passes through unchanged.
    func completeItinerary(
        _ json: String,
        dates: [String],
        destination: String,
        notes: String,
        context: RTSRunContext
    ) async throws -> String {
        guard var plan = try? Itinerary.decode(from: json) else { return json }
        let missing = dates.filter { date in !plan.days.contains { $0.date == date } }
        guard !missing.isEmpty else { return json }
        AppLog.warning("Itinerary incomplete, asking again for missing days", properties: [
            "Returned": "\(plan.days.count)", "Missing": "\(missing.count)",
        ])

        for date in missing {
            let used = Set(plan.days.flatMap { $0.activities.map(\.placeName) })
            let answer = try await context.call(
                agents.itinerary,
                fallback: fallbackAgents?.itinerary,
                prompt: """
                Plan one day in \(destination): \(date). Return exactly one entry in `days`, for \(date).
                Places already planned on other days, so pick different ones: \(used.sorted().joined(separator: ", ")).
                Traveler notes: \(notes.isEmpty ? "none" : notes)
                """,
                onFallback: onFallback
            )
            onAgentResult(TripAgents.Name.itinerary, answer)
            // Keyed to the date asked for, whatever date the model wrote.
            if let day = (try? Itinerary.decode(from: answer))?.days.first {
                plan = Itinerary(days: plan.days + [ItineraryDay(date: date, activities: day.activities)])
            }
        }
        let ordered = Itinerary(days: plan.days
            .filter { dates.contains($0.date) }
            .sorted { (dates.firstIndex(of: $0.date) ?? 0) < (dates.firstIndex(of: $1.date) ?? 0) })
        guard let data = try? JSONEncoder().encode(ordered), let merged = String(data: data, encoding: .utf8) else {
            return json
        }
        return merged
    }

    /// Runs one agent call and reports its answer through `onAgentResult`.
    private func reporting(_ agentName: String, _ call: () async throws -> String) async throws -> String {
        let answer = try await call()
        onAgentResult(agentName, answer)
        return answer
    }

    /// `count` consecutive yyyy-MM-dd dates from `start`; just `start` if it does not parse.
    static func dates(from start: String, count: Int) -> [String] {
        let formatter = TripRequest.dateFormatter
        guard let first = formatter.date(from: start) else { return [start] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        return (0..<max(count, 1)).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: first).map(formatter.string(from:))
        }
    }
}
