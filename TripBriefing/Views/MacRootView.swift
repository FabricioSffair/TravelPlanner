//
//  MacRootView.swift
//  TripBriefing
//
//  The macOS window: a sidebar with Plan, Chat and Translate, and the chosen
//  screen as the detail. Same layout as the Whiteboard app's macOS target.
//  Settings is a separate scene, opened from the sidebar button or with ⌘,.
//

#if os(macOS)
import SwiftUI

struct MacRootView: View {
    @Environment(TripPlannerViewModel.self) private var planner
    @Environment(PhotoTranslateViewModel.self) private var translator
    @Environment(\.openSettings) private var openSettings

    @Binding var tab: TripTab

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 240)
        } detail: {
            detail
                .frame(minWidth: 640)
        }
        .frame(minWidth: 1080, minHeight: 680)
    }

    /// Settings is not a sidebar row on the Mac, so it maps to Plan.
    private var selection: Binding<TripTab?> {
        Binding(
            get: { tab == .settings ? .plan : tab },
            set: { if let destination = $0 { tab = destination } }
        )
    }

    private var sidebar: some View {
        List(selection: selection) {
            Label("Plan", systemImage: "airplane.departure")
                .tag(TripTab.plan)
            Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                .tag(TripTab.chat)
            Label("Translate", systemImage: "camera.viewfinder")
                .tag(TripTab.translate)
        }
        .listStyle(.sidebar)
        .navigationTitle("Travel Assistant")
        .safeAreaInset(edge: .bottom) {
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .hoverOpacity()
            .padding(.horizontal, .spacing3XL)
            .padding(.vertical, .spacingXL)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch tab {
        case .chat: TripChatView(model: planner)
        case .translate: TranslateView(model: translator)
        case .plan, .settings: PlanView(model: planner)
        }
    }
}
#endif
