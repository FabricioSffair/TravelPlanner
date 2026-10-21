//
//  TripBriefingRootView.swift
//  TripBriefing
//
//  Travel Assistant's root (Trip Briefing in code): tabs on iOS, a sidebar on macOS. The view
//  models are created once in the App struct. Also opens the trip note a tapped Spotlight
//  result points at.
//

import CoreSpotlight
import SwiftUI

enum TripTab: Hashable {
    case plan, chat, translate, settings
}

struct TripBriefingRootView: View {
    @Environment(TripPlannerViewModel.self) private var planner
    @Environment(PhotoTranslateViewModel.self) private var translator

    @State private var tab: TripTab = .plan
    /// The trip note a tapped Spotlight result opens.
    @State private var spotlightNote: SpotlightNote?

    var body: some View {
        Group {
            #if os(macOS)
            MacRootView(tab: $tab)
            #else
            TabView(selection: $tab) {
                Tab("Plan", systemImage: "airplane.departure", value: TripTab.plan) {
                    PlanView(model: planner)
                }
                Tab("Chat", systemImage: "bubble.left.and.text.bubble.right", value: TripTab.chat) {
                    TripChatView(model: planner)
                }
                Tab("Translate", systemImage: "camera.viewfinder", value: TripTab.translate) {
                    TranslateView(model: translator)
                }
                Tab("Settings", systemImage: "key", value: TripTab.settings) {
                    SettingsView()
                }
            }
            #endif
        }
        .task { SpotlightIndex.syncAtLaunch() }
        .onContinueUserActivity(CSSearchableItemActionType, perform: openSpotlightResult)
        .sheet(item: $spotlightNote) { item in
            TripNoteSheet(note: item.note, destination: item.destination)
        }
    }

    private func openSpotlightResult(_ activity: NSUserActivity) {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
        spotlightNote = SpotlightIndex.note(for: identifier)
    }
}
