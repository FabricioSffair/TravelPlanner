//
//  DailyForecastTool.swift
//  TripBriefing
//
//  Tool: coordinates and a date range → one summary per day. Four scalar
//  parameters: the SDK's main branch has no object type for tool parameters.
//

import Foundation
import RailtracksSwift

struct DailyForecastTool: RTSToolNode {
    let id = UUID()
    let toolName = "DailyForecast"
    var inputs: RTSInput = [:]

    let callableRoutine = RTSClosure { inputs in
        guard case let .number(latitude)? = inputs["latitude"] else { throw RTSError.missingInput("latitude") }
        guard case let .number(longitude)? = inputs["longitude"] else { throw RTSError.missingInput("longitude") }
        guard case let .string(start)? = inputs["start"] else { throw RTSError.missingInput("start") }
        guard case let .string(end)? = inputs["end"] else { throw RTSError.missingInput("end") }

        let result = try await OpenMeteoClient.dailyForecast(
            latitude: latitude, longitude: longitude, start: start, end: end
        )
        let days: [RTSValue] = result.days.map { day in
            var fields: [String: RTSValue] = [
                "date": .string(day.date),
                "maxC": .number(day.maxC),
                "minC": .number(day.minC),
                "condition": .string(day.condition),
            ]
            if let chance = day.precipitationChance {
                fields["precipitationChancePercent"] = .number(Double(chance))
            }
            return .object(fields)
        }
        return [
            "source": .string(result.source),
            "days": .array(days),
        ]
    }

    var toolDescription = "Daily weather (max/min °C, condition, rain chance) for a location over an inclusive date range. Returns a `source` field: `forecast`, or `historical (same dates last year)` when the dates are more than 16 days out."

    var parameterSchema: RTSToolSchema {
        RTSToolSchema(parameters: [
            .init(name: "latitude", description: "Latitude in degrees, from GeocodePlace", type: .number),
            .init(name: "longitude", description: "Longitude in degrees, from GeocodePlace", type: .number),
            .init(name: "start", description: "First day of the trip, yyyy-MM-dd", type: .string),
            .init(name: "end", description: "Last day of the trip, yyyy-MM-dd", type: .string),
        ])
    }
}
