//
//  ManualDocument.swift
//  PocketManuals
//

import Foundation

/// One PDF in the library. The file lives at `Documents/Manuals/<id>.pdf`.
struct ManualDocument: Identifiable, Codable, Hashable, Sendable {

    enum IndexState: Codable, Hashable, Sendable {
        case notIndexed
        /// 0...1, pages finished over pages with text.
        case indexing(progress: Double)
        /// `embedder` is the label of the embedder that built the chunks, e.g. "on-device".
        case indexed(chunks: Int, embedder: String)
        case failed(reason: String)
    }

    /// A UUID string. Also the manual's id in the index and the prefix of its citation keys.
    let id: String
    var title: String
    var pageCount: Int
    /// Bundled with the app rather than imported. Samples are only indexed on request.
    let isSample: Bool
    var indexState: IndexState
    var addedAt: Date

    var isIndexing: Bool {
        if case .indexing = indexState { return true }
        return false
    }
}
