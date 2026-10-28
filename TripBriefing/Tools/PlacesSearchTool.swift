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
import Synchronization

/// What PlacesSearch remembers during one briefing, shared by the Local Guide's first call and
/// its repair calls.
///
/// Without it, every "museums" search returned the same six Apple Maps results, so the same
/// place came back day after day, and the small on-device model repeated identical searches
/// until Apple Maps refused the burst (MKError 4) and its context window filled.
final class PlacesSearchSession: Sendable {
    struct Place: Sendable {
        let name: String
        let category: String
        /// The town or city the place is in.
        let locality: String
        let address: String
    }

    /// Apple Maps searches one briefing may make. A repeated query is answered from the cache
    /// and does not count.
    static let maxSearches = 12
    /// Results handed out per call. Apple Maps returns more; the rest come out on later calls.
    static let resultsPerCall = 6

    private struct State {
        var cache: [String: [Place]] = [:]
        var shown: Set<String> = []
        var searches = 0
    }
    private let state = Mutex(State())

    enum Lookup {
        case cached([Place])
        case search
        case limitReached
    }

    func lookup(_ key: String) -> Lookup {
        state.withLock { state in
            if let places = state.cache[key] { return .cached(places) }
            guard state.searches < Self.maxSearches else { return .limitReached }
            state.searches += 1
            return .search
        }
    }

    func store(_ places: [Place], for key: String) {
        state.withLock { $0.cache[key] = places }
    }

    /// Up to `resultsPerCall` of `places` not handed out before, now marked as handed out.
    func takeUnseen(from places: [Place]) -> [Place] {
        state.withLock { state in
            let unseen = places.filter { !state.shown.contains($0.name.lowercased()) }
            let taken = Array(unseen.prefix(Self.resultsPerCall))
            state.shown.formUnion(taken.map { $0.name.lowercased() })
            return taken
        }
    }
}

struct PlacesSearchTool: RTSToolNode {
    let id = UUID()
    let toolName = "PlacesSearch"
    var inputs: RTSInput = [:]
    let callableRoutine: RTSClosure

    init(session: PlacesSearchSession) {
        callableRoutine = RTSClosure { inputs in
            guard case let .string(query)? = inputs["query"], !query.isEmpty else {
                throw RTSError.missingInput("query")
            }
            guard case let .string(place)? = inputs["place"], !place.isEmpty else {
                throw RTSError.missingInput("place")
            }

            let key = "\(query) in \(place)".lowercased().trimmingCharacters(in: .whitespaces)
            let places: [PlacesSearchSession.Place]
            switch session.lookup(key) {
            case .cached(let cached):
                places = cached
            case .limitReached:
                return Self.answer([], note: "No more searches for this trip. Plan with the places you already have.")
            case .search:
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = "\(query) in \(place)"
                request.resultTypes = [.pointOfInterest]
                do {
                    let response = try await MKLocalSearch(request: request).start()
                    places = response.mapItems.map { item in
                        PlacesSearchSession.Place(
                            name: item.name ?? "Unknown",
                            category: item.pointOfInterestCategory?.rawValue
                                .replacingOccurrences(of: "MKPOICategory", with: "") ?? "",
                            locality: item.placemark.locality ?? "",
                            address: item.placemark.title ?? ""
                        )
                    }
                    session.store(places, for: key)
                } catch {
                    AppLog.warning("Apple Maps search failed, Local Guide continues without results", properties: ["Error": "\(error)"])
                    // Apple Maps throttles bursts of searches (MKError 4). A thrown error would end the
                    // Local Guide and the whole briefing, so the model gets an empty result it can work
                    // around instead.
                    return Self.answer([], note: "Apple Maps search is unavailable right now. Use well-known places in \(place) that you are sure exist.")
                }
            }

            let unseen = session.takeUnseen(from: places)
            guard !unseen.isEmpty else {
                let note = places.isEmpty
                    ? "Apple Maps found nothing for this. Try a different kind of place."
                    : "Every result for this search was already suggested on another day. Search for a different kind of place."
                return Self.answer([], note: note)
            }
            return Self.answer(unseen)
        }
    }

    private static func answer(_ places: [PlacesSearchSession.Place], note: String? = nil) -> RTSOutput {
        var answer: RTSOutput = [
            "results": .array(places.map { place in
                .object([
                    "name": .string(place.name),
                    "category": .string(place.category),
                    "locality": .string(place.locality),
                    "address": .string(place.address),
                ])
            }),
            "count": .number(Double(places.count)),
        ]
        if let note { answer["note"] = .string(note) }
        return answer
    }

    var toolDescription = "Finds real points of interest (museums, restaurants, parks, viewpoints, neighborhoods) in a place using Apple Maps. Returns up to 6 results with name, category, locality (town or city) and address, never a place it already returned in this trip. Search again with the same words to get more places of that kind."

    var parameterSchema: RTSToolSchema {
        RTSToolSchema(parameters: [
            .init(name: "query", description: "What to look for, e.g. \"art museums\" or \"seafood restaurants\"", type: .string),
            .init(name: "place", description: "City or area to search in", type: .string),
        ])
    }
}
