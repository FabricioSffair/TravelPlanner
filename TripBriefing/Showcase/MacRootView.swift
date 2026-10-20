//
//  MacRootView.swift
//  TripBriefing
//
//  The macOS window: a sidebar with both showcases' screens, and the chosen
//  screen as the detail. Same layout as the Whiteboard app's macOS target. iOS
//  keeps the picker and tab bars in ShowcaseRootView.
//
//  Picking a row sets the same `showcase.selected` and tab slot the iOS tabs
//  use, so the selection persists and the view models are shared.
//

#if os(macOS)
import SwiftUI

/// One sidebar row: a screen of one showcase.
enum MacDestination: String, Hashable, CaseIterable, Identifiable {
    case plan, chat, translate, library, ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan: "Plan"
        case .chat: "Chat"
        case .translate: "Translate"
        case .library: "Library"
        case .ask: "Ask"
        }
    }

    var systemImage: String {
        switch self {
        case .plan: "airplane.departure"
        case .chat: "bubble.left.and.text.bubble.right"
        case .translate: "camera.viewfinder"
        case .library: "books.vertical"
        case .ask: "questionmark.bubble"
        }
    }

    var showcase: Showcase {
        switch self {
        case .plan, .chat, .translate: .tripBriefing
        case .library, .ask: .pocketManuals
        }
    }

    var tab: ShowcaseTab {
        switch self {
        case .plan, .library: .primary
        case .chat: .chat
        case .translate, .ask: .secondary
        }
    }

    static func from(showcase: Showcase?, tab: ShowcaseTab) -> MacDestination {
        switch (showcase ?? .tripBriefing, tab) {
        case (.tripBriefing, .secondary): .translate
        case (.tripBriefing, .chat): .chat
        case (.tripBriefing, _): .plan
        case (.pocketManuals, .secondary): .ask
        case (.pocketManuals, _): .library
        }
    }
}

struct MacRootView: View {
    @Environment(ShowcaseSelection.self) private var showcase
    @Environment(ManualLibrary.self) private var library
    @Environment(TripPlannerViewModel.self) private var planner
    @Environment(PhotoTranslateViewModel.self) private var translator
    @Environment(AskViewModel.self) private var ask
    @Environment(\.openSettings) private var openSettings

    @Binding var tab: ShowcaseTab

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 240)
        } detail: {
            detail
                .frame(minWidth: 640)
        }
        .frame(minWidth: 1080, minHeight: 680)
        .task {
            // Loads the on-device model if its assets are present; no download, no network.
            await library.refreshEmbedderStatus()
        }
    }

    private var selection: Binding<MacDestination?> {
        Binding(
            get: { MacDestination.from(showcase: showcase.selected, tab: tab) },
            set: { destination in
                guard let destination else { return }
                showcase.selected = destination.showcase
                tab = destination.tab
            }
        )
    }

    private var sidebar: some View {
        List(selection: selection) {
            ForEach(Showcase.allCases) { item in
                Section(item.title) {
                    ForEach(MacDestination.allCases.filter { $0.showcase == item }) { destination in
                        Label(destination.title, systemImage: destination.systemImage)
                            .tag(destination)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Railtracks Showcase")
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
        switch MacDestination.from(showcase: showcase.selected, tab: tab) {
        case .plan: PlanView(model: planner)
        case .chat: TripChatView(model: planner)
        case .translate: TranslateView(model: translator)
        case .library: LibraryView()
        case .ask: AskView(model: ask)
        }
    }
}
#endif
