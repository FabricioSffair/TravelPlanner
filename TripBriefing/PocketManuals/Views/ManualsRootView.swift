//
//  ManualsRootView.swift
//  PocketManuals
//
//  Pocket Manuals' tabs. The library, its index and the Ask view model are
//  created once in the App struct, so a question, its answer and any indexing
//  in progress survive switching showcases.
//

import SwiftUI

struct ManualsRootView: View {
    @Environment(ManualLibrary.self) private var library
    @Environment(AskViewModel.self) private var ask

    @Binding var tab: ShowcaseTab

    var body: some View {
        TabView(selection: $tab) {
            Tab("Library", systemImage: "books.vertical", value: ShowcaseTab.primary) {
                LibraryView()
            }
            Tab("Ask", systemImage: "questionmark.bubble", value: ShowcaseTab.secondary) {
                AskView(model: ask)
            }
            Tab("Settings", systemImage: "gearshape", value: ShowcaseTab.settings) {
                SettingsView()
            }
        }
        .onAppear {
            // Travel Assistant's Chat tab has no counterpart here.
            if tab == .chat { tab = .primary }
        }
        .task {
            // Loads the on-device model if its assets are present; no download, no network.
            await library.refreshEmbedderStatus()
        }
    }
}
