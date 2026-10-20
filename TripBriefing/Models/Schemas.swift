//
//  Schemas.swift
//  TripBriefing
//
//  Structured outputs. `@RTSSchema` synthesizes `rtsSchema` so the agents can
//  ask the model for exactly these shapes, and `decode(from:)` turns the
//  returned JSON string back into the type.
//

import Foundation
import RailtracksSwift

@RTSSchema
struct Phrase: Codable, Hashable {
    let phrase: String
    let pronunciation: String
    let meaning: String
    let whenToUse: String
}

@RTSSchema
struct PhraseBook: Codable, Hashable {
    let language: String
    let greeting: String
    let phrases: [Phrase]
}

@RTSSchema
struct DayPlan: Codable, Hashable {
    let day: String
    let morning: String
    let afternoon: String
    let evening: String
}

@RTSSchema
struct TripBriefingReport: Codable, Hashable {
    let headline: String
    let weatherSummary: String
    let days: [DayPlan]
    let packingList: [String]
    let tips: [String]
}

// MARK: - Weather Scout

@RTSSchema
struct WeatherDay: Codable, Hashable {
    /// yyyy-MM-dd
    let date: String
    /// A few words, e.g. "Overcast" or "Light rain".
    let condition: String
    let maxC: Double
    let minC: Double
    /// When the forecast gives one.
    let rainChancePercent: Double?
}

@RTSSchema
struct WeatherReport: Codable, Hashable {
    let days: [WeatherDay]
    /// Two sentences on the period as a whole.
    let outlook: String
    /// True when the dates are too far out and the readings are last year's, not a forecast.
    let isHistorical: Bool
}

// MARK: - Local Guide

@RTSSchema
struct ItineraryActivity: Codable, Hashable {
    /// "Morning", "Afternoon" or "Evening".
    let slot: String
    /// A few words, e.g. "Walk through Alfama".
    let title: String
    /// The real place name from PlacesSearch.
    let place: String
    /// One sentence.
    let details: String
}

/// The three activities are a list with a `slot` each, not `morning`/`afternoon`/`evening`
/// fields: the SDK turns each field of the same nested type into its own named type, and
/// FoundationModels rejects the schema ("Duplicate type ItineraryActivity"). A list of one type
/// converts fine, as PhraseBook's does.
@RTSSchema
struct ItineraryDay: Codable, Hashable {
    /// yyyy-MM-dd
    let date: String
    let activities: [ItineraryActivity]
}

@RTSSchema
struct Itinerary: Codable, Hashable {
    let days: [ItineraryDay]
}

// MARK: - Compact text

extension ItineraryActivity {
    /// The name alone: the model sometimes copies PlacesSearch's address in too.
    var placeName: String {
        place.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? place
    }
}

// What the Concierge, the Packing List and the trip notes read: one line per day, no JSON
// punctuation. Shorter than the Markdown these agents used to write, which matters for the
// on-device context window.

extension WeatherReport {
    var compactText: String {
        let lines = days.map { day in
            var line = "\(day.date): \(day.condition), max \(Self.degrees(day.maxC)) °C, min \(Self.degrees(day.minC)) °C"
            if let rain = day.rainChancePercent { line += ", rain chance \(Int(rain.rounded())) %" }
            return line
        }
        let source = isHistorical ? "Last year's readings for the same dates, not a forecast." : "Forecast."
        return ([source] + lines + ["Outlook: \(outlook)"]).joined(separator: "\n")
    }

    static func degrees(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

extension Itinerary {
    var compactText: String {
        days.enumerated().map { index, day in
            let slots = day.activities.map { "\($0.slot.lowercased()) \($0.title) at \($0.placeName)" }
            return "Day \(index + 1) (\(day.date)): \(slots.joined(separator: "; "))."
        }.joined(separator: "\n")
    }
}
