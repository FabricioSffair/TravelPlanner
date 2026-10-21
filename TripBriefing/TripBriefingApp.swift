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
import AppIntents
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
        let planner = TripPlannerViewModel()
        // The index's embedding fallback uses the shared OpenAI key, only when cloud embeddings are
        // allowed; ShowcaseRootView passes changes on.
        let library = ManualLibrary(index: ManualIndex(openAIKey: settings.embeddingOpenAIKey))
        let ask = AskViewModel()
        let manualsPreferences = ManualsPreferences()
        _showcase = State(initialValue: ShowcaseSelection())
        _settings = State(initialValue: settings)
        _planner = State(initialValue: planner)
        _translator = State(initialValue: PhotoTranslateViewModel())
        _library = State(initialValue: library)
        _ask = State(initialValue: ask)
        _manualsPreferences = State(initialValue: manualsPreferences)
        // The Siri and Shortcuts actions use these same instances: see AskIntents.swift.
        AppDependencyManager.shared.add(dependency: settings)
        AppDependencyManager.shared.add(dependency: planner)
        AppDependencyManager.shared.add(dependency: library)
        AppDependencyManager.shared.add(dependency: ask)
        AppDependencyManager.shared.add(dependency: manualsPreferences)

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
