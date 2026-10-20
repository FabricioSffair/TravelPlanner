//
//  Showcase.swift
//  TripBriefing
//
//  The demos this app hosts, and which one is running. The selection is
//  persisted; it is nil until the user picks one on first launch.
//

import Foundation
import Observation

enum Showcase: String, CaseIterable, Identifiable {
    case tripBriefing, pocketManuals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tripBriefing: "Travel Assistant"
        case .pocketManuals: "Pocket Manuals"
        }
    }

    var subtitle: String {
        switch self {
        case .tripBriefing: "A trip briefing from parallel agents, a chat grounded in Wikivoyage, and a sign translator"
        case .pocketManuals: "Ask your PDF manuals — answers cite the page and get verified"
        }
    }

    var systemImage: String {
        switch self {
        case .tripBriefing: "airplane.departure"
        case .pocketManuals: "book.pages"
        }
    }
}

/// Tab slots both showcases share, so switching in Settings lands on the other showcase's Settings.
enum ShowcaseTab: Hashable {
    /// Plan, or Library.
    case primary
    /// Translate, or Ask.
    case secondary
    /// Travel Assistant's Chat. Pocket Manuals has no such tab and shows its Library instead.
    case chat
    case settings
}

@MainActor
@Observable
final class ShowcaseSelection {
    private static let defaultsKey = "showcase.selected"

    /// `nil` shows the picker.
    var selected: Showcase? {
        didSet {
            if let selected {
                UserDefaults.standard.set(selected.rawValue, forKey: Self.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            }
        }
    }

    init() {
        selected = UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(Showcase.init(rawValue:))
    }
}
