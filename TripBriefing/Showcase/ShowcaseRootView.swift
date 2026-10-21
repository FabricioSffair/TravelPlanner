//
//  ShowcaseRootView.swift
//  TripBriefing
//
//  The picker on first launch, then the chosen showcase's tabs. Settings in
//  either showcase can switch to the other one.
//

import CoreSpotlight
import SwiftUI

struct ShowcaseRootView: View {
    @Environment(ShowcaseSelection.self) private var showcase
    @Environment(ProviderSettings.self) private var settings
    @Environment(ManualLibrary.self) private var library
    @State private var tab: ShowcaseTab = .primary
    /// The trip note or manual page a tapped Spotlight result opens.
    @State private var spotlightRoute: SpotlightRoute?

    var body: some View {
        Group {
            #if os(macOS)
            // Both showcases live in one sidebar, so there is no first-launch picker.
            MacRootView(tab: $tab)
            #else
            switch showcase.selected {
            case nil:
                ShowcasePickerView()
            case .tripBriefing:
                TripBriefingRootView(tab: $tab)
            case .pocketManuals:
                ManualsRootView(tab: $tab)
            }
            #endif
        }
        // Here rather than in Pocket Manuals' views: the key and the cloud-embeddings switch can
        // change while Travel Assistant is showing, and the index's embedding fallback must still see it.
        .onChange(of: settings.embeddingOpenAIKey) { _, key in
            Task { await library.updateOpenAIKey(key) }
        }
        .task { SpotlightIndex.syncAtLaunch(documents: library.documents) }
        .onContinueUserActivity(CSSearchableItemActionType, perform: openSpotlightResult)
        .sheet(item: $spotlightRoute) { route in
            switch route {
            case .tripNote(let note, let destination):
                TripNoteSheet(note: note, destination: destination)
            case .manualPage(let page):
                ManualPageViewer(reference: page)
            }
        }
    }

    /// Switches to the result's showcase and opens the note or page over it.
    private func openSpotlightResult(_ activity: NSUserActivity) {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let route = SpotlightIndex.route(for: identifier, documents: library.documents)
        else { return }
        switch route {
        case .tripNote: showcase.selected = .tripBriefing
        case .manualPage: showcase.selected = .pocketManuals
        }
        spotlightRoute = route
    }
}
