//
//  TripNoteSheet.swift
//  TripBriefing
//
//  One part of the latest briefing, opened from a Spotlight result. Reads the saved notes, so it
//  works before a briefing runs in this launch.
//

import SwiftUI

struct TripNoteSheet: View {
    let note: TripNote
    let destination: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(note.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("\(destination) · \(note.part)")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}
