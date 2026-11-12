//
//  TripAgents.swift
//  TripBriefing
//
//  The five agents and how they are wired. Names are what shows up in the
//  call tree, the JSON trace and the Instruments Agent Runs lane.
//

import Foundation
import RailtracksSwift

enum TripAgents {

    enum Name {
        static let weather = "Weather Scout"
        static let itinerary = "Local Guide"
        static let phrasebook = "Phrasebook"
        static let packing = "Packing List"
        static let concierge = "Concierge"
        static let translator = "Sign Translator"
        static let assistant = "Trip Assistant"
        static let workflow = "Trip Briefing"
    }

    struct Set: Sendable {
        let weather: RTSAgent
        let itinerary: RTSAgent
        /// The Local Guide without tools, for when PlacesSearch's calls are spent: it plans from
        /// the places listed in its prompt.
        let itineraryFromPlaces: RTSAgent
        /// The PlacesSearch memory `itinerary` uses, shared with the fallback set.
        let places: PlacesSearchSession
        let phrasebook: RTSAgent
        let concierge: RTSAgent
        let cloud: RTSLLMProvider
        let packingTool: RTSAgentTool

        /// The Concierge with the travel-guide search alongside the Packing List tool.
        /// Without a guide tool this is the plain `concierge`.
        func concierge(guideTool: RTSKnowledgeSearchTool?) -> RTSAgent {
            guard let guideTool else { return concierge }
            return TripAgents.groundedConcierge(cloud: cloud, packingTool: packingTool, guideTool: guideTool)
        }
    }

    /// - Parameters:
    ///   - cloud: provider for the agents that need tools and long context.
    ///   - phrasebook: provider for the phrasebook agent; on-device when available.
    ///   - places: one briefing's PlacesSearch memory. Pass the same one to the fallback set, so a
    ///     day that falls back to the cloud still skips the places already suggested.
    static func make(
        cloud: RTSLLMProvider,
        phrasebook phrasebookProvider: RTSLLMProvider,
        places: PlacesSearchSession
    ) throws -> Set {

        // Track 1: two chained tools; the model decides the order.
        let weather = RTSAgent(
            llmProvider: cloud,
            name: Name.weather,
            tools: [GeocodePlaceTool(), DailyForecastTool()],
            systemMessage: """
            You are a travel weather analyst. Always call GeocodePlace first, then DailyForecast \
            passing its `latitude` and `longitude` and the exact dates you were given as `start` and \
            `end`. \
            Return one entry in `days` per date from the tool: `date` as yyyy-MM-dd, `condition` in \
            a few words, `maxC` and `minC` in °C, and `rainChancePercent` only when the tool gives \
            one. Write a two-sentence `outlook` for the whole period. Set `isHistorical` to true \
            when the tool's source says historical (last year's readings, not a forecast). \
            Reply with only the structured object: no introduction, no closing sentence, no code \
            fences.
            """,
            outputSchema: WeatherReport.rtsSchema
        )

        // Track 2: MapKit-backed tool, with guardrails on the traveler's notes.
        let itinerary = RTSAgent(
            llmProvider: cloud,
            name: Name.itinerary,
            tools: [PlacesSearchTool(session: places)],
            systemMessage: """
            You are a local guide. Use PlacesSearch to find real places for each kind of activity you \
            recommend (at most four searches). PlacesSearch never returns a place twice, so use each \
            place once. Return one entry in `days` for every date in the range, \
            with `date` as yyyy-MM-dd and exactly three `activities` in order, with `slot` "Morning", \
            "Afternoon" and "Evening". For each activity, `title` is a few words, `place` is the place's \
            name exactly as PlacesSearch gives it, without the address, and `details` is one sentence. \
            `area` is the town or city the traveler is in during the activity, not where the operator is \
            based: PlacesSearch gives each place's `locality`, so use it when the activity happens at that \
            place, and for a day trip to another town use that town. \
            Prefer different places on different days. Respect the traveler's notes.
            """,
            outputSchema: Itinerary.rtsSchema,
            inputGuardrails: [
                try RTSPIIRedactInputGuardrail(),
                RTSLengthInputGuardrail(maxCharacters: 2000),
            ]
        )

        // Track 2 once PlacesSearch is spent: the same plan, from the places already found.
        let itineraryFromPlaces = RTSAgent(
            llmProvider: cloud,
            name: Name.itinerary,
            systemMessage: """
            You are a local guide. Plan with the places listed under "Places found", using each place \
            once where you can. Return one entry in `days` for every date you are asked for, with `date` \
            as yyyy-MM-dd and exactly three `activities` in order, with `slot` "Morning", "Afternoon" and \
            "Evening". For each activity, `title` is a few words, `place` is the place's name exactly as \
            listed, and `details` is one sentence. `area` is the place's locality, or for a day trip the \
            town the traveler visits. When the list has too few places, use well-known places you are \
            sure exist. Respect the traveler's notes.
            """,
            outputSchema: Itinerary.rtsSchema,
            // The place list makes the prompt longer than the searching Local Guide's.
            inputGuardrails: [
                try RTSPIIRedactInputGuardrail(),
                RTSLengthInputGuardrail(maxCharacters: 6000),
            ]
        )

        // Track 3: no tools, structured output, on-device when possible.
        let phrasebook = RTSAgent(
            llmProvider: phrasebookProvider,
            name: Name.phrasebook,
            systemMessage: """
            You prepare a pocket phrasebook for a traveler. Identify the main local language of the \
            destination and give eight must-know phrases with a simple pronunciation guide, the meaning, \
            and when to use each. Include one polite greeting as `greeting`.
            """,
            outputSchema: PhraseBook.rtsSchema
        )

        // Nested agent, exposed to the concierge as one tool.
        let packing = RTSAgent(
            llmProvider: cloud,
            name: Name.packing,
            systemMessage: """
            Given a weather report and an itinerary, write a concise packing list of 8 to 14 items, \
            one per line, no explanations. Tailor it to the temperatures, rain chance and activities.
            """
        )
        let packingTool = RTSAgentTool(
            agent: packing,
            description: "Builds a packing list from a weather report and an itinerary. Pass both texts in `prompt`.",
            parameters: RTSToolSchema(parameters: [
                .init(name: "prompt", description: "The weather report followed by the itinerary", type: .string),
            ])
        )

        // Sequential tail: composes everything, calls the packing tool, returns JSON.
        let concierge = RTSAgent(
            llmProvider: cloud,
            name: Name.concierge,
            tools: [packingTool],
            systemMessage: """
            You are the trip concierge. You receive a weather report and an itinerary. First call the \
            Packing List tool exactly once with both texts. Then produce the final briefing: a short \
            headline, a two-sentence weatherSummary, one entry in days per date with morning, afternoon \
            and evening, the packingList from the tool as separate strings, and four short practical tips.
            """,
            outputSchema: TripBriefingReport.rtsSchema
        )

        return Set(
            weather: weather,
            itinerary: itinerary,
            itineraryFromPlaces: itineraryFromPlaces,
            places: places,
            phrasebook: phrasebook,
            concierge: concierge,
            cloud: cloud,
            packingTool: packingTool
        )
    }

    /// Same job and output schema as the plain Concierge, but the four practical tips come from
    /// the destination's Wikivoyage guide, searched through a RAG-backed knowledge tool.
    static func groundedConcierge(cloud: RTSLLMProvider, packingTool: RTSAgentTool, guideTool: RTSKnowledgeSearchTool) -> RTSAgent {
        RTSAgent(
            llmProvider: cloud,
            name: Name.concierge,
            tools: [packingTool, guideTool],
            systemMessage: """
            You are the trip concierge. You receive a weather report and an itinerary. First call the \
            Packing List tool exactly once with both texts. Then call \(guideTool.toolName) to search the \
            destination's travel guide, once for each of: getting around (including from the airport), \
            safety, local etiquette, and staying connected. Then produce the final briefing: a short \
            headline, a two-sentence weatherSummary, one entry in days per date with morning, afternoon \
            and evening, the packingList from the tool as separate strings, and four short practical tips, \
            one each on getting around, safety, etiquette and connectivity. Base every tip on what the \
            guide search returned, with concrete details from it; if a search found nothing useful for \
            a topic, give a brief general tip for it instead.
            """,
            outputSchema: TripBriefingReport.rtsSchema
        )
    }

    /// Answers a traveler's questions from what the searches return: the briefing's own notes,
    /// the destination's Wikivoyage guide, or both. At least one tool must be given.
    /// - Parameter tripDays: "Day 1 = 2026-10-14", one per day. Stated in the instructions because
    ///   the on-device model miscounts days from a start date.
    static func tripAssistant(
        provider: RTSLLMProvider,
        notesTool: RTSKnowledgeSearchTool?,
        guideTool: RTSKnowledgeSearchTool?,
        tripDays: [String] = []
    ) -> RTSAgent {
        var steps: [String] = []
        if let notesTool {
            steps.append(
                "For anything about this trip (dates, daily weather, the day-by-day plan, packing, "
                    + "tips, phrases), call \(notesTool.toolName) to search the traveler's briefing."
            )
        }
        if let guideTool {
            steps.append(
                "For practical questions about the destination itself (getting there and around, "
                    + "safety, customs, tipping, SIM cards), call \(guideTool.toolName) to search its "
                    + "Wikivoyage travel guide."
            )
        }
        let days = tripDays.isEmpty ? "" : " The trip's days: \(tripDays.joined(separator: ", "))."
        return RTSAgent(
            llmProvider: provider,
            name: Name.assistant,
            tools: [notesTool, guideTool].compactMap { $0 },
            systemMessage: """
            You answer a traveler's questions about their trip. \(steps.joined(separator: " "))\(days) \
            The prompt may start with the recent conversation; use it only to understand follow-up \
            questions such as "and in the evening?". Search again for every new question, even one \
            asked before, and never repeat an earlier answer from the conversation. Answer in two to \
            four plain sentences, only from the search results, and name the day, part of the briefing or guide section you used. \
            If the answer covers more than one day, write one block per day instead: the day and its \
            full date on one line, each activity on its own line under it starting with "- ", and an \
            empty line between days. \
            Keep numbers and place names exactly as the results give them. Write each date in full, \
            as in "November 12, 2026". When asked when or where, give the date and the town or city. \
            If the results do not answer the question, say so. Do not guess.
            """
        )
    }

    /// Vision agent for the Translate tab. Cloud only: Apple Intelligence ignores images.
    static func translator(cloud: RTSLLMProvider) -> RTSAgent {
        RTSAgent(
            llmProvider: cloud,
            name: Name.translator,
            systemMessage: """
            The user shows you a photo taken while traveling: a menu, a sign, a ticket or a label. \
            Transcribe the text, translate it into the language the user asks for, and finish with one \
            sentence saying what the thing is and anything a traveler should know about it.
            """
        )
    }
}
