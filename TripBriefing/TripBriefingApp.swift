//
//  TripBriefingApp.swift
//  TripBriefing
//
//  Travel Assistant (Trip Briefing in code): a RailtracksSwift showcase. One
//  orchestrator node fans out three agents in parallel (weather, itinerary,
//  phrasebook), then a concierge agent composes the briefing using a
//  packing-list agent exposed as a tool.
//
//  Every long-lived object is created here once and shared by the window, the
//  Settings scene, and the Siri and Shortcuts actions.
//

import SwiftUI
import AppIntents
import Logging
import RailtracksSwift
import RailtownLogger

@main
struct TripBriefingApp: App {
    @State private var settings: ProviderSettings
    @State private var planner: TripPlannerViewModel
    @State private var translator: PhotoTranslateViewModel

    init() {
        let settings = ProviderSettings()
        let planner = TripPlannerViewModel()
        _settings = State(initialValue: settings)
        _planner = State(initialValue: planner)
        _translator = State(initialValue: PhotoTranslateViewModel())
        // The Siri and Shortcuts actions use these same instances: see AskIntents.swift.
        AppDependencyManager.shared.add(dependency: settings)
        AppDependencyManager.shared.add(dependency: planner)

        Self.bootstrapLogging()
        // Error logs, the SDK's own error reports and trace uploads, with the Conductr key from
        // Settings. Without a key they stay off.
        settings.configureRailtown()
        AppLog.info("App launched")
        // Traces default to Documents/sessions. Keep the default so the Files app
        // (and the Share button in the Plan tab) can reach them.
        print("Trace directory: \(RailtracksSwift.flowGraphOutputDirectory.path)")
    }

    var body: some Scene {
        WindowGroup {
            withEnvironment(TripBriefingRootView())
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
            .environment(settings)
            .environment(planner)
            .environment(translator)
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
