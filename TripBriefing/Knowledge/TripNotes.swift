//
//  TripNotes.swift
//  TripBriefing
//
//  Retrieval over the briefing itself: once a run finishes, its weather report,
//  itinerary, day plans, packing list, tips and phrasebook are embedded with the
//  same embedder as the travel guide, so the Trip Assistant can search them. With
//  no embedder, they go to Spotlight and are searched by keyword, like the guide.
//
//  The briefing is short, but the on-device model's context is small (4,096
//  tokens on iOS 26, 8,192 on iOS 27), and the briefing plus guide passages do
//  not reliably fit in one prompt. Searching keeps each question's prompt to the
//  few passages that answer it.
//

import Foundation
import Synchronization
import RailtracksSwift
import RailtracksSwiftRAG

/// One part of a finished briefing, as plain text.
struct TripNote: Codable, Sendable, Hashable {
    /// Short label for citations, e.g. "Weather" or "Plan · 2026-10-15".
    let part: String
    let text: String
}

/// A retrieved passage of the briefing.
struct TripNoteHit: Sendable, Hashable {
    let content: String
    let part: String
    let score: Double

    /// `Your briefing › Weather`
    var sourceLabel: String { "Your briefing › \(part)" }
}

/// One briefing's notes, indexed and ready to search.
struct TripNotes: Sendable {
    let destination: String
    /// "on-device", "OpenAI embeddings" or "Spotlight".
    let embedderLabel: String
    let noteCount: Int
    /// The notes as indexed, for the exact day match in `search`.
    let notes: [TripNote]
    let retriever: PassageRetriever

    /// True when the notes are in Spotlight, which matches words rather than meaning.
    var isKeywordSearch: Bool { retriever.isKeywordSearch }

    /// Vector search, with any day or part the query names put first. The on-device embeddings
    /// barely tell "day 2" from "day 4", so "What is the plan for day 2?" would otherwise return
    /// the other days' plans; a plain text match on the day fixes that. They do not route
    /// "weather" to the Weather note either (it ranked a Phrasebook chunk first), so a few
    /// keywords name a part directly.
    ///
    /// A query that names no day also gets the Itinerary note, in the last slot. Such a question
    /// is often about the whole trip ("Which cities do we visit?"), and its answer is spread over
    /// every day plan, past what the few best matches cover: "cities to visit" ranked the
    /// practical tips, which name the airports, above the day that goes to Whistler.
    ///
    /// Returns at most `topK` hits, most important first: `RTSKnowledgeSearchTool` keeps only the
    /// first `topK` of what a source returns, so anything past that never reaches the model.
    func search(_ query: String, topK: Int) async throws -> [TripNoteHit] {
        let wanted = Self.namedDays(in: query, dayCount: planDayCount)
        let topics = Self.namedParts(in: query)
        let plans = notes.filter { note in
            wanted.contains { token in
                // "-16" is a date's day of month: match the end, not the month in every date.
                token.hasPrefix("-") ? note.part.hasSuffix(token) : note.part.contains(token)
            }
        }
        // The weather note covers every day, so a named day brings it along, after the plans:
        // with two named days and two slots, "day 2 and day 3" needs both plans more. A weather
        // question ("Will it rain on day 2?") names Weather as a topic, which puts it first.
        let alongside = wanted.isEmpty || topics.contains("Weather") ? [] : ["Weather"]
        let order = topics + plans.map(\.part) + alongside
        let named = order
            .compactMap { part in notes.first { $0.part == part } }
            .map { TripNoteHit(content: "\(destination) trip › \($0.part): \($0.text)", part: $0.part, score: 1) }
        // Every note starts with "<destination> trip", so a keyword search leaves those words out.
        let passages = try await retriever.retrieve(
            query, topK: topK, labelKey: TripNotes.partKey, ignoring: PassageRetriever.words(of: destination)
        )
        let namedSet = Set(order)
        let vector = passages
            .map { TripNoteHit(content: $0.content, part: $0.label ?? "Briefing", score: $0.score) }
            .filter { !namedSet.contains($0.part) }
        var hits = Array(named.prefix(topK))
        let room = topK - hits.count
        // The Itinerary takes the last free slot, after the named parts and the best vector
        // matches: "What should I pack?" still gets the packing list first.
        if wanted.isEmpty, room > 0, !namedSet.contains(Self.itineraryPart),
           !vector.prefix(room).contains(where: { $0.part == Self.itineraryPart }),
           let itinerary = notes.first(where: { $0.part == Self.itineraryPart }) {
            hits += vector.prefix(room - 1)
            hits.append(TripNoteHit(
                content: "\(destination) trip › \(itinerary.part): \(itinerary.text)",
                part: itinerary.part,
                score: 1
            ))
        } else {
            hits += vector.prefix(max(room, 0))
        }
        return hits
    }

    /// The parts a query names by topic, in note order. Whole words, so "say" does not match
    /// "essay" and "rain" does not match "train".
    static func namedParts(in query: String) -> [String] {
        let words = Set(query.lowercased().split { !$0.isLetter }.map(String.init))
        return partKeywords.filter { !words.isDisjoint(with: $0.words) }.map(\.part)
    }

    /// Part names as `notes(request:...)` writes them.
    private static let partKeywords: [(part: String, words: Set<String>)] = [
        ("Weather", ["weather", "forecast", "rain", "rainy", "raining", "temperature", "temperatures", "cold", "warm"]),
        ("Packing list", ["pack", "packing", "bring", "wear", "clothes"]),
        ("Practical tips", ["tip", "tips", "transport", "airport", "money"]),
        ("Phrasebook", ["phrase", "phrases", "say", "speak", "language"]),
    ]

    /// The note that lists every day's plan in one passage.
    static let itineraryPart = "Itinerary"

    /// How many day-plan notes there are, which is what "the last day" refers to.
    private var planDayCount: Int { notes.filter { $0.part.hasPrefix("Plan · Day ") }.count }

    /// What a query names, as text to find in a note's part: "Day 2" for "day 2", "the second
    /// day" or "day two"; the last day for "last day"; "-16" for "the 16th" or "on 16".
    static func namedDays(in query: String, dayCount: Int) -> [String] {
        let text = query.lowercased()
        var days: [String] = []
        let words = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
        let numbers = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        for (index, word) in words.enumerated() where text.contains("\(word) day") {
            days.append("Day \(index + 1) ")
        }
        for (index, word) in numbers.enumerated() where text.contains("day \(word)") {
            days.append("Day \(index + 1) ")
        }
        // "the 2nd day" is a trip day, not the 2nd of the month: checked before the date below.
        if let match = text.firstMatch(of: #/\b(\d{1,2})(st|nd|rd|th)\s+day\b/#), let number = Int(match.1) {
            days.append("Day \(number) ")
            return days
        }
        // Every match, not the first: "day 2 and day 3" names both.
        for match in text.matches(of: #/day\s*(\d{1,2})\b/#) {
            if let number = Int(match.1) { days.append("Day \(number) ") }
        }
        if text.contains("last day"), dayCount > 0 {
            days.append("Day \(dayCount) ")
        }
        if let match = text.firstMatch(of: #/\b(\d{1,2})(st|nd|rd|th)\b/#), let number = Int(match.1) {
            days.append(String(format: "-%02d", number))
        }
        return days
    }

    static let partKey = "part"
}

extension TripNotes {
    /// The notes for a finished briefing: trip details, overview, weather, itinerary, one note
    /// per day plan, packing list, tips and phrasebook. Empty parts are left out.
    static func notes(
        request: TripRequest,
        report: TripBriefingReport?,
        phraseBook: PhraseBook?,
        weather: String,
        itinerary: String
    ) -> [TripNote] {
        let dates = DateFormatter.tripNoteDay
        var notes = [
            TripNote(part: "Trip details", text: """
            Destination: \(request.destination). Dates: \(dates.string(from: request.startDate)) to \
            \(dates.string(from: request.endDate)). The traveler speaks \(request.homeLanguage). \
            Traveler notes: \(request.notes.isEmpty ? "none" : request.notes)
            """),
            TripNote(part: "Weather", text: weather),
            TripNote(part: TripNotes.itineraryPart, text: itinerary),
        ]
        if let report {
            notes.append(TripNote(part: "Overview", text: "\(report.headline). \(report.weatherSummary)"))
            // "Day 2" in both the label and the text: travelers ask by day number, and a note
            // labelled by date alone does not come up for "the plan for day 2".
            for (index, day) in report.days.enumerated() {
                notes.append(TripNote(
                    part: "Plan · Day \(index + 1) · \(day.day)",
                    text: "Day \(index + 1) (\(day.day)). Morning: \(day.morning) Afternoon: \(day.afternoon) Evening: \(day.evening)"
                ))
            }
            notes.append(TripNote(part: "Packing list", text: report.packingList.joined(separator: "\n")))
            notes.append(TripNote(part: "Practical tips", text: report.tips.joined(separator: "\n")))
        }
        if let phraseBook {
            let phrases = phraseBook.phrases.map { phrase in
                "\(phrase.phrase) (\(phrase.pronunciation)): \(phrase.meaning). Use it \(phrase.whenToUse)."
            }
            notes.append(TripNote(
                part: "Phrasebook",
                text: "Language: \(phraseBook.language). Greeting: \(phraseBook.greeting).\n" + phrases.joined(separator: "\n")
            ))
        }
        return notes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private extension DateFormatter {
    static let tripNoteDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension TravelGuideLibrary {

    /// Embeds a finished briefing's notes with the same embedder choice as the guide, into a
    /// store under `Caches/TripNotes`. Only the latest briefing is kept: each call replaces the
    /// previous store.
    /// - Parameter openAIKey: used only when the on-device model is unavailable.
    func tripNotes(_ notes: [TripNote], destination: String, openAIKey: String?) async throws -> TripNotes {
        let selection: Selection
        do {
            selection = try await selectEmbedder(openAIKey: openAIKey)
        } catch TravelGuideError.embedderUnavailable {
            return try await spotlightTripNotes(notes, destination: destination)
        }
        let root = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TripNotes", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let directory = root
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(selection.cacheKey, isDirectory: true)

        let source = URL(string: "trip-notes://\(Self.slug(destination))")!
        let documents = Self.noteDocuments(notes, destination: destination, source: source)

        let store = try RTSRAGFileStore(directory: directory)
        let runtime = RTSRAGRetrievalRuntime(embedder: selection.embedder, store: store)
        let stats = try await runtime.ingest(
            loader: InMemoryLoader(source: source, documents: documents),
            chunker: RTSRAGSentenceChunker(maxCharacters: Self.chunkBudget(for: selection.embedder))
        )
        guard stats.documentsWithheld == 0, stats.documentsCommitted > 0 else {
            throw TravelGuideError.incompleteIngest(
                "\(stats.documentsCommitted) of \(documents.count) notes stored, \(stats.documentsWithheld) withheld"
            )
        }
        return TripNotes(
            destination: destination,
            embedderLabel: selection.label,
            noteCount: documents.count,
            notes: notes,
            retriever: .vector(runtime)
        )
    }

    /// The notes when no embedder can be used, donated to Spotlight for keyword search. Only the
    /// latest briefing is kept: each call clears the namespace first.
    ///
    /// Each call donates under a fresh source. Spotlight only queues the delete, and the ingest
    /// skips a document it already holds at the same content, so under the old source the same
    /// notes could be skipped, then deleted, leaving nothing.
    private func spotlightTripNotes(_ notes: [TripNote], destination: String) async throws -> TripNotes {
        let feeder = RTSRAGSpotlightFeeder(namespace: Self.spotlightNamespace("tripnotes"))
        do {
            try await feeder.deleteAll()
        } catch {
            throw TravelGuideError.spotlightFailed(Self.shortReason(error))
        }
        let source = URL(string: "trip-notes://\(UUID().uuidString)/\(Self.slug(destination))")!
        let documents = Self.noteDocuments(notes, destination: destination, source: source)
        let stats = try await Self.donate(documents, source: source, to: feeder, sweepsOrphans: false)
        guard stats.documentsCommitted > 0 else {
            throw TravelGuideError.spotlightFailed("none of \(documents.count) notes stored")
        }
        let partsBySource = Dictionary(
            zip(documents.compactMap(\.source), notes.map(\.part)),
            uniquingKeysWith: { first, _ in first }
        )
        return TripNotes(
            destination: destination,
            embedderLabel: Self.spotlightLabel,
            noteCount: documents.count,
            notes: notes,
            retriever: .spotlight(RTSRAGSpotlightSearcher(feeder: feeder), labels: partsBySource)
        )
    }

    /// One document per note, under `source#<part>`.
    private static func noteDocuments(_ notes: [TripNote], destination: String, source: URL) -> [RTSRAGDocument] {
        notes.map { note in
            RTSRAGDocument(
                content: "\(destination) trip › \(note.part): \(note.text)",
                type: .text,
                source: "\(source.absoluteString)#\(slug(note.part))",
                metadata: [TripNotes.partKey: .string(note.part)]
            )
        }
    }
}

// MARK: - Last trip on disk

/// The latest briefing's notes, saved when they are indexed, so Siri and Spotlight can reach them
/// after the app restarts. The vector store lives in Caches and can be purged, so only the notes
/// are kept: `TravelGuideLibrary.tripNotes` embeds them again, which takes about a second.
struct TripNotesArchive: Codable, Sendable {
    let destination: String
    /// "Day 1 = 2026-10-14", one per day of the trip.
    let tripDays: [String]
    let notes: [TripNote]
    /// The Local Guide's plan, for Get Trip Activities. Nil in trips saved before it was kept,
    /// and when the itinerary did not decode.
    var itinerary: Itinerary?

    static var fileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TripNotes/last-trip.json")
    }

    static func load() -> TripNotesArchive? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(TripNotesArchive.self, from: data)
    }

    func save() {
        do {
            let url = Self.fileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        } catch {
            AppLog.warning("Trip notes not saved", properties: ["Reason": error.localizedDescription])
        }
    }
}

// MARK: - Tool

/// Thread-safe record of the source labels a question's searches returned, in first-seen order.
final class TripAnswerSourceCollector: Sendable {
    private let state = Mutex<[String]>([])

    func record(_ labels: [String]) {
        state.withLock { $0.append(contentsOf: labels) }
    }

    /// Deduplicated, first-seen order.
    var sourceLabels: [String] {
        var seen = Set<String>()
        return state.withLock { $0 }.filter { seen.insert($0).inserted }
    }

    func reset() {
        state.withLock { $0.removeAll() }
    }
}

enum TripNotesTool {
    static let name = "SearchTrip"

    /// - Parameter maxSearches: searches the tool answers before it throws `SearchLimitReached`;
    ///   `nil` for no limit.
    static func make(notes: TripNotes, collector: TripAnswerSourceCollector, maxSearches: Int? = nil) -> RTSKnowledgeSearchTool {
        let searches = SearchCounter()
        return RTSKnowledgeSearchTool(
            toolName: name,
            toolDescription: """
            Searches the traveler's own \(notes.destination) briefing: the trip dates and notes, the \
            daily weather forecast, the itinerary and day-by-day plan, the packing list, the practical \
            tips and the phrasebook. Returns passages with the part of the briefing they came from. \
            An empty result means the briefing does not cover it.
            """ + (notes.isKeywordSearch ? " " + PassageRetriever.keywordSearchHint : ""),
            source: RTSClosureKnowledgeSource { query in
                if let maxSearches, searches.next() > maxSearches {
                    throw SearchLimitReached(toolName: name)
                }
                let found = try await notes.search(query.text, topK: query.topK)
                collector.record(found.map(\.sourceLabel))
                return found.map { hit in
                    RTSKnowledgeHit(
                        content: hit.content,
                        source: hit.sourceLabel,
                        score: hit.score,
                        metadata: [TripNotes.partKey: .string(hit.part)]
                    )
                }
            },
            // At least 2, so the best match and the Itinerary `search` adds both fit.
            resultCountRange: 2...4
        )
    }
}
