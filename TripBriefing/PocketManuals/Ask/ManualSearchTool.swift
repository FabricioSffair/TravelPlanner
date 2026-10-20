//
//  ManualSearchTool.swift
//  PocketManuals
//
//  Exposes the library index to an agent as RTSKnowledgeSearchTool, and records
//  every passage it hands over, so the Verifier and the UI see exactly what was
//  retrieved.
//

import Foundation
import Synchronization
import RailtracksSwift

/// Thread-safe record of the passages a run's searches returned, in first-seen order.
final class ManualSourceCollector: Sendable {
    private let state = Mutex<[ManualHit]>([])

    func record(_ hits: [ManualHit]) {
        state.withLock { $0.append(contentsOf: hits) }
    }

    /// Every hit, deduplicated by citation key and content, in the order the tool returned them.
    var hits: [ManualHit] {
        var seen = Set<String>()
        return state.withLock { $0 }.filter { seen.insert("\($0.citationKey)\n\($0.content)").inserted }
    }

    /// Each retrieved page's passages joined, keyed by `citationKey`, in first-seen order.
    var passagesByCitation: [(citationKey: String, title: String, page: Int, text: String)] {
        var order: [String] = []
        var grouped: [String: (title: String, page: Int, parts: [String])] = [:]
        for hit in hits {
            if grouped[hit.citationKey] == nil {
                order.append(hit.citationKey)
                grouped[hit.citationKey] = (hit.title, hit.page, [])
            }
            grouped[hit.citationKey]?.parts.append(hit.content)
        }
        return order.compactMap { key in
            grouped[key].map { (key, $0.title, $0.page, $0.parts.joined(separator: "\n…\n")) }
        }
    }

    func reset() {
        state.withLock { $0.removeAll() }
    }
}

enum ManualSearchTool {
    static let name = "SearchManuals"

    /// - Parameters:
    ///   - manualID: restricts searches to one manual; `nil` searches the whole library.
    ///   - scopeDescription: what the model is told it is searching, e.g. "the user's manuals:
    ///     Kitchen Companion (USDA), Energy Saver Guide (DOE)".
    static func make(
        index: ManualIndex,
        manualID: String?,
        scopeDescription: String,
        collector: ManualSourceCollector
    ) -> RTSKnowledgeSearchTool {
        RTSKnowledgeSearchTool(
            toolName: name,
            toolDescription: """
            Searches \(scopeDescription) for passages relevant to a question. Each result has the \
            passage text, a `source` ("<manual title>, p. <page>") and `metadata.citationKey`, the \
            identifier to cite. Search again with different wording (or per sub-question) when the \
            first results do not answer the question. An empty result means nothing relevant \
            was found.
            """,
            source: source(index: index, manualID: manualID, collector: collector),
            resultCountRange: 1...8
        )
    }

    /// Maps manual hits to knowledge hits and records each returned passage in `collector`.
    static func source(index: ManualIndex, manualID: String?, collector: ManualSourceCollector) -> RTSClosureKnowledgeSource {
        RTSClosureKnowledgeSource { query in
            let found = try await index.search(query.text, topK: query.topK, manualID: manualID)
            collector.record(found)
            return found.map { hit in
                RTSKnowledgeHit(
                    content: hit.content,
                    source: "\(hit.title), p. \(hit.page)",
                    score: hit.score,
                    metadata: [
                        "citationKey": .string(hit.citationKey),
                        "title": .string(hit.title),
                        "page": .number(Double(hit.page)),
                    ]
                )
            }
        }
    }
}
