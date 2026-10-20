//
//  ShowcaseRootView.swift
//  TripBriefing
//
//  The picker on first launch, then the chosen showcase's tabs. Settings in
//  either showcase can switch to the other one.
//

import SwiftUI

struct ShowcaseRootView: View {
    @Environment(ShowcaseSelection.self) private var showcase
    @Environment(ProviderSettings.self) private var settings
    @Environment(ManualLibrary.self) private var library
    @State private var tab: ShowcaseTab = .primary

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
    }
}
