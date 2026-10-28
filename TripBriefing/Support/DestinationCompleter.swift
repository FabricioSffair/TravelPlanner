//
//  DestinationCompleter.swift
//  TripBriefing
//
//  City suggestions for the destination field, from MapKit's search completer. A typo in the
//  destination reaches every agent, the weather lookup and the Wikivoyage fetch, so the form
//  offers real place names while the traveler types.
//

import Foundation
import MapKit

@MainActor @Observable
final class DestinationCompleter: NSObject, MKLocalSearchCompleterDelegate {
    /// "London, United Kingdom", best match first.
    private(set) var suggestions: [String] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    /// The suggestion just picked, so writing it into the field does not search for it again.
    @ObservationIgnored private var picked: String?

    static let maxSuggestions = 4

    override init() {
        super.init()
        completer.resultTypes = .address
        completer.addressFilter = MKAddressFilter(including: .locality)
        completer.delegate = self
    }

    /// Searches for `text`, or clears the suggestions when it is too short or was just picked.
    func update(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        // The macOS suggestion menu writes the chosen city straight into the field.
        if suggestions.contains(query) { picked = query }
        guard query.count >= 2, query != picked else {
            completer.cancel()
            suggestions = []
            return
        }
        picked = nil
        completer.queryFragment = query
    }

    func pick(_ suggestion: String) {
        picked = suggestion
        completer.cancel()
        suggestions = []
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        var seen = Set<String>()
        let names = completer.results
            .map(Self.destination(from:))
            .filter { seen.insert($0).inserted }
        MainActor.assumeIsolated {
            suggestions = Array(names.prefix(Self.maxSuggestions))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated { suggestions = [] }
    }

    /// The city and its country, the form the rest of the app expects: "London" with the subtitle
    /// "England, United Kingdom" becomes "London, United Kingdom".
    nonisolated static func destination(from completion: MKLocalSearchCompletion) -> String {
        let country = completion.subtitle
            .split(separator: ",")
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !country.isEmpty, country != completion.title else { return completion.title }
        return "\(completion.title), \(country)"
    }
}
