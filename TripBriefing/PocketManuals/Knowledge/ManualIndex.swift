//
//  ManualIndex.swift
//  PocketManuals
//
//  Retrieval over the whole library: every manual's pages, embedded on-device
//  when the model is present (otherwise with OpenAI), in one store per
//  embedder under Application Support. Foundation, NaturalLanguage, Combine
//  and RailtracksSwiftRAG only, so the same files compile into a macOS CLI.
//

import Combine
import Foundation
import NaturalLanguage
import Synchronization
import RailtracksSwiftRAG

// MARK: - Results

/// A retrieved passage, with what a citation needs.
struct ManualHit: Sendable, Hashable {
    let docID: String
    let title: String
    /// 1-based page number.
    let page: Int
    let content: String
    /// Higher is more similar; comparable only within one query.
    let score: Double
    /// `<docID>#page-N`. Independent of where the file lives.
    let citationKey: String
}

/// Which embedder the index uses right now.
enum ManualEmbedderStatus: Sendable, Equatable {
    case onDevice
    case openAI(model: String)
    case unavailable(reason: String)

    var label: String {
        switch self {
        case .onDevice: "On-device (Apple)"
        case .openAI(let model): "OpenAI embeddings (\(model))"
        case .unavailable(let reason): "Unavailable: \(reason)"
        }
    }
}

/// What indexing one manual produced.
struct ManualIndexResult: Sendable {
    /// Chunks the store holds for the manual after this run.
    let chunks: Int
    /// A short label for the embedder, e.g. "on-device" or "OpenAI".
    let embedderLabel: String
    let stats: RTSRAGIngestionStats

    /// True when every page was already stored and nothing was embedded.
    var reusedCache: Bool { stats.documentsCommitted == 0 && stats.documentsSkipped > 0 }
}

enum ManualIndexError: Error, CustomStringConvertible {
    /// No embedder can be used; the reason is shown as is.
    case embedderUnavailable(String)
    /// `what` did not finish in time.
    case timedOut(String)
    case unreadablePDF(String)
    case noText
    case incomplete(String)

    var description: String {
        switch self {
        case .embedderUnavailable(let reason): reason
        case .timedOut(let what): "\(what) timed out"
        case .unreadablePDF(let detail): "could not read the PDF: \(detail)"
        case .noText: "the PDF has no text layer (scanned pages are not supported yet)"
        case .incomplete(let detail): "indexing incomplete: \(detail)"
        }
    }

    /// A short, user-facing reason for any error indexing or search can end with.
    static func reason(for error: Error) -> String {
        switch error {
        case let error as ManualIndexError: error.description
        case is CancellationError: "cancelled"
        case let error as URLError: error.localizedDescription
        default: "\(error)"
        }
    }
}

// MARK: - Index

/// The library's retrieval index. One per app; holds the on-device embedder so its model loads
/// once, and one open store per embedder (two instances over one store directory would diverge).
///
/// Embedder choice, per call: Apple's on-device model when its assets are already on the device
/// (checked without downloading) and it loads within ``prepareTimeout``; otherwise OpenAI
/// `text-embedding-3-small` when an OpenAI key is set; otherwise the index is unavailable. A store
/// is locked to one embedding model, so each embedder has its own store under
/// `<root>/<embedder-id>/`.
actor ManualIndex {

    /// Bump when the document shape, chunk sizing or store layout changes, so stores built the old
    /// way are rebuilt instead of reused.
    static let indexFormatVersion = 1

    /// Chunk budget as a share of the on-device embedder's `maxInputCharacters`. That figure
    /// assumes two characters per token, and a chunk over the 256-token limit is dropped at
    /// ingest. Trip Briefing measured 0.64 as the largest share that drops no chunks.
    static let chunkBudgetFraction = 0.64

    /// How long loading the on-device model may take before it is given up for this process.
    /// Loading assets already on disk takes well under a second.
    static let prepareTimeout: Double = 8

    static let openAIModel = "text-embedding-3-small"

    /// The embedder a call uses, and where its store lives.
    private struct Selection {
        let embedder: any RTSRAGEmbedding
        /// Directory name under the root: `on-device` or `openai-text-embedding-3-small`.
        let storeKey: String
        let label: String
    }

    /// Written next to each store; a store whose manifest does not match is rebuilt.
    private struct StoreManifest: Codable, Equatable {
        let formatVersion: Int
        let embeddingModel: String
    }

    private let root: URL
    private let governors = RTSRAGRateGovernorManager()
    private var openAIKey: String?
    /// Set once the on-device model loaded.
    private var onDevice: RTSRAGAppleEmbedding?
    /// Set when loading it failed or timed out; it is not retried in this process.
    private var onDeviceFailure: String?
    private var stores: [String: RTSRAGFileStore] = [:]

    /// - Parameter root: where the stores live. Defaults to `Application Support/ManualIndex`.
    /// - Parameter openAIKey: used only when the on-device model is unavailable.
    init(root: URL? = nil, openAIKey: String? = nil) {
        self.root = root ?? Self.defaultRoot
        self.openAIKey = openAIKey
    }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ManualIndex", isDirectory: true)
    }

    /// Sets or clears the OpenAI key. Search has no key parameter, so the index holds it.
    func setOpenAIKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        openAIKey = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Whether the on-device model's assets are on this device, without downloading anything.
    /// Same lookup `RTSRAGAppleEmbedding()` makes (English, revision 1).
    nonisolated static var onDeviceAssetsAvailable: Bool {
        NLContextualEmbedding.contextualEmbeddings(
            forValues: [.languages: [NLLanguage.english.rawValue], .revision: 1]
        ).first?.hasAvailableAssets ?? false
    }

    /// The embedder the next call would use. Loads the on-device model if needed (no download,
    /// no network); never calls OpenAI.
    func embedderStatus() async -> ManualEmbedderStatus {
        if await loadOnDevice() != nil { return .onDevice }
        if openAIKey != nil { return .openAI(model: Self.openAIModel) }
        return .unavailable(reason: unavailableReason)
    }

    // MARK: Indexing

    /// Embeds and stores a manual's pages. Pages already stored unchanged are skipped, so calling
    /// it again is cheap and resumes a run that stopped part way.
    ///
    /// - Parameter progress: called with 0...1 as pages finish, on an arbitrary thread.
    func index(
        manualID: String,
        title: String,
        fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ManualIndexResult {
        let selection = try await selectEmbedder()
        let store = try validatedStore(for: selection)
        let runtime = RTSRAGRetrievalRuntime(embedder: selection.embedder, store: store)

        let tracker = ProgressTracker(report: progress)
        // Subscribed before ingesting; `ingest` drains its events before returning, so cancelling
        // after it loses nothing.
        let subscription = runtime.eventPublisher.sink { tracker.handle($0) }
        defer { subscription.cancel() }

        let loader = ManualPageLoader(
            fileURL: fileURL,
            manualID: manualID,
            title: title,
            onPagesLoaded: { tracker.setTotal($0) }
        )
        let stats: RTSRAGIngestionStats
        do {
            stats = try await runtime.ingest(loader: loader, chunker: Self.chunker(for: selection.embedder))
        } catch RTSRAGError.loadFailed(_, let reason) {
            // Thrown by `stream()` when the file is missing; a PDF that will not open arrives as
            // a `loadFailed` event instead, handled below.
            throw ManualIndexError.unreadablePDF(reason)
        }

        if let failure = tracker.loadFailure {
            throw ManualIndexError.unreadablePDF(failure)
        }
        guard stats.documentsLoaded > 0 else {
            throw ManualIndexError.noText
        }
        if stats.documentsWithheld > 0 {
            throw ManualIndexError.incomplete(
                "\(stats.documentsWithheld) of \(stats.documentsLoaded) pages not stored; try again"
            )
        }
        let chunks = try await store.count(matching: [ManualMetadataKey.manualID: .string(manualID)])
        progress(1)
        return ManualIndexResult(chunks: chunks, embedderLabel: selection.label, stats: stats)
    }

    /// Removes a manual's pages from every store on disk, whichever embedder built them.
    func remove(manualID: String) async throws {
        let filter: RTSRAGMetadata = [ManualMetadataKey.manualID: .string(manualID)]
        for key in storeKeysOnDisk() {
            let store = try store(named: key)
            let entries = try await store.find(matching: filter, limit: Int.max)
            for documentID in Set(entries.map(\.documentID)) {
                try await store.deleteDocument(id: documentID)
            }
        }
    }

    /// Chunks stored for a manual in the active embedder's store, or `nil` when no embedder is
    /// available.
    func chunkCount(manualID: String) async -> Int? {
        guard let selection = try? await selectEmbedder(),
              let store = try? validatedStore(for: selection)
        else { return nil }
        return try? await store.count(matching: [ManualMetadataKey.manualID: .string(manualID)])
    }

    // MARK: Search

    /// The `topK` passages closest to `query`, best first: across every indexed manual, or within
    /// one when `manualID` is given. Empty when nothing in that scope is indexed with the active
    /// embedder.
    ///
    /// - Parameter manualID: restricts the search to one manual. Applied as a store metadata
    ///   filter, which runs before the top-K cut, so a scoped search still returns `topK` hits.
    func search(_ query: String, topK: Int, manualID: String? = nil) async throws -> [ManualHit] {
        let selection = try await selectEmbedder()
        let store = try validatedStore(for: selection)
        let filters: RTSRAGMetadata? = manualID.map { [ManualMetadataKey.manualID: .string($0)] }
        guard try await store.count(matching: filters ?? [:]) > 0 else { return [] }
        let runtime = RTSRAGRetrievalRuntime(embedder: selection.embedder, store: store)
        let result = try await runtime.retrieve(query, topK: topK, filters: filters)
        return result.entries.compactMap { hit in
            let metadata = hit.entry.metadata
            guard case .string(let docID)? = metadata[ManualMetadataKey.manualID],
                  case .integer(let page)? = metadata[ManualMetadataKey.page]
            else { return nil }
            var title = docID
            if case .string(let stored)? = metadata[ManualMetadataKey.manualTitle] {
                title = stored
            }
            return ManualHit(
                docID: docID,
                title: title,
                page: page,
                content: hit.entry.content,
                score: Double(hit.score),
                citationKey: ManualCitation.key(manualID: docID, page: page)
            )
        }
    }

    // MARK: Embedder

    private var unavailableReason: String {
        let onDevice = onDeviceFailure ?? "the on-device embedding model is not on this device"
        return "\(onDevice), and no OpenAI key is set"
    }

    private func selectEmbedder() async throws -> Selection {
        if let apple = await loadOnDevice() {
            return Selection(embedder: apple, storeKey: "on-device", label: "on-device")
        }
        if let openAIKey {
            return Selection(
                embedder: RTSRAGOpenAIEmbedding(apiKey: openAIKey, model: Self.openAIModel, governors: governors),
                storeKey: "openai-\(Self.openAIModel)",
                label: "OpenAI"
            )
        }
        throw ManualIndexError.embedderUnavailable(unavailableReason)
    }

    /// The on-device embedder, when its assets are already present and it loads in time. Never
    /// requests a download: on a simulator without the model, `requestAssets` never completes.
    private func loadOnDevice() async -> RTSRAGAppleEmbedding? {
        if let onDevice { return onDevice }
        guard onDeviceFailure == nil else { return nil }
        guard Self.onDeviceAssetsAvailable else { return nil }
        do {
            let candidate = try RTSRAGAppleEmbedding()
            try await withDeadline(
                seconds: Self.prepareTimeout,
                timeoutError: { ManualIndexError.timedOut("on-device model") },
                operation: { try await candidate.prepare() }
            )
            // Another call may have loaded it while this one was suspended.
            if let onDevice { return onDevice }
            onDevice = candidate
            return candidate
        } catch {
            // A timed-out embedder may still be stuck inside `prepare()`; it is dropped, not reused.
            if case ManualIndexError.timedOut = error {
                onDeviceFailure = "the on-device model timed out loading"
            } else {
                onDeviceFailure = "the on-device model failed to load (\(ManualIndexError.reason(for: error)))"
            }
            return nil
        }
    }

    /// On-device: a share of the 256-token ceiling (see ``chunkBudgetFraction``). Embedders
    /// without a ceiling (OpenAI) use the SDK default.
    static func chunker(for embedder: any RTSRAGEmbedding) -> RTSRAGSentenceChunker {
        guard let ceiling = embedder.maxInputCharacters else {
            return RTSRAGSentenceChunker()
        }
        return RTSRAGSentenceChunker(maxCharacters: max(64, Int(Double(ceiling) * chunkBudgetFraction)))
    }

    // MARK: Stores

    /// The open store for `selection`, rebuilt first when its manifest is from another format or
    /// embedding model.
    private func validatedStore(for selection: Selection) throws -> RTSRAGFileStore {
        let directory = root.appendingPathComponent(selection.storeKey, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let expected = StoreManifest(
            formatVersion: Self.indexFormatVersion,
            embeddingModel: selection.embedder.modelIdentifier
        )
        let found = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(StoreManifest.self, from: $0) }
        if found != expected {
            if FileManager.default.fileExists(atPath: directory.path) {
                stores[selection.storeKey] = nil
                try? FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(expected).write(to: manifestURL, options: .atomic)
        }
        return try store(named: selection.storeKey)
    }

    private func store(named key: String) throws -> RTSRAGFileStore {
        if let store = stores[key] { return store }
        let store = try RTSRAGFileStore(directory: root.appendingPathComponent(key, isDirectory: true))
        stores[key] = store
        return store
    }

    private func storeKeysOnDisk() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
    }
}

// MARK: - Progress

/// Turns ingest events into a 0...1 fraction of pages finished. Events arrive on the runtime's
/// delivery queue; the page total arrives from the loader.
private final class ProgressTracker: Sendable {
    private struct State {
        var total = 0
        var finished = 0
        var loadFailure: String?
    }
    private let state = Mutex(State())
    private let report: @Sendable (Double) -> Void

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    var loadFailure: String? { state.withLock { $0.loadFailure } }

    func setTotal(_ total: Int) {
        state.withLock { $0.total = total }
    }

    func handle(_ event: RTSRAGIngestEvent) {
        let fraction: Double? = state.withLock { state in
            switch event {
            case .documentCommitted, .documentSkipped, .documentWithheld, .documentEmpty:
                state.finished += 1
                guard state.total > 0 else { return nil }
                return min(1, Double(state.finished) / Double(state.total))
            case .loadFailed(let error):
                state.loadFailure = "\(error)"
                return nil
            case .documentLoaded, .documentChunked, .batchEmbedded, .batchFailed:
                return nil
            }
        }
        if let fraction { report(fraction) }
    }
}
