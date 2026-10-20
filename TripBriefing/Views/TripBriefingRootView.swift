//
//  TripBriefingRootView.swift
//  TripBriefing
//
//  Travel Assistant's tabs (the Trip Briefing showcase in code). The view models are created once in the App struct,
//  so a run and its results survive switching showcases.
//

import SwiftUI

struct TripBriefingRootView: View {
    @Environment(TripPlannerViewModel.self) private var planner
    @Environment(PhotoTranslateViewModel.self) private var translator

    @Binding var tab: ShowcaseTab

    var body: some View {
        TabView(selection: $tab) {
            Tab("Plan", systemImage: "airplane.departure", value: ShowcaseTab.primary) {
                PlanView(model: planner)
            }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right", value: ShowcaseTab.chat) {
                TripChatView(model: planner)
            }
            Tab("Translate", systemImage: "camera.viewfinder", value: ShowcaseTab.secondary) {
                TranslateView(model: translator)
            }
            Tab("Settings", systemImage: "key", value: ShowcaseTab.settings) {
                SettingsView()
            }
        }
    }
}
