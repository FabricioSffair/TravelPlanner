//
//  ManualLibrary.swift
//  PocketManuals
//
//  The document list, its files, and the queue that indexes them. The list is
//  persisted as JSON in Application Support; the PDFs live in
//  Documents/Manuals/<id>.pdf; the vectors live in the ManualIndex.
//

import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class ManualLibrary {

    private(set) var documents: [ManualDocument] = []
    /// The embedder indexing and search would use now; `nil` until first checked.
    private(set) var embedderStatus: ManualEmbedderStatus?
    /// The last import or file error, for an alert.
    var lastError: String?

    /// For the Q&A agents: `search(_:topK:)` lives here.
    let index: ManualIndex

    /// Sample ids the user deleted, so they don't come back on the next launch.
    private var removedSampleIDs: Set<String> = []
    private var pending: [String] = []
    private var worker: Task<Void, Never>?

    private struct Persisted: Codable {
        var documents: [ManualDocument]
        var removedSampleIDs: [String]
    }

    init(index: ManualIndex) {
        self.index = index
        load()
        syncSamples()
    }

    // MARK: Paths

    static var manualsDirectory: URL {
        URL.documentsDirectory.appendingPathComponent("Manuals", isDirectory: true)
    }

    static func fileURL(for id: String) -> URL {
        manualsDirectory.appendingPathComponent("\(id).pdf")
    }

    private static var libraryURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("PocketManuals", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    // MARK: Import

    /// Copies a user-chosen PDF into the library and indexes it right away: the user picked it.
    func importPDF(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let id = UUID().uuidString
        let destination = Self.fileURL(for: id)
        do {
            try FileManager.default.createDirectory(at: Self.manualsDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            lastError = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        guard let info = PDFManualInfo.read(at: destination, fallbackTitle: url.deletingPathExtension().lastPathComponent) else {
            try? FileManager.default.removeItem(at: destination)
            lastError = "\(url.lastPathComponent) is not a readable PDF."
            return
        }
        documents.append(ManualDocument(
            id: id,
            title: info.title,
            pageCount: info.pageCount,
            isSample: false,
            indexState: .notIndexed,
            addedAt: Date()
        ))
        save()
        enqueue(id)
    }

    // MARK: Samples

    /// Adds bundled sample PDFs as not indexed. They are never indexed on launch: with no
    /// on-device model (a simulator) that would spend the user's OpenAI key unasked.
    ///
    /// Looks in a `Samples` folder in the bundle and at the bundle root, since a synchronized
    /// group copies a plain folder's files flat. A missing or empty folder adds nothing.
    private func syncSamples() {
        let bundle = Bundle.main
        let urls = (bundle.urls(forResourcesWithExtension: "pdf", subdirectory: "Samples") ?? [])
            + (bundle.urls(forResourcesWithExtension: "pdf", subdirectory: nil) ?? [])
        var seen: Set<String> = []
        var added = false
        for url in urls where seen.insert(url.lastPathComponent).inserted {
            let id = Self.sampleID(for: url.lastPathComponent)
            guard !removedSampleIDs.contains(id), !documents.contains(where: { $0.id == id }) else { continue }
            let destination = Self.fileURL(for: id)
            do {
                try FileManager.default.createDirectory(at: Self.manualsDirectory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: url, to: destination)
                }
            } catch {
                continue
            }
            guard let info = PDFManualInfo.read(at: destination) else {
                continue
            }
            documents.append(ManualDocument(
                id: id,
                // The file name, e.g. "Kitchen Companion (USDA)": the bundled PDFs' metadata titles
                // are long or carry layout notes ("… (Single Page Layout)").
                title: url.deletingPathExtension().lastPathComponent,
                pageCount: info.pageCount,
                isSample: true,
                indexState: .notIndexed,
                addedAt: Date()
            ))
            added = true
        }
        if added { save() }
    }

    /// A UUID derived from the sample's file name, so a sample keeps its id (and its index
    /// entries) across launches and installs.
    static func sampleID(for fileName: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("pocketmanuals.sample:\(fileName)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5 style (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }

    // MARK: Delete

    /// Removes documents from the list, their files, and their pages from the index.
    func delete(ids: [String]) {
        for id in ids {
            guard let document = documents.first(where: { $0.id == id }) else { continue }
            if document.isSample { removedSampleIDs.insert(id) }
            pending.removeAll { $0 == id }
            try? FileManager.default.removeItem(at: Self.fileURL(for: id))
            SpotlightIndex.removeManual(id: id)
        }
        documents.removeAll { ids.contains($0.id) }
        save()
        let index = index
        Task {
            for id in ids {
                // A run still going for this id cleans up after itself; see `runIndex`.
                try? await index.remove(manualID: id)
            }
        }
    }

    // MARK: Indexing

    /// Queues one document. Indexing runs one document at a time.
    func requestIndex(_ id: String) {
        enqueue(id)
    }

    /// Indexes every document again with the active embedder, except samples never indexed.
    /// Non-destructive: pages already stored unchanged for this embedder are skipped, so this
    /// mainly fills the store after the embedder changed (or retries failures).
    func reindexAll() {
        for document in documents {
            if document.isSample, document.indexState == .notIndexed { continue }
            enqueue(document.id)
        }
    }

    /// Hands the OpenAI key to the index and re-checks which embedder is active.
    func updateOpenAIKey(_ key: String?) async {
        await index.setOpenAIKey(key)
        await refreshEmbedderStatus()
    }

    func refreshEmbedderStatus() async {
        embedderStatus = await index.embedderStatus()
    }

    /// The label the index would record now, for spotting documents built by another embedder.
    var activeEmbedderLabel: String? {
        switch embedderStatus {
        case .onDevice: "on-device"
        case .openAI: "OpenAI"
        case .unavailable, nil: nil
        }
    }

    /// Documents the active embedder's store holds, so a search can reach them. A document built
    /// with another embedder is not in the active store until it is re-indexed.
    var searchableDocuments: [ManualDocument] {
        guard let active = activeEmbedderLabel else { return [] }
        return documents.filter { document in
            if case .indexed(_, let embedder) = document.indexState { return embedder == active }
            return false
        }
    }

    private func enqueue(_ id: String) {
        guard !pending.contains(id),
              let position = documents.firstIndex(where: { $0.id == id }),
              !documents[position].isIndexing
        else { return }
        pending.append(id)
        documents[position].indexState = .indexing(progress: 0)
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let id = self.nextPending() {
                await self.runIndex(id)
            }
            self?.worker = nil
        }
    }

    private func nextPending() -> String? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    private func runIndex(_ id: String) async {
        guard let document = documents.first(where: { $0.id == id }) else { return }
        let state: ManualDocument.IndexState
        do {
            let result = try await index.index(
                manualID: id,
                title: document.title,
                fileURL: Self.fileURL(for: id),
                progress: { [weak self] fraction in
                    Task { @MainActor in self?.setProgress(fraction, for: id) }
                }
            )
            state = .indexed(chunks: result.chunks, embedder: result.embedderLabel)
        } catch {
            state = .failed(reason: ManualIndexError.reason(for: error))
        }
        if let position = documents.firstIndex(where: { $0.id == id }) {
            documents[position].indexState = state
            save()
            if case .indexed = state {
                SpotlightIndex.indexManual(id: id, title: document.title)
            }
        } else {
            // Deleted while indexing: the run may have written pages after the delete removed them.
            try? await index.remove(manualID: id)
        }
        await refreshEmbedderStatus()
    }

    /// Progress arrives asynchronously, possibly after the run finished; only an in-flight state
    /// is updated.
    private func setProgress(_ fraction: Double, for id: String) {
        guard let position = documents.firstIndex(where: { $0.id == id }),
              case .indexing = documents[position].indexState
        else { return }
        documents[position].indexState = .indexing(progress: fraction)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.libraryURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return }
        removedSampleIDs = Set(persisted.removedSampleIDs)
        // A run the app quit during is not resumed automatically; it shows as failed with a retry.
        documents = persisted.documents.map { document in
            var document = document
            if document.isIndexing {
                document.indexState = .failed(reason: "interrupted before finishing")
            }
            return document
        }
        // Drop entries whose file is gone (e.g. removed through the Files app).
        documents.removeAll { !FileManager.default.fileExists(atPath: Self.fileURL(for: $0.id).path) }
    }

    private func save() {
        let persisted = Persisted(documents: documents, removedSampleIDs: removedSampleIDs.sorted())
        do {
            let url = Self.libraryURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(persisted).write(to: url, options: .atomic)
        } catch {
            lastError = "Could not save the library: \(error.localizedDescription)"
        }
    }
}
