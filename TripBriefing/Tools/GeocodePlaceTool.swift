//
//  GeocodePlaceTool.swift
//  TripBriefing
//
//  Tool: place name → coordinates. The weather agent calls this first, then
//  feeds the coordinates to DailyForecastTool.
//

import Foundation
import RailtracksSwift

struct GeocodePlaceTool: RTSToolNode {
    let id = UUID()
    let toolName = "GeocodePlace"
    var inputs: RTSInput = [:]

    let callableRoutine = RTSClosure { inputs in
        guard case let .string(place)? = inputs["place"], !place.isEmpty else {
            throw RTSError.missingInput("place")
        }
        let geo = try await OpenMeteoClient.geocode(place)
        return [
            "name": .string(geo.name),
            "country": .string(geo.country ?? ""),
            "latitude": .number(geo.latitude),
            "longitude": .number(geo.longitude),
            "timezone": .string(geo.timezone ?? ""),
        ]
    }

    var toolDescription = "Resolves a city or place name to latitude, longitude, country and timezone. Call this before asking for a forecast."

    var parameterSchema: RTSToolSchema {
        RTSToolSchema(parameters: [
            .init(name: "place", description: "City or place name, e.g. \"Lisbon, Portugal\"", type: .string),
        ])
    }
}
