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
#if os(macOS)
import AppKit
#endif

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
    /// Set once the manual pages this app indexed while it also held Pocket Manuals are gone.
    private static let manualPagesClearedKey = "spotlight.manualPagesCleared"
    /// Pocket Manuals put each manual's pages under `manual.<id>`. Domains nest on ".", so
    /// deleting "manual" removes every manual.
    private static let legacyManualDomain = "manual"

    /// Indexes the trip on disk when Spotlight does not have it yet: a trip planned before this
    /// feature, or before a format change. Once per launch, however many windows call it.
    @MainActor
    static func syncAtLaunch() {
        guard !didSync else { return }
        didSync = true
        let archive = TripNotesArchive.load()
        guard UserDefaults.standard.bool(forKey: manualPagesClearedKey) else {
            // Until Pocket Manuals became its own app, this app also put manual pages in
            // Spotlight, and tapping one now opens nothing. Clear those and the trip's items once,
            // then index the trip again. Only these domains: the travel guide and trip notes
            // the RAG fallback donates live under the bundle id and must stay.
            Task {
                do {
                    try await CSSearchableIndex.default()
                        .deleteSearchableItems(withDomainIdentifiers: [legacyManualDomain, tripDomain])
                    UserDefaults.standard.set(true, forKey: manualPagesClearedKey)
                    AppLog.info("Old Spotlight items removed")
                } catch {
                    AppLog.warning("Old Spotlight items not removed", properties: ["Reason": error.localizedDescription])
                }
                if let archive { indexTrip(archive) }
            }
            return
        }
        if let archive, UserDefaults.standard.string(forKey: tripStateKey) != signature(of: archive) {
            indexTrip(archive)
        }
    }

    // MARK: Opening a result

    #if os(macOS)
    /// The tapped result's identifier, set by `SpotlightAppDelegate` and read by the root view.
    @MainActor static let requests = SpotlightRequests()
    #endif

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

#if os(macOS)
/// The latest tapped result that the window has not opened yet.
@MainActor @Observable
final class SpotlightRequests {
    var identifier: String?
}

/// On macOS, Spotlight hands a tapped result to the app delegate, and SwiftUI's
/// `onContinueUserActivity` never sees it. This passes the identifier on to the root view, also
/// when the click launched the app.
final class SpotlightAppDelegate: NSObject, NSApplicationDelegate {
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return false }
        AppLog.info("Spotlight result opened", properties: ["Item": identifier])
        MainActor.assumeIsolated { SpotlightIndex.requests.identifier = identifier }
        return true
    }
}
#endif
