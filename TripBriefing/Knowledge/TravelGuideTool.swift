//
//  TravelGuideTool.swift
//  TripBriefing
//
//  Exposes a TravelGuide to an agent as RTSKnowledgeSearchTool, and records
//  every passage it hands over so the UI can cite exactly what was retrieved.
//

import Foundation
import Synchronization
import RailtracksSwift

/// Thread-safe record of the sources a run's searches returned, in first-seen order.
final class TravelGuideSourceCollector: Sendable {
    private let state = Mutex<[TravelGuideHit]>([])

    func record(_ hits: [TravelGuideHit]) {
        state.withLock { $0.append(contentsOf: hits) }
    }

    /// Every hit, in the order the tool returned them.
    var hits: [TravelGuideHit] {
        state.withLock { $0 }
    }

    /// `Wikivoyage › <City> › <Section>`, deduplicated, first-seen order.
    var sourceLabels: [String] {
        var seen = Set<String>()
        return hits.map(\.sourceLabel).filter { seen.insert($0).inserted }
    }

    func reset() {
        state.withLock { $0.removeAll() }
    }
}

/// Counts one tool's searches, from any thread.
final class SearchCounter: Sendable {
    private let count = Mutex(0)

    /// This search's number, starting at 1.
    func next() -> Int {
        count.withLock { $0 += 1; return $0 }
    }
}

/// Thrown by a search tool once its `maxSearches` are spent. The on-device Concierge, whose
/// searches all came back empty, searched 57 times until its context filled; only a thrown error
/// ends its turn. The briefing then runs the Concierge without the guide; the chat answers that
/// nothing was found.
struct SearchLimitReached: Error, CustomStringConvertible {
    let toolName: String
    var description: String { "\(toolName) ToolCallLimitReached" }
}

enum TravelGuideTool {
    static let name = "SearchTravelGuide"

    /// - Parameter maxSearches: searches the tool answers before it throws `SearchLimitReached`;
    ///   `nil` for no limit.
    static func make(guide: TravelGuide, collector: TravelGuideSourceCollector, maxSearches: Int? = nil) -> RTSKnowledgeSearchTool {
        RTSKnowledgeSearchTool(
            toolName: name,
            toolDescription: """
            Searches the \(guide.city) Wikivoyage travel guide for practical advice: getting in \
            and around (airport transfers, transit, tickets), staying safe (scams, pickpockets, \
            emergencies), local etiquette and customs (tipping, dress, manners), and staying \
            connected (SIM cards, Wi-Fi). Returns passages with the guide section they came from. \
            An empty result means the guide does not cover it.
            """ + (guide.isKeywordSearch ? " " + PassageRetriever.keywordSearchHint : ""),
            source: source(guide: guide, collector: collector, maxSearches: maxSearches),
            resultCountRange: 1...4
        )
    }

    /// Maps guide hits to knowledge hits, citing `Wikivoyage › <City> › <Section>`, and records
    /// each returned passage in `collector`.
    static func source(guide: TravelGuide, collector: TravelGuideSourceCollector, maxSearches: Int? = nil) -> RTSClosureKnowledgeSource {
        let searches = SearchCounter()
        return RTSClosureKnowledgeSource { query in
            if let maxSearches, searches.next() > maxSearches {
                throw SearchLimitReached(toolName: name)
            }
            let found = try await guide.search(query.text, topK: query.topK)
            collector.record(found)
            return found.map { hit in
                RTSKnowledgeHit(
                    content: hit.content,
                    source: hit.sourceLabel,
                    score: hit.score,
                    metadata: [
                        "section": .string(hit.section),
                        "url": .string(hit.articleURL.absoluteString),
                    ]
                )
            }
        }
    }
}
