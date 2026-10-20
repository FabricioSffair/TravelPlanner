//
//  ManualsSettingsSection.swift
//  PocketManuals
//
//  Pocket Manuals' part of the shared Settings form: grounding, the active
//  embedder (or why none is available), and re-indexing.
//

import SwiftUI

struct ManualsSettingsSection: View {
    @Environment(ManualsPreferences.self) private var preferences
    @Environment(ManualLibrary.self) private var library

    var body: some View {
        @Bindable var preferences = preferences
        Section {
            Toggle("Ground answers in my manuals", isOn: $preferences.groundsAnswers)
        } footer: {
            Text("On: the Answerer searches your indexed manuals and cites pages, then the Verifier checks each claim. Off: the Answerer uses model knowledge only and the Verifier is skipped.")
        }

        Section {
            LabeledContent("Embedder") {
                if let status = library.embedderStatus {
                    Text(status.label)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(statusColor(status))
                } else {
                    ProgressView()
                }
            }
            .task { await library.refreshEmbedderStatus() }
            Button("Re-index library") {
                library.reindexAll()
            }
            .disabled(library.embedderStatus.map(isUnavailable) ?? true)
        } header: {
            Text("Index")
        } footer: {
            Text("Pages are embedded on-device when Apple's model is on this device; otherwise with OpenAI embeddings, only when Allow OpenAI embeddings is on and an OpenAI key is set. Re-indexing skips pages already stored for the active embedder.")
        }
    }

    private func isUnavailable(_ status: ManualEmbedderStatus) -> Bool {
        if case .unavailable = status { return true }
        return false
    }

    private func statusColor(_ status: ManualEmbedderStatus) -> Color {
        isUnavailable(status) ? .red : .primary
    }
}
