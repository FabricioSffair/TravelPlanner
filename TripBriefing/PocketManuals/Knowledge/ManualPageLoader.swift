//
//  ManualPageLoader.swift
//  PocketManuals
//
//  Wraps the SDK's PDF loader so every page is keyed by the manual's id rather
//  than by where the file happens to live.
//

import Foundation
import Synchronization
import RailtracksSwiftRAG

/// Metadata keys the library writes onto every page, alongside the PDF loader's own `page` and
/// `page_count`.
enum ManualMetadataKey {
    static let manualID = "manual_id"
    static let manualTitle = "manual_title"
    /// Written by `RTSRAGPDFLoader`.
    static let page = "page"
}

/// `RTSRAGPDFLoader` (one document per page), with each page's source rewritten from
/// `<absolute path>#page-N` to `<manualID>#page-N`.
///
/// The loader has no option for the source, and the app container's path changes between
/// installs. The source derives the document id and, with the content hash, decides whether a
/// re-ingest skips a page, so a path-based source would orphan every page after a reinstall and
/// make citations unstable. Rewriting it here, before the pipeline sees the documents, keeps the
/// store, the staleness check and the citation key all path-independent.
struct ManualPageLoader: RTSRAGDocumentLoader {
    let fileURL: URL
    let manualID: String
    let title: String
    /// Receives the number of pages with text once the PDF is read, before any page is ingested.
    /// The progress denominator: the loader skips empty pages, so `pageCount` would overcount.
    let onPagesLoaded: @Sendable (Int) -> Void

    init(fileURL: URL, manualID: String, title: String, onPagesLoaded: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.fileURL = fileURL
        self.manualID = manualID
        self.title = title
        self.onPagesLoaded = onPagesLoaded
    }

    func stream() throws -> RTSRAGDocumentStream {
        let manualID = manualID
        let title = title
        let onPagesLoaded = onPagesLoaded
        return try RTSRAGPDFLoader(path: fileURL, granularity: .page).stream().mapDocuments { pages in
            let rewritten = pages.compactMap { page -> RTSRAGDocument? in
                guard case .integer(let number)? = page.metadata[ManualMetadataKey.page] else { return nil }
                var metadata = page.metadata
                metadata[ManualMetadataKey.manualID] = .string(manualID)
                metadata[ManualMetadataKey.manualTitle] = .string(title)
                // The source-taking initialiser re-derives the id from the new source.
                return RTSRAGDocument(
                    content: page.content,
                    type: page.type,
                    source: ManualCitation.key(manualID: manualID, page: number),
                    metadata: metadata
                )
            }
            onPagesLoaded(rewritten.count)
            return rewritten
        }
    }
}

enum ManualCitation {
    /// `<manualID>#page-N`: stable across installs and file moves.
    static func key(manualID: String, page: Int) -> String {
        "\(manualID)#page-\(page)"
    }
}
