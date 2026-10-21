//
//  SpotlightIndex.swift
//  TripBriefing
//
//  Puts the latest trip's notes in Spotlight, as plain keyword search: a search for "Tile
//  Museum" finds the day plan. Tapping a result opens the note in the app (see
//  TripBriefingRootView). The agents are not involved; this reuses the text the app already has.
//

import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// The trip note a Spotlight result opens.
struct SpotlightNote: Identifiable {
    let note: TripNote
    let destination: String

    var id: String { SpotlightIndex.tripNoteID(note) }
}

enum SpotlightIndex {
    private static let tripDomain = "trip-notes"
    private static let tripPrefix = "trip-note|"
    /// Bump when the items' shape changes, so the launch sync indexes everything again.
    private static let formatVersion = 1
    /// The trip's signature when it was indexed, so the launch sync only fills gaps.
    private static let tripStateKey = "spotlight.v\(formatVersion).trip"

    static func tripNoteID(_ note: TripNote) -> String { tripPrefix + note.part }

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

    // MARK: Launch

    @MainActor private static var didSync = false

    /// Indexes the trip on disk when Spotlight does not have it yet: a trip planned before this
    /// feature, or before a format change. Once per launch, however many windows call it.
    @MainActor
    static func syncAtLaunch() {
        guard !didSync else { return }
        didSync = true
        if let archive = TripNotesArchive.load(),
           UserDefaults.standard.string(forKey: tripStateKey) != signature(of: archive) {
            indexTrip(archive)
        }
    }

    // MARK: Opening a result

    /// The note a tapped result's identifier points at, or `nil` when it is gone (a newer trip).
    @MainActor
    static func note(for identifier: String) -> SpotlightNote? {
        guard identifier.hasPrefix(tripPrefix) else { return nil }
        let part = String(identifier.dropFirst(tripPrefix.count))
        guard let archive = TripNotesArchive.load(),
              let note = archive.notes.first(where: { $0.part == part })
        else { return nil }
        return SpotlightNote(note: note, destination: archive.destination)
    }
}
