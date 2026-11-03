//
//  TravelGuideIndex.swift
//  TripBriefing
//
//  Retrieval over the destination's Wikivoyage article: fetch it as plain
//  text, keep the practical sections, embed them (on-device when the model is
//  present, otherwise OpenAI) and store the vectors per destination and
//  embedder under Caches. With no embedder at all, the sections go to Spotlight
//  instead and are searched by keyword. Foundation, Combine, NaturalLanguage and
//  RailtracksSwiftRAG only, so the same file compiles into a command-line check.
//
//  Wikivoyage text is CC BY-SA 4.0; anything shown from it needs attribution.
//

import Combine
import Foundation
import NaturalLanguage
import Synchronization
import RailtracksSwiftRAG

// MARK: - Article

/// One Wikivoyage article as plain text.
struct WikivoyageArticle: Sendable {
    /// The resolved title, after redirects.
    let title: String
    let url: URL
    let extract: String
}

enum WikivoyageClient {

    /// Wikimedia asks API clients for a descriptive User-Agent with a way to reach the project.
    static let userAgent = "TripBriefing/1.0"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: configuration)
    }()

    /// Titles to try for a destination: the city name first ("Lisbon" from "Lisbon, Portugal"),
    /// then the full string.
    static func candidateTitles(for destination: String) -> [String] {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let city = trimmed.split(separator: ",").first.map {
            String($0).trimmingCharacters(in: .whitespaces)
        } ?? trimmed
        return city == trimmed ? [trimmed] : [city, trimmed]
    }

    /// The first candidate title that resolves to an article, or `nil` when none does.
    /// Requests go one at a time, never in parallel.
    static func fetchArticle(for destination: String) async throws -> WikivoyageArticle? {
        for title in candidateTitles(for: destination) where !title.isEmpty {
            if let article = try await fetchArticle(title: title) {
                return article
            }
        }
        return nil
    }

    static func fetchArticle(title: String) async throws -> WikivoyageArticle? {
        var components = URLComponents(string: "https://en.wikivoyage.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "extracts"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "exsectionformat", value: "wiki"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "titles", value: title),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TravelGuideError.http(http.statusCode)
        }

        struct Envelope: Decodable {
            struct Query: Decodable { let pages: [String: Page] }
            struct Page: Decodable {
                let title: String?
                let missing: String?
                let invalid: String?
                let extract: String?
            }
            let query: Query?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        // A missing page comes back as pages["-1"] with a "missing" key.
        guard let page = envelope.query?.pages.values.first,
              page.missing == nil, page.invalid == nil,
              let resolved = page.title,
              let extract = page.extract,
              !extract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return WikivoyageArticle(title: resolved, url: articleURL(for: resolved), extract: extract)
    }

    static func articleURL(for title: String) -> URL {
        let path = title.replacingOccurrences(of: " ", with: "_")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://en.wikivoyage.org/wiki/\(encoded)")!
    }
}

// MARK: - Sections

/// A top-level (`== X ==`) section of an article. Subsection headings stay in the text as
/// plain lines, which helps retrieval ("By plane", "Scams").
struct WikivoyageSection: Sendable, Hashable {
    let name: String
    let text: String
}

enum WikivoyageSections {

    /// The sections that ground practical tips. Eat and Drink are kept for tipping and dining
    /// etiquette; See, Do, Buy, Sleep and the rest are dropped to keep indexing short.
    static let kept: Set<String> = [
        "Understand", "Get in", "Get around", "Eat", "Drink", "Stay safe", "Respect", "Cope",
        "Connect", "Talk",
    ]

    /// Splits an `exsectionformat=wiki` extract into its top-level sections, in article order,
    /// and keeps only ``kept``.
    static func practicalSections(of extract: String) -> [WikivoyageSection] {
        split(extract).filter { kept.contains($0.name) && !$0.text.isEmpty }
    }

    static func split(_ extract: String) -> [WikivoyageSection] {
        var sections: [WikivoyageSection] = []
        var current: String?
        var lines: [String] = []

        func flush() {
            if let current {
                let text = lines.joined(separator: "\n")
                    .replacingOccurrences(of: "\n\n\n", with: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                sections.append(WikivoyageSection(name: current, text: text))
            }
            lines = []
        }

        for rawLine in extract.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let (level, title) = heading(line) {
                if level == 2 {
                    flush()
                    current = title
                } else {
                    // `=== Sub ===` and deeper: keep the title as a line of its own.
                    lines.append("")
                    lines.append("\(title).")
                }
            } else {
                lines.append(line)
            }
        }
        flush()
        return sections
    }

    /// `== Get in ==` → (2, "Get in"); nil for anything else.
    private static func heading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("=="), line.hasSuffix("==") else { return nil }
        let level = line.prefix { $0 == "=" }.count
        guard level >= 2, line.count > level * 2 else { return nil }
        let title = line.dropFirst(level).dropLast(level).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (level, title)
    }
}

// MARK: - Errors

enum TravelGuideError: Error, CustomStringConvertible {
    case http(Int)
    case articleNotFound(String)
    case noPracticalSections(String)
    case incompleteIngest(String)
    /// No embedder can be used; the reason is shown as is.
    case embedderUnavailable(String)
    /// `what` did not finish in time.
    case timedOut(String)
    /// Donating to Spotlight, the fallback when no embedder can be used, failed.
    case spotlightFailed(String)

    var description: String {
        switch self {
        case .http(let code): "Wikivoyage returned HTTP \(code)"
        case .articleNotFound(let destination): "no Wikivoyage article for \(destination)"
        case .noPracticalSections(let title): "the \(title) article has no practical sections"
        case .incompleteIngest(let detail): "indexing incomplete: \(detail)"
        case .embedderUnavailable(let reason): reason
        case .timedOut(let what): "\(what) timed out"
        case .spotlightFailed(let detail): "Spotlight indexing failed: \(detail)"
        }
    }

    /// A short, user-facing reason for any error the guide can end with.
    static func reason(for error: Error) -> String {
        switch error {
        case let error as TravelGuideError: error.description
        case is CancellationError: "cancelled"
        case let error as URLError: error.localizedDescription
        default: "\(error)"
        }
    }
}

// MARK: - Deadline

/// Returns `operation`'s result, or throws `timeoutError` after `seconds`, whichever comes first.
///
/// Unstructured on purpose. A task-group race waits for every child before it returns, so an
/// operation that ignores cancellation (an asset request that never completes) would hold it
/// forever. Here the operation runs in its own task, is cancelled on timeout, and is abandoned
/// if it keeps going.
func withDeadline<T: Sendable>(
    seconds: Double,
    timeoutError: @escaping @Sendable () -> Error,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
            let work = Task {
                do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                work.cancel()
                race.finish(.failure(timeoutError()))
            }
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// First result wins; later ones are dropped.
private final class DeadlineRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var early: Result<T, Error>?
        var finished = false
    }
    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let pending: Result<T, Error>? = state.withLock { state in
            if let early = state.early {
                state.early = nil
                return early
            }
            state.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func finish(_ result: Result<T, Error>) {
        let continuation: CheckedContinuation<T, Error>? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            if let continuation = state.continuation {
                state.continuation = nil
                return continuation
            }
            state.early = result
            return nil
        }
        continuation?.resume(with: result)
    }
}

// MARK: - Guide

/// A retrieved passage, with what a citation needs.
struct TravelGuideHit: Sendable, Hashable {
    let content: String
    let city: String
    let section: String
    let articleURL: URL
    let score: Double

    /// `Wikivoyage › Lisbon › Get around`
    var sourceLabel: String { "Wikivoyage › \(city) › \(section)" }
}

/// Where a guide's or a trip's passages are searched: a vector store, or Spotlight when no
/// embedder can be used.
enum PassageRetriever: Sendable {
    case vector(RTSRAGRetrievalRuntime)
    /// Keyword search. A Spotlight hit carries its document's source but no metadata, so `labels`
    /// maps each source this index donated to its section or part. Hits from any other source are
    /// dropped.
    case spotlight(RTSRAGSpotlightSearcher, labels: [String: String])

    /// One retrieved passage. `label` is the section or part, `nil` when the store has none.
    struct Passage: Sendable {
        let content: String
        let label: String?
        let score: Double
    }

    /// Appended to a search tool's description when the search is by keyword. No "search again":
    /// told that, the on-device Concierge searched 57 times, all empty, until its context filled.
    static let keywordSearchHint = """
    This search matches words, not meaning: use one or two specific words, for example "transit" \
    or "SIM".
    """

    var isKeywordSearch: Bool {
        if case .spotlight = self { true } else { false }
    }

    /// At most `topK` passages, best first. `labelKey` is the metadata key the vector store keeps
    /// the label under. `ignoring` lists words every passage of this index holds, such as the
    /// city's name; keyword search leaves them out (see `keywordTerms`).
    func retrieve(_ query: String, topK: Int, labelKey: String, ignoring: Set<String> = []) async throws -> [Passage] {
        switch self {
        case .vector(let runtime):
            let result = try await runtime.retrieve(query, topK: topK)
            return result.entries.map { hit in
                var label: String?
                if case .string(let name)? = hit.entry.metadata[labelKey] {
                    label = name
                }
                return Passage(content: hit.entry.content, label: label, score: Double(hit.score))
            }
        case .spotlight(let searcher, let labels):
            // Spotlight returns a passage only when it holds every word of the query, so "safety
            // Vancouver" found nothing. The whole query runs first, then each of its words alone;
            // a passage ranks by how many of the searches found it, then by its best rank.
            let terms = Self.keywordTerms(of: query, ignoring: ignoring)
            let queries = [query] + terms.filter { $0 != query.lowercased() }
            var found: [String: (text: String, label: String, matches: Int, rank: Int)] = [:]
            for text in queries {
                // Asks for more than needed: the namespace also holds other cities' guides, and an
                // earlier trip's notes until their deletion lands, and those are dropped here.
                for hit in try await searcher.search(text, limit: max(topK * 4, 20)) {
                    guard let source = hit.source, let label = labels[source] else { continue }
                    if var match = found[hit.identifier] {
                        match.matches += 1
                        match.rank = min(match.rank, hit.rank)
                        found[hit.identifier] = match
                    } else {
                        found[hit.identifier] = (hit.text, label, 1, hit.rank)
                    }
                }
            }
            let ranked = found.values.sorted { ($0.matches, -$0.rank) > ($1.matches, -$1.rank) }
            // Spotlight ranks but does not score, so the score falls with the rank.
            return ranked.prefix(topK).enumerated().map { rank, hit in
                Passage(content: hit.text, label: hit.label, score: 1 / Double(rank + 1))
            }
        }
    }

    /// Words that are left out of keyword searches: they match nearly every passage or none.
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "how", "what", "where", "when", "from", "about", "into",
        "near", "including", "tips", "local", "city", "trip", "best",
    ]

    /// The words of `query` worth a keyword search of their own, lowercased, in order, without
    /// short words, `stopWords` or `ignoring`. A plural or "-ing"/"-ed" ending is cut, because
    /// Spotlight matches the start of a word: "connect" finds "connected" and "connectivity",
    /// "connected" does not find "connect".
    static func keywordTerms(of query: String, ignoring: Set<String>) -> [String] {
        var seen = Set<String>()
        return query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) && !ignoring.contains($0) }
            .map { word in
                for suffix in ["ing", "ed", "s"] where word.hasSuffix(suffix) && word.count - suffix.count >= 4 {
                    return String(word.dropLast(suffix.count))
                }
                return word
            }
            .filter { seen.insert($0).inserted }
    }

    /// The lowercased words of `name`, for `retrieve(_:topK:labelKey:ignoring:)`.
    static func words(of name: String) -> Set<String> {
        Set(name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}

/// One destination's indexed guide, ready to search.
struct TravelGuide: Sendable {
    let city: String
    let articleTitle: String
    let articleURL: URL
    let sections: [String]
    /// "on-device", "OpenAI embeddings" or "Spotlight".
    let embedderLabel: String
    /// True when the store was reused rather than embedded in this call.
    let fromCache: Bool
    let retriever: PassageRetriever

    /// True when the guide is in Spotlight, which matches words rather than meaning.
    var isKeywordSearch: Bool { retriever.isKeywordSearch }

    func search(_ query: String, topK: Int) async throws -> [TravelGuideHit] {
        // Every passage starts with the city's name, so a keyword search leaves it out.
        let passages = try await retriever.retrieve(
            query, topK: topK, labelKey: TravelGuideLibrary.MetadataKey.section,
            ignoring: PassageRetriever.words(of: city)
        )
        return passages.map { passage in
            TravelGuideHit(
                content: passage.content,
                city: city,
                section: passage.label ?? "Guide",
                articleURL: articleURL,
                score: passage.score
            )
        }
    }
}

/// Builds and caches guides. One per app; holds the on-device embedder so its model is loaded
/// once.
///
/// Embedder choice, per call: Apple's on-device model when its assets are already on the device
/// (checked without downloading) and it loads within ``prepareTimeout``; otherwise OpenAI
/// `text-embedding-3-small` when an OpenAI key is given; otherwise no embedder, and the guide is
/// donated to Spotlight and searched by keyword (the simulator, where the on-device model does
/// not load). A store is locked to one embedding model, so each embedder has its own store.
actor TravelGuideLibrary {

    enum MetadataKey {
        static let section = "section"
        static let articleURL = "article_url"
        static let city = "city"
    }

    /// Bump whenever the kept sections, document shape, chunk sizing or store layout change, so
    /// stores built the old way are rebuilt instead of reused.
    static let indexFormatVersion = 3

    /// Chunk budget as a share of the embedder's `maxInputCharacters`. That figure assumes two
    /// characters per token, but URLs, numbers and Portuguese place names run denser, and a chunk
    /// over the 256-token limit is dropped at ingest. Measured on Lisbon (512-character ceiling):
    /// every budget from 332 to 512 characters drops 1 to 11 chunks, and 307 to 331 drops none.
    /// 0.64 (327 characters) sits just inside that band.
    static let chunkBudgetFraction = 0.64

    /// How long loading the on-device model may take before it is given up for this process.
    /// Loading assets already on disk takes well under a second.
    static let prepareTimeout: Double = 8

    static let openAIModel = "text-embedding-3-small"

    /// The embedder a guide (or a trip's notes) is built with, and where its store lives.
    struct Selection {
        let embedder: any RTSRAGEmbedding
        /// Directory name under the city: `on-device` or `openai-text-embedding-3-small`.
        let cacheKey: String
        let label: String
    }

    /// Written next to the store after a clean ingest. Its presence is what "complete" means.
    private struct Manifest: Codable {
        /// `nil` in manifests written before versioning, which therefore never match.
        let formatVersion: Int?
        let city: String
        let articleTitle: String
        let articleURL: URL
        let sections: [String]
        let embeddingModel: String
        let indexedAt: Date
    }

    /// Written under `spotlight/` after every section of a guide was donated to Spotlight. Spotlight
    /// hits come back without metadata, so this keeps each source's section for citations.
    private struct SpotlightManifest: Codable {
        let formatVersion: Int
        let city: String
        let articleTitle: String
        let articleURL: URL
        let sections: [String]
        /// `<articleURL>#<Section>` → `<Section>`, one per donated section.
        let sectionsBySource: [String: String]
        let indexedAt: Date
    }

    /// Shown where an embedder's label would be, and the directory name of the Spotlight manifest.
    static let spotlightLabel = "Spotlight"
    static let spotlightCacheKey = "spotlight"

    /// The Spotlight namespace for `name` ("guide" or "tripnotes"), under the bundle id. Neither
    /// name is a prefix of the other, so one namespace's `deleteAll()` never reaches the other.
    nonisolated static func spotlightNamespace(_ name: String) -> String {
        "\(Bundle.main.bundleIdentifier ?? "TripBriefing").\(name)"
    }

    /// Feeds in-memory documents to `ingest`, no temp files.
    struct InMemoryLoader: RTSRAGDocumentLoader {
        let source: URL
        let documents: [RTSRAGDocument]
        func stream() throws -> RTSRAGDocumentStream {
            let documents = documents
            return RTSRAGDocumentStream(sources: [source]) { _ in documents }
        }
    }

    /// What happened during the last `guide(for:)`, for logs and the CLI.
    struct Timings: Sendable {
        var prepare: TimeInterval = 0
        var fetch: TimeInterval = 0
        var ingest: TimeInterval = 0
        var stats: RTSRAGIngestionStats?
    }

    private let cacheRoot: URL
    private let chunkCharactersOverride: Int?
    private let governors = RTSRAGRateGovernorManager()
    /// Set once the on-device model loaded.
    private var onDevice: RTSRAGAppleEmbedding?
    /// Set when loading it failed or timed out; it is not retried in this process.
    private var onDeviceFailure: String?
    private var assetRequestStarted = false
    private(set) var lastTimings = Timings()

    /// - Parameter cacheRoot: where per-destination stores live. Defaults to
    ///   `Caches/TravelGuides`.
    /// - Parameter chunkCharacters: overrides the chunk budget; for measuring sizes only.
    init(cacheRoot: URL? = nil, chunkCharacters: Int? = nil) {
        self.chunkCharactersOverride = chunkCharacters
        self.cacheRoot = cacheRoot ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TravelGuides", isDirectory: true)
    }

    /// Whether the on-device model's assets are on this device, without downloading anything.
    /// Same lookup `RTSRAGAppleEmbedding()` makes (English, revision 1).
    nonisolated static var onDeviceAssetsAvailable: Bool {
        NLContextualEmbedding.contextualEmbeddings(
            forValues: [.languages: [NLLanguage.english.rawValue], .revision: 1]
        ).first?.hasAvailableAssets ?? false
    }

    /// Loads the on-device model when its assets are present, so the first run does not pay for
    /// it. When they are absent, asks the system for them once in the background and returns
    /// without waiting. Never touches the network beyond that, and never uses OpenAI.
    /// - Returns: whether the on-device embedder is ready.
    @discardableResult
    func warmUp() async -> Bool {
        await loadOnDevice() != nil
    }

    private func loadOnDevice() async -> RTSRAGAppleEmbedding? {
        if let onDevice { return onDevice }
        guard onDeviceFailure == nil else { return nil }
        guard Self.onDeviceAssetsAvailable else {
            requestAssetsInBackground()
            return nil
        }
        do {
            let candidate = try RTSRAGAppleEmbedding()
            try await withDeadline(
                seconds: Self.prepareTimeout,
                timeoutError: { TravelGuideError.timedOut("on-device model") },
                operation: { try await candidate.prepare() }
            )
            onDevice = candidate
            return candidate
        } catch {
            // A timed-out embedder may still be stuck inside `prepare()`; it is dropped, not reused.
            if case TravelGuideError.timedOut = error {
                onDeviceFailure = "on-device model timed out loading"
            } else {
                onDeviceFailure = "on-device embedding model failed to load (\(Self.shortReason(error)))"
            }
            return nil
        }
    }

    /// The readable part of a load error. The SDK wraps NaturalLanguage's error, so its own
    /// description is "RTSRAGEmbeddingError error 1"; the text holds the real reason in quotes
    /// (`Code=7 "Embedding model requires compilation"`), after an asset path and domain.
    nonisolated static func shortReason(_ error: Error) -> String {
        shortReason("\(error)")
    }

    nonisolated static func shortReason(_ text: String) -> String {
        if let match = text.firstMatch(of: #/Code=-?\d+ "([^"]+)"/#) {
            return String(match.1)
        }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return firstLine.count > 160 ? String(firstLine.prefix(160)) + "…" : firstLine
    }

    /// One fire-and-forget asset request per process, awaited by nothing, so a real device can
    /// acquire the model for later runs. On a simulator without the assets it never completes.
    private func requestAssetsInBackground() {
        guard !assetRequestStarted else { return }
        assetRequestStarted = true
        Task.detached(priority: .background) {
            let model = NLContextualEmbedding.contextualEmbeddings(
                forValues: [.languages: [NLLanguage.english.rawValue], .revision: 1]
            ).first
            _ = try? await model?.requestAssets()
        }
    }

    /// Apple's on-device model when it loads, else OpenAI when a key is given, else throws.
    func selectEmbedder(openAIKey: String?) async throws -> Selection {
        if let apple = await loadOnDevice() {
            return Selection(embedder: apple, cacheKey: "on-device", label: "on-device")
        }
        if let openAIKey, !openAIKey.isEmpty {
            return Selection(
                embedder: RTSRAGOpenAIEmbedding(apiKey: openAIKey, model: Self.openAIModel, governors: governors),
                cacheKey: "openai-\(Self.openAIModel)",
                label: "OpenAI embeddings"
            )
        }
        throw TravelGuideError.embedderUnavailable(onDeviceFailure ?? "on-device embedding model not on this device")
    }

    /// The guide for a destination: reused from Caches when a complete store exists for the
    /// chosen embedder, otherwise fetched, split, embedded and stored.
    /// - Parameter openAIKey: used only when the on-device model is unavailable.
    func guide(for destination: String, openAIKey: String? = nil) async throws -> TravelGuide {
        var timings = Timings()
        defer { lastTimings = timings }

        var clock = Date()
        let selection: Selection
        do {
            selection = try await selectEmbedder(openAIKey: openAIKey)
        } catch TravelGuideError.embedderUnavailable {
            timings.prepare = Date().timeIntervalSince(clock)
            return try await spotlightGuide(for: destination, timings: &timings)
        }
        let embedder = selection.embedder
        timings.prepare = Date().timeIntervalSince(clock)

        let cityDirectory = cityDirectory(for: destination)
        removeLegacyStore(in: cityDirectory)
        let directory = cityDirectory.appendingPathComponent(selection.cacheKey, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("guide.json")

        if let guide = await storedGuide(in: directory, selection: selection) {
            return guide
        }
        if readManifest(Manifest.self, at: manifestURL) != nil {
            // Older format, another embedder, or unreadable: start clean.
            try? FileManager.default.removeItem(at: directory)
        }
        // No manifest: either nothing is stored yet, or an earlier run stopped part way. The
        // ingest below skips sections already stored complete, so a partial store resumes.

        clock = Date()
        let (article, sections, documents) = try await fetchDocuments(for: destination)
        timings.fetch = Date().timeIntervalSince(clock)
        let displayCity = article.title

        clock = Date()
        let store = try RTSRAGFileStore(directory: directory)
        let runtime = RTSRAGRetrievalRuntime(embedder: embedder, store: store)
        let budget = chunkCharactersOverride ?? Self.chunkBudget(for: embedder)
        let stats = try await runtime.ingest(
            loader: InMemoryLoader(source: article.url, documents: documents),
            chunker: RTSRAGSentenceChunker(maxCharacters: budget)
        )
        timings.ingest = Date().timeIntervalSince(clock)
        timings.stats = stats

        guard stats.documentsWithheld == 0,
              stats.documentsCommitted + stats.documentsSkipped > 0
        else {
            throw TravelGuideError.incompleteIngest(
                "\(stats.documentsCommitted) of \(documents.count) sections stored, \(stats.documentsWithheld) withheld"
            )
        }
        // Only a run where every section landed counts as complete; otherwise the next run
        // fetches again and the runtime skips the sections already stored.
        if stats.documentsCommitted + stats.documentsSkipped == documents.count {
            writeManifest(
                Manifest(
                    formatVersion: Self.indexFormatVersion,
                    city: displayCity,
                    articleTitle: article.title,
                    articleURL: article.url,
                    sections: sections.map(\.name),
                    embeddingModel: embedder.modelIdentifier,
                    indexedAt: Date()
                ),
                to: manifestURL
            )
        }

        return TravelGuide(
            city: displayCity,
            articleTitle: article.title,
            articleURL: article.url,
            sections: sections.map(\.name),
            embedderLabel: selection.label,
            fromCache: false,
            retriever: .vector(runtime)
        )
    }

    /// The destination's article and its practical sections, one document per section.
    private func fetchDocuments(
        for destination: String
    ) async throws -> (WikivoyageArticle, [WikivoyageSection], [RTSRAGDocument]) {
        guard let article = try await WikivoyageClient.fetchArticle(for: destination) else {
            throw TravelGuideError.articleNotFound(destination)
        }
        let sections = WikivoyageSections.practicalSections(of: article.extract)
        guard !sections.isEmpty else {
            throw TravelGuideError.noPracticalSections(article.title)
        }
        let displayCity = article.title
        let documents = sections.map { section in
            RTSRAGDocument(
                content: "\(displayCity) › \(section.name): \(section.text)",
                type: .text,
                // Stable per section, so a re-ingest replaces rather than duplicates.
                source: "\(article.url.absoluteString)#\(section.name)",
                metadata: [
                    MetadataKey.section: .string(section.name),
                    MetadataKey.articleURL: .string(article.url.absoluteString),
                    MetadataKey.city: .string(displayCity),
                ]
            )
        }
        return (article, sections, documents)
    }

    // MARK: Spotlight

    /// The guide when no embedder can be used: the same sections, donated to Spotlight with the
    /// SDK's default sentence chunker and searched by keyword. Reused without fetching when the
    /// manifest says every section was donated and Spotlight still holds them.
    private func spotlightGuide(for destination: String, timings: inout Timings) async throws -> TravelGuide {
        let directory = cityDirectory(for: destination)
            .appendingPathComponent(Self.spotlightCacheKey, isDirectory: true)
        if let guide = await storedSpotlightGuide(in: directory) {
            return guide
        }

        var clock = Date()
        let (article, sections, documents) = try await fetchDocuments(for: destination)
        timings.fetch = Date().timeIntervalSince(clock)

        clock = Date()
        let feeder = RTSRAGSpotlightFeeder(namespace: Self.spotlightNamespace("guide"))
        // Every city shares this namespace. The loader's stream states no root, so the SDK would
        // not sweep anyway; off to make that explicit, since a sweep sees only one city's sections.
        let stats = try await Self.donate(documents, source: article.url, to: feeder, sweepsOrphans: false)
        timings.ingest = Date().timeIntervalSince(clock)
        timings.stats = stats
        guard stats.documentsCommitted + stats.documentsSkipped > 0 else {
            throw TravelGuideError.spotlightFailed("none of \(documents.count) sections stored")
        }

        let sectionsBySource = Dictionary(
            zip(documents.compactMap(\.source), sections.map(\.name)),
            uniquingKeysWith: { first, _ in first }
        )
        if stats.documentsCommitted + stats.documentsSkipped == documents.count {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            writeManifest(
                SpotlightManifest(
                    formatVersion: Self.indexFormatVersion,
                    city: article.title,
                    articleTitle: article.title,
                    articleURL: article.url,
                    sections: sections.map(\.name),
                    sectionsBySource: sectionsBySource,
                    indexedAt: Date()
                ),
                to: directory.appendingPathComponent("guide.json")
            )
        }
        return TravelGuide(
            city: article.title,
            articleTitle: article.title,
            articleURL: article.url,
            sections: sections.map(\.name),
            embedderLabel: Self.spotlightLabel,
            fromCache: false,
            retriever: .spotlight(RTSRAGSpotlightSearcher(feeder: feeder), labels: sectionsBySource)
        )
    }

    /// The Spotlight guide in `directory` when its manifest matches this format and Spotlight
    /// still holds every section it lists. One query, not a per-section staleness check.
    private func storedSpotlightGuide(in directory: URL) async -> TravelGuide? {
        guard let manifest = readManifest(SpotlightManifest.self, at: directory.appendingPathComponent("guide.json")),
              manifest.formatVersion == Self.indexFormatVersion
        else { return nil }
        let feeder = RTSRAGSpotlightFeeder(namespace: Self.spotlightNamespace("guide"))
        let root = RTSRAGSourceRoot(path: manifest.articleURL.absoluteString)
        guard let held = try? await feeder.documents(under: root),
              Set(held.values).isSuperset(of: manifest.sectionsBySource.keys)
        else { return nil }
        return TravelGuide(
            city: manifest.city,
            articleTitle: manifest.articleTitle,
            articleURL: manifest.articleURL,
            sections: manifest.sections,
            embedderLabel: Self.spotlightLabel,
            fromCache: true,
            retriever: .spotlight(RTSRAGSpotlightSearcher(feeder: feeder), labels: manifest.sectionsBySource)
        )
    }

    /// Donates `documents` to Spotlight with the SDK's default sentence chunker, as its demo does.
    /// A failed donation does not throw from the SDK but is withheld, so the first withheld reason
    /// is read from the event stream and thrown here, naming Spotlight.
    static func donate(
        _ documents: [RTSRAGDocument],
        source: URL,
        to feeder: RTSRAGSpotlightFeeder,
        sweepsOrphans: Bool
    ) async throws -> RTSRAGIngestionStats {
        let runtime = RTSRAGSpotlightIngestRuntime(feeder: feeder)
        let withheld = FirstReason()
        let subscription = runtime.eventPublisher.sink { event in
            guard case .documentWithheld(_, let reason) = event else { return }
            switch reason {
            case .transient(let text), .unchunkable(let text): withheld.record(text)
            case .unembeddable: withheld.record("not stored")
            }
        }
        defer { subscription.cancel() }

        let stats: RTSRAGIngestionStats
        do {
            stats = try await runtime.ingest(
                loader: InMemoryLoader(source: source, documents: documents),
                chunker: RTSRAGSentenceChunker(),
                sweepsOrphans: sweepsOrphans
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TravelGuideError.spotlightFailed(shortReason(error))
        }
        guard stats.documentsWithheld == 0 else {
            let reason = withheld.first.map { " (\(shortReason($0)))" } ?? ""
            throw TravelGuideError.spotlightFailed(
                "\(stats.documentsWithheld) of \(documents.count) documents not stored\(reason)"
            )
        }
        return stats
    }

    /// Removes a destination's stores, for every embedder, e.g. after an embedder mismatch.
    func discard(destination: String) {
        let city = WikivoyageClient.candidateTitles(for: destination).first ?? destination
        try? FileManager.default.removeItem(at: cacheRoot.appendingPathComponent(Self.slug(city)))
    }

    // MARK: Helpers

    /// On-device: a share of the 256-token ceiling (see ``chunkBudgetFraction``). Embedders
    /// without a ceiling (OpenAI) use the library default.
    static func chunkBudget(for embedder: any RTSRAGEmbedding) -> Int {
        guard let ceiling = embedder.maxInputCharacters else {
            return RTSRAGLimits.defaultMaxChunkCharacters
        }
        return max(64, Int(Double(ceiling) * chunkBudgetFraction))
    }

    /// The guide for a destination when a complete store for the chosen embedder is already in
    /// Caches; `nil` otherwise. Never fetches or embeds, so Siri does not wait for a download.
    func cachedGuide(for destination: String, openAIKey: String? = nil) async throws -> TravelGuide? {
        let selection: Selection
        do {
            selection = try await selectEmbedder(openAIKey: openAIKey)
        } catch TravelGuideError.embedderUnavailable {
            return await storedSpotlightGuide(
                in: cityDirectory(for: destination).appendingPathComponent(Self.spotlightCacheKey, isDirectory: true)
            )
        }
        let directory = cityDirectory(for: destination)
            .appendingPathComponent(selection.cacheKey, isDirectory: true)
        return await storedGuide(in: directory, selection: selection)
    }

    private func cityDirectory(for destination: String) -> URL {
        let city = WikivoyageClient.candidateTitles(for: destination).first ?? destination
        return cacheRoot.appendingPathComponent(Self.slug(city), isDirectory: true)
    }

    /// The store in `directory` when its manifest matches this format and embedder and it holds
    /// entries.
    private func storedGuide(in directory: URL, selection: Selection) async -> TravelGuide? {
        guard let manifest = readManifest(Manifest.self, at: directory.appendingPathComponent("guide.json")),
              manifest.formatVersion == Self.indexFormatVersion,
              manifest.embeddingModel == selection.embedder.modelIdentifier,
              let store = try? RTSRAGFileStore(directory: directory),
              (try? await store.count(matching: [:])) ?? 0 > 0
        else { return nil }
        return TravelGuide(
            city: manifest.city,
            articleTitle: manifest.articleTitle,
            articleURL: manifest.articleURL,
            sections: manifest.sections,
            embedderLabel: selection.label,
            fromCache: true,
            retriever: .vector(RTSRAGRetrievalRuntime(embedder: selection.embedder, store: store))
        )
    }

    /// Format 2 kept one store directly under the city directory. Stores now live one level
    /// down, per embedder, so a store file left at the city level is from the old layout.
    private func removeLegacyStore(in cityDirectory: URL) {
        let manager = FileManager.default
        for name in ["guide.json", "entries.jsonl"] {
            let url = cityDirectory.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) {
                try? manager.removeItem(at: url)
            }
        }
    }

    /// "São Paulo" → "sao-paulo"
    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        let parts = folded.lowercased().split { !($0.isLetter || $0.isNumber) }
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "guide" : slug
    }

    private func readManifest<M: Decodable>(_ type: M.Type, at url: URL) -> M? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func writeManifest<M: Encodable>(_ manifest: M, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(manifest).write(to: url, options: .atomic)
    }
}

/// The first reason recorded, from any thread.
private final class FirstReason: Sendable {
    private let state = Mutex<String?>(nil)

    func record(_ reason: String) {
        state.withLock { if $0 == nil { $0 = reason } }
    }

    var first: String? { state.withLock { $0 } }
}
