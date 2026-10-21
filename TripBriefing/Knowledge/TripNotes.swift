//
//  TripNotes.swift
//  TripBriefing
//
//  Retrieval over the briefing itself: once a run finishes, its weather report,
//  itinerary, day plans, packing list, tips and phrasebook are embedded with the
//  same embedder as the travel guide, so the Trip Assistant can search them.
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
    /// "on-device" or "OpenAI embeddings".
    let embedderLabel: String
    let noteCount: Int
    /// The notes as indexed, for the exact day match in `search`.
    let notes: [TripNote]
    let runtime: RTSRAGRetrievalRuntime

    /// Vector search, with any day the query names put first. The on-device embeddings barely
    /// tell "day 2" from "day 4", so "What is the plan for day 2?" would otherwise return the
    /// other days' plans; a plain text match on the day fixes that.
    func search(_ query: String, topK: Int) async throws -> [TripNoteHit] {
        let wanted = Self.namedDays(in: query, dayCount: planDayCount)
        let named = notes
            .filter { note in
                // The weather note covers every day, so a named day brings it along: "Will it
                // rain on the 16th?" needs it more than that day's plan.
                if !wanted.isEmpty, note.part == "Weather" { return true }
                return wanted.contains { token in
                    // "-16" is a date's day of month: match the end, not the month in every date.
                    token.hasPrefix("-") ? note.part.hasSuffix(token) : note.part.contains(token)
                }
            }
            .map { TripNoteHit(content: "\(destination) trip › \($0.part): \($0.text)", part: $0.part, score: 1) }
        let result = try await runtime.retrieve(query, topK: topK)
        let vector = result.entries.map { hit in
            var part = "Briefing"
            if case .string(let name)? = hit.entry.metadata[TripNotes.partKey] {
                part = name
            }
            return TripNoteHit(content: hit.entry.content, part: part, score: Double(hit.score))
        }
        let namedParts = Set(named.map(\.part))
        return Array((named + vector.filter { !namedParts.contains($0.part) }).prefix(max(topK, named.count)))
    }

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
        if let match = text.firstMatch(of: #/day\s*(\d{1,2})\b/#), let number = Int(match.1) {
            days.append("Day \(number) ")
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
            TripNote(part: "Itinerary", text: itinerary),
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
        let selection = try await selectEmbedder(openAIKey: openAIKey)
        let root = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TripNotes", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let directory = root
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(selection.cacheKey, isDirectory: true)

        let source = URL(string: "trip-notes://\(Self.slug(destination))")!
        let documents = notes.map { note in
            RTSRAGDocument(
                content: "\(destination) trip › \(note.part): \(note.text)",
                type: .text,
                source: "\(source.absoluteString)#\(Self.slug(note.part))",
                metadata: [TripNotes.partKey: .string(note.part)]
            )
        }

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
            runtime: runtime
        )
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

    static func make(notes: TripNotes, collector: TripAnswerSourceCollector) -> RTSKnowledgeSearchTool {
        RTSKnowledgeSearchTool(
            toolName: name,
            toolDescription: """
            Searches the traveler's own \(notes.destination) briefing: the trip dates and notes, the \
            daily weather forecast, the itinerary and day-by-day plan, the packing list, the practical \
            tips and the phrasebook. Returns passages with the part of the briefing they came from. \
            An empty result means the briefing does not cover it.
            """,
            source: RTSClosureKnowledgeSource { query in
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
            resultCountRange: 1...4
        )
    }
}
