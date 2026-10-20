//
//  ManualsPreferences.swift
//  PocketManuals
//
//  Pocket Manuals' own preferences. The provider and the keys are shared with
//  Travel Assistant and live in ProviderSettings.
//

import Foundation
import Observation

@MainActor
@Observable
final class ManualsPreferences {
    private static let groundingDefaultsKey = "manuals.groundsAnswers"

    /// Answer from the manuals through the search tool, then verify. Off means the Answerer runs
    /// on model knowledge alone and the Verifier is skipped, for a with/without comparison.
    var groundsAnswers: Bool {
        didSet { UserDefaults.standard.set(groundsAnswers, forKey: Self.groundingDefaultsKey) }
    }

    init() {
        groundsAnswers = UserDefaults.standard.object(forKey: Self.groundingDefaultsKey) as? Bool ?? true
    }
}
