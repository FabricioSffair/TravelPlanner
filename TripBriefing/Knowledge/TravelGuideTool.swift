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

enum TravelGuideTool {
    static let name = "SearchTravelGuide"

    static func make(guide: TravelGuide, collector: TravelGuideSourceCollector) -> RTSKnowledgeSearchTool {
        RTSKnowledgeSearchTool(
            toolName: name,
            toolDescription: """
            Searches the \(guide.city) Wikivoyage travel guide for practical advice: getting in \
            and around (airport transfers, transit, tickets), staying safe (scams, pickpockets, \
            emergencies), local etiquette and customs (tipping, dress, manners), and staying \
            connected (SIM cards, Wi-Fi). Returns passages with the guide section they came from. \
            An empty result means the guide does not cover it.
            """,
            source: source(guide: guide, collector: collector),
            resultCountRange: 1...4
        )
    }

    /// Maps guide hits to knowledge hits, citing `Wikivoyage › <City> › <Section>`, and records
    /// each returned passage in `collector`.
    static func source(guide: TravelGuide, collector: TravelGuideSourceCollector) -> RTSClosureKnowledgeSource {
        RTSClosureKnowledgeSource { query in
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
