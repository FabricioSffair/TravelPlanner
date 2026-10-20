//
//  TripRequest.swift
//  TripBriefing
//

import Foundation
import RailtracksSwift

struct TripRequest: Sendable {
    var destination: String
    var startDate: Date
    var endDate: Date
    var notes: String
    var homeLanguage: String

    static let dateFormatter = OpenMeteoClient.dateFormatter

    var startString: String { Self.dateFormatter.string(from: startDate) }
    var endString: String { Self.dateFormatter.string(from: endDate) }

    var dayCount: Int {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        return max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
    }

    /// The orchestrator's input dictionary. Keys are read back in
    /// `TripBriefingWorkflow.run`.
    var asInput: RTSInput {
        [
            "destination": .string(destination),
            "startDate": .string(startString),
            "endDate": .string(endString),
            "dayCount": .number(Double(dayCount)),
            "notes": .string(notes),
            "homeLanguage": .string(homeLanguage),
        ]
    }

    static var sample: TripRequest {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(byAdding: .day, value: 5, to: Date())!
        let end = calendar.date(byAdding: .day, value: 8, to: Date())!
        return TripRequest(
            destination: "Lisbon, Portugal",
            startDate: start,
            endDate: end,
            notes: "We love seafood and walking. One museum day is enough.",
            homeLanguage: "English"
        )
    }
}
