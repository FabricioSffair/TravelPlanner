//
//  LibraryView.swift
//  PocketManuals
//

import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(ManualLibrary.self) private var library
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            Group {
                if library.documents.isEmpty {
                    ContentUnavailableView {
                        Label("No manuals yet", systemImage: "book.closed")
                    } description: {
                        Text("Import a PDF manual. It is indexed page by page so answers can cite pages.")
                    } actions: {
                        Button("Import PDF") { isImporting = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isImporting = true
                    } label: {
                        Label("Import PDF", systemImage: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    urls.forEach(library.importPDF(from:))
                case .failure(let error):
                    library.lastError = error.localizedDescription
                }
            }
            .alert("Library", isPresented: errorBinding) {
                Button("OK", role: .cancel) { library.lastError = nil }
            } message: {
                Text(library.lastError ?? "")
            }
        }
    }

    private var list: some View {
        List {
            let imported = library.documents.filter { !$0.isSample }
            let samples = library.documents.filter(\.isSample)
            if !imported.isEmpty {
                Section("My manuals") {
                    ForEach(imported) { ManualRow(document: $0) }
                        .onDelete { library.delete(ids: $0.map { imported[$0].id }) }
                }
            }
            if !samples.isEmpty {
                Section {
                    ForEach(samples) { ManualRow(document: $0) }
                        .onDelete { library.delete(ids: $0.map { samples[$0].id }) }
                } header: {
                    Text("Samples")
                } footer: {
                    Text("Samples are indexed only when you tap Index.")
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { library.lastError != nil },
            set: { if !$0 { library.lastError = nil } }
        )
    }
}

private struct ManualRow: View {
    @Environment(ManualLibrary.self) private var library
    let document: ManualDocument

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(document.pageCount == 1 ? "1 page" : "\(document.pageCount) pages")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                stateView
            }
            Spacer(minLength: 0)
            actionButton
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stateView: some View {
        switch document.indexState {
        case .notIndexed:
            Label("Not indexed", systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .indexing(let progress):
            ProgressView(value: progress) {
                Text("Indexing… \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .indexed(let chunks, let embedder):
            VStack(alignment: .leading, spacing: 2) {
                Label("Indexed · \(chunks) chunks · \(embedder)", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                if let active = library.activeEmbedderLabel, active != embedder {
                    Text("Built with \(embedder); re-index for \(active) search.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch document.indexState {
        case .notIndexed:
            Button("Index") { library.requestIndex(document.id) }
                .buttonStyle(.bordered)
        case .failed:
            Button("Retry") { library.requestIndex(document.id) }
                .buttonStyle(.bordered)
        case .indexing, .indexed:
            EmptyView()
        }
    }
}
