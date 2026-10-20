//
//  TripBriefingApp.swift
//  TripBriefing
//
//  Railtracks Showcase: two RailtracksSwift demos in one app, picked at the
//  root and switchable in Settings, sharing one provider choice and one set
//  of keys.
//
//  - Travel Assistant (Trip Briefing in code): one orchestrator node fans out three agents in parallel
//    (weather, itinerary, phrasebook), then a concierge agent composes the
//    briefing using a packing-list agent exposed as a tool.
//  - Pocket Manuals: PDF manuals indexed page by page; answers cite the page
//    and are checked by a verifier.
//
//  Every long-lived object is created here once, so switching showcases keeps
//  runs, answers and indexing in progress.
//

import SwiftUI
import Logging
import RailtracksSwift
import RailtownLogger

@main
struct TripBriefingApp: App {
    @State private var showcase: ShowcaseSelection
    @State private var settings: ProviderSettings
    // Travel Assistant
    @State private var planner: TripPlannerViewModel
    @State private var translator: PhotoTranslateViewModel
    // Pocket Manuals
    @State private var library: ManualLibrary
    @State private var ask: AskViewModel
    @State private var manualsPreferences: ManualsPreferences

    init() {
        let settings = ProviderSettings()
        _showcase = State(initialValue: ShowcaseSelection())
        _settings = State(initialValue: settings)
        _planner = State(initialValue: TripPlannerViewModel())
        _translator = State(initialValue: PhotoTranslateViewModel())
        // The index's embedding fallback uses the shared OpenAI key, only when cloud embeddings are
        // allowed; ShowcaseRootView passes changes on.
        _library = State(initialValue: ManualLibrary(index: ManualIndex(openAIKey: settings.embeddingOpenAIKey)))
        _ask = State(initialValue: AskViewModel())
        _manualsPreferences = State(initialValue: ManualsPreferences())

        Self.bootstrapLogging()
        // Error logs, the SDK's own error reports and trace uploads, with the Conductr key from
        // Settings. Without a key they stay off.
        settings.configureRailtown()
        AppLog.info("App launched", properties: ["Showcase": UserDefaults.standard.string(forKey: "showcase.selected") ?? "none"])
        // Traces default to Documents/sessions. Keep the default so the Files app
        // (and the Share button in the Plan tab) can reach them.
        print("Trace directory: \(RailtracksSwift.flowGraphOutputDirectory.path)")
    }

    var body: some Scene {
        WindowGroup {
            withEnvironment(ShowcaseRootView())
        }
        #if os(macOS)
        // ⌘, and the sidebar's Settings button. The same view as the iOS Settings tab.
        Settings {
            withEnvironment(SettingsView())
                .frame(width: 560, height: 680)
        }
        #endif
    }

    /// Every scene sees the same shared state.
    private func withEnvironment(_ content: some View) -> some View {
        content
            .environment(showcase)
            .environment(settings)
            .environment(planner)
            .environment(translator)
            .environment(library)
            .environment(ask)
            .environment(manualsPreferences)
    }

    private static func bootstrapLogging() {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            #if DEBUG
            handler.logLevel = .debug
            #else
            handler.logLevel = .info
            #endif
            return handler
        }
    }
}
