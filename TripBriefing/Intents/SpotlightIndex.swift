//
//  SpotlightIndex.swift
//  TripBriefing
//
//  Puts the latest trip's notes and every page of each indexed manual in Spotlight, as plain
//  keyword search: a search for "Tile Museum" finds the day plan, "radon test kit" the page.
//  Tapping a result opens it in the app (see ShowcaseRootView). The agents are not involved;
//  this reuses the text the app already has.
//

import CoreSpotlight
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// What a Spotlight result opens.
enum SpotlightRoute: Identifiable {
    case tripNote(TripNote, destination: String)
    case manualPage(PageReference)

    var id: String {
        switch self {
        case .tripNote(let note, _): SpotlightIndex.tripNoteID(note)
        case .manualPage(let page): SpotlightIndex.manualPageID(docID: page.docID, page: page.page)
        }
    }
}

enum SpotlightIndex {
    private static let tripDomain = "trip-notes"
    private static let tripPrefix = "trip-note|"
    private static let manualPrefix = "manual-page|"
    /// Bump when the items' shape changes, so the launch sync indexes everything again.
    private static let formatVersion = 1
    /// What was indexed, so the launch sync only fills gaps: the trip's signature, and one key
    /// per manual.
    private static let tripStateKey = "spotlight.v\(formatVersion).trip"
    private static func manualStateKey(_ id: String) -> String { "spotlight.v\(formatVersion).manual.\(id)" }

    static func tripNoteID(_ note: TripNote) -> String { tripPrefix + note.part }
    static func manualPageID(docID: String, page: Int) -> String {
        manualPrefix + ManualCitation.key(manualID: docID, page: page)
    }
    private static func manualDomain(_ id: String) -> String { "manual.\(id)" }

    // MARK: Trip

    /// Replaces the previous trip's notes with these.
    static func indexTrip(_ archive: TripNotesArchive) {
        Task.detached(priority: .utility) {
            let items = archive.notes.map { note in
                let attributes = CSSearchableItemAttributeSet(contentType: .text)
                attributes.title = "\(archive.destination) trip · \(note.part)"
                attributes.contentDescription = String(note.text.prefix(300))
                attributes.textContent = note.text
                attributes.keywords = [archive.destination, "trip", "travel"]
                return CSSearchableItem(
                    uniqueIdentifier: tripNoteID(note),
                    domainIdentifier: tripDomain,
                    attributeSet: attributes
                )
            }
            do {
                let index = CSSearchableIndex.default()
                try await index.deleteSearchableItems(withDomainIdentifiers: [tripDomain])
                try await index.indexSearchableItems(items)
                UserDefaults.standard.set(signature(of: archive), forKey: tripStateKey)
                AppLog.info("Trip added to Spotlight", properties: ["Notes": "\(items.count)"])
            } catch {
                AppLog.warning("Trip not added to Spotlight", properties: ["Reason": error.localizedDescription])
            }
        }
    }

    private static func signature(of archive: TripNotesArchive) -> String {
        "\(archive.destination)|\(archive.tripDays.joined(separator: ","))|\(archive.notes.count)"
    }

    // MARK: Manuals

    /// One item per page with text. Replaces the manual's earlier items.
    @MainActor
    static func indexManual(id: String, title: String) {
        let fileURL = ManualLibrary.fileURL(for: id)
        Task.detached(priority: .utility) {
            guard let document = PDFDocument(url: fileURL) else { return }
            let shortTitle = PageReference.shortTitle(title)
            let items = (0..<document.pageCount).compactMap { index -> CSSearchableItem? in
                guard let text = document.page(at: index)?.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty
                else { return nil }
                let attributes = CSSearchableItemAttributeSet(contentType: .pdf)
                attributes.title = "\(shortTitle), p. \(index + 1)"
                attributes.contentDescription = String(text.prefix(300))
                attributes.textContent = text
                attributes.keywords = [shortTitle, "manual"]
                return CSSearchableItem(
                    uniqueIdentifier: manualPageID(docID: id, page: index + 1),
                    domainIdentifier: manualDomain(id),
                    attributeSet: attributes
                )
            }
            do {
                let index = CSSearchableIndex.default()
                try await index.deleteSearchableItems(withDomainIdentifiers: [manualDomain(id)])
                try await index.indexSearchableItems(items)
                UserDefaults.standard.set(true, forKey: manualStateKey(id))
                AppLog.info("Manual added to Spotlight", properties: ["Pages": "\(items.count)"])
            } catch {
                AppLog.warning("Manual not added to Spotlight", properties: ["Reason": error.localizedDescription])
            }
        }
    }

    static func removeManual(id: String) {
        UserDefaults.standard.removeObject(forKey: manualStateKey(id))
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [manualDomain(id)])
    }

    // MARK: Launch

    @MainActor private static var didSync = false

    /// Indexes what is on disk but not in Spotlight yet: a trip or manuals indexed before this
    /// feature, or before a format change. Once per launch, however many windows call it.
    @MainActor
    static func syncAtLaunch(documents: [ManualDocument]) {
        guard !didSync else { return }
        didSync = true
        if let archive = TripNotesArchive.load(),
           UserDefaults.standard.string(forKey: tripStateKey) != signature(of: archive) {
            indexTrip(archive)
        }
        for document in documents where !UserDefaults.standard.bool(forKey: manualStateKey(document.id)) {
            if case .indexed = document.indexState {
                indexManual(id: document.id, title: document.title)
            }
        }
    }

    // MARK: Opening a result

    /// What a tapped result's identifier points at, or `nil` when it is gone (a newer trip, a
    /// deleted manual).
    @MainActor
    static func route(for identifier: String, documents: [ManualDocument]) -> SpotlightRoute? {
        if identifier.hasPrefix(tripPrefix) {
            let part = String(identifier.dropFirst(tripPrefix.count))
            guard let archive = TripNotesArchive.load(),
                  let note = archive.notes.first(where: { $0.part == part })
            else { return nil }
            return .tripNote(note, destination: archive.destination)
        }
        if identifier.hasPrefix(manualPrefix) {
            let key = identifier.dropFirst(manualPrefix.count)
            guard let marker = key.range(of: "#page-", options: .backwards),
                  let page = Int(key[marker.upperBound...]),
                  let document = documents.first(where: { $0.id == String(key[..<marker.lowerBound]) })
            else { return nil }
            return .manualPage(PageReference(docID: document.id, page: page, title: document.title))
        }
        return nil
    }
}
