//
//  PlacesSearchTool.swift
//  TripBriefing
//
//  Tool backed by MapKit local search. This is the iOS-specific tool: it calls
//  an Apple framework from inside the tool closure, which is where framework
//  types meet the SDK's Sendable closure contract.
//

import Foundation
import MapKit
import RailtracksSwift

struct PlacesSearchTool: RTSToolNode {
    let id = UUID()
    let toolName = "PlacesSearch"
    var inputs: RTSInput = [:]

    let callableRoutine = RTSClosure { inputs in
        guard case let .string(query)? = inputs["query"], !query.isEmpty else {
            throw RTSError.missingInput("query")
        }
        guard case let .string(place)? = inputs["place"], !place.isEmpty else {
            throw RTSError.missingInput("place")
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "\(query) in \(place)"
        request.resultTypes = [.pointOfInterest]
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch {
            AppLog.warning("Apple Maps search failed, Local Guide continues without results", properties: ["Error": "\(error)"])
            // Apple Maps throttles bursts of searches (MKError 4). A thrown error would end the
            // Local Guide and the whole briefing, so the model gets an empty result it can work
            // around instead.
            return [
                "results": .array([]),
                "count": .number(0),
                "note": .string("Apple Maps search is unavailable right now. Use well-known places in \(place) that you are sure exist."),
            ]
        }

        let results: [RTSValue] = response.mapItems.prefix(6).map { item in
            .object([
                "name": .string(item.name ?? "Unknown"),
                "category": .string(item.pointOfInterestCategory?.rawValue
                    .replacingOccurrences(of: "MKPOICategory", with: "") ?? ""),
                "address": .string(item.placemark.title ?? ""),
            ])
        }
        return ["results": .array(results), "count": .number(Double(results.count))]
    }

    var toolDescription = "Finds real points of interest (museums, restaurants, parks, viewpoints, neighborhoods) in a place using Apple Maps. Returns up to 6 results with name, category and address."

    var parameterSchema: RTSToolSchema {
        RTSToolSchema(parameters: [
            .init(name: "query", description: "What to look for, e.g. \"art museums\" or \"seafood restaurants\"", type: .string),
            .init(name: "place", description: "City or area to search in", type: .string),
        ])
    }
}
