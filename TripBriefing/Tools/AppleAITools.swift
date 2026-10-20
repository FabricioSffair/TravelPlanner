//
//  AppleAITools.swift
//  TripBriefing
//
//  Makes the three trip tools callable by Apple's on-device model. The Apple
//  path hands LanguageModelSession only RTSAppleAIToolNode tools and drops any
//  other RTSToolNode with a warning, so without these the Weather Scout and the
//  Local Guide would run on-device with no tools at all.
//
//  Same pattern as the SDK's RTSKnowledgeSearchTool: the conformance carries the
//  availability, so the tools stay one type on the app's iOS 18 / macOS 15 floor. Only
//  `Arguments` and `Output` are declared; the protocol's defaults bridge
//  `call(arguments:)` to the existing `callableRoutine` and trace it like a cloud
//  call. Each tool's explicit `parameterSchema` still serves the cloud providers.
//  Property names must match the keys `callableRoutine` reads.
//

import Foundation
import FoundationModels
import RailtracksSwift

@available(iOS 26, macOS 26, *)
extension GeocodePlaceTool: RTSAppleAIToolNode {
    @Generable
    struct Arguments: Encodable {
        @Guide(description: "City or place name, e.g. \"Lisbon, Portugal\"")
        var place: String
    }

    typealias Output = String
}

@available(iOS 26, macOS 26, *)
extension DailyForecastTool: RTSAppleAIToolNode {
    @Generable
    struct Arguments: Encodable {
        @Guide(description: "Latitude in degrees, from GeocodePlace")
        var latitude: Double
        @Guide(description: "Longitude in degrees, from GeocodePlace")
        var longitude: Double
        @Guide(description: "First day of the trip, yyyy-MM-dd")
        var start: String
        @Guide(description: "Last day of the trip, yyyy-MM-dd")
        var end: String
    }

    typealias Output = String
}

@available(iOS 26, macOS 26, *)
extension PlacesSearchTool: RTSAppleAIToolNode {
    @Generable
    struct Arguments: Encodable {
        @Guide(description: "What to look for, e.g. \"art museums\" or \"seafood restaurants\"")
        var query: String
        @Guide(description: "City or area to search in")
        var place: String
    }

    typealias Output = String
}
