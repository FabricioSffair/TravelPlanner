//
//  AskView.swift
//  PocketManuals
//
//  Ask a question; get claims with page citations, a verdict per claim, and
//  the passages that were retrieved.
//

import SwiftUI

struct AskView: View {
    @Environment(ProviderSettings.self) private var settings
    @Environment(ManualsPreferences.self) private var preferences
    @Environment(ManualLibrary.self) private var library
    @Bindable var model: AskViewModel
    @State private var openPage: PageReference?
    @FocusState private var questionFocused: Bool

    var body: some View {
        @Bindable var preferences = preferences
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inputSection(grounded: $preferences.groundsAnswers)
                    if preferences.groundsAnswers && library.searchableDocuments.isEmpty {
                        noIndexBanner
                    }
                    if model.isRunning || model.answererState != .idle {
                        progressSection
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                    answerSection
                    sourcesSection
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Ask")
            .sheet(item: $openPage) { ManualPageViewer(reference: $0) }
        }
    }

    // MARK: Input

    private func inputSection(grounded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask your manuals…", text: $model.question, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($questionFocused)
                    .submitLabel(.send)
                    .onSubmit(ask)
                Button(action: ask) {
                    if model.isRunning {
                        ProgressView()
                    } else {
                        Text("Ask")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning || model.question.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AskViewModel.suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            model.question = suggestion
                            ask()
                        }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                        .disabled(model.isRunning)
                    }
                }
            }

            Toggle("Ground answers in my manuals", isOn: grounded)
                .font(.subheadline)
                .disabled(model.isRunning)

            if grounded.wrappedValue {
                Picker("Search", selection: $model.scopeID) {
                    Text("All manuals").tag(String?.none)
                    ForEach(library.searchableDocuments) { document in
                        Text(document.title).tag(Optional(document.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.isRunning || library.searchableDocuments.isEmpty)
            }
        }
    }

    private var noIndexBanner: some View {
        Label {
            Text("Nothing is indexed yet. Open the Library tab and tap **Index** on a sample manual, or import a PDF.")
        } icon: {
            Image(systemName: "books.vertical")
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            stepRow(
                "Answerer",
                detail: model.wasGrounded ? "searches the manuals, answers with citations" : "model knowledge only",
                state: model.answererState,
                extra: nil
            )
            stepRow(
                "Verifier",
                detail: model.wasGrounded ? "checks each claim against the passages" : "skipped when not grounded",
                state: model.verifierState,
                extra: nil
            )
            if let elapsed = model.elapsed {
                Text(String(format: "%.1f s", elapsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stepRow(_ title: String, detail: String, state: AskViewModel.StepState, extra: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            stepIcon(state)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(extra ?? stepDetail(state, fallback: detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ state: AskViewModel.StepState) -> some View {
        switch state {
        case .idle: Image(systemName: "circle").foregroundStyle(.secondary)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func stepDetail(_ state: AskViewModel.StepState, fallback: String) -> String {
        if case .failed(let message) = state { return message }
        return fallback
    }

    // MARK: Answer

    @ViewBuilder
    private var answerSection: some View {
        if let answer = model.answer {
            VStack(alignment: .leading, spacing: 12) {
                if let asked = model.askedQuestion {
                    Text(asked).font(.headline)
                }
                if !model.wasGrounded {
                    Label("Not grounded — model knowledge only", systemImage: "exclamationmark.bubble")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if answer.notFound {
                    Label("The manuals don't cover this.", systemImage: "questionmark.folder")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(answer.claims.enumerated()), id: \.offset) { offset, claim in
                    claimRow(number: offset + 1, claim: claim)
                }
                if model.verifierUnreadable {
                    Text("The Verifier's reply could not be read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        } else if let raw = model.undecodedAnswer {
            VStack(alignment: .leading, spacing: 6) {
                Text("The answer was not in the expected format:").font(.caption).foregroundStyle(.secondary)
                Text(raw).font(.callout).textSelection(.enabled)
            }
        }
    }

    private func claimRow(number: Int, claim: ManualClaim) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if model.wasGrounded {
                    verdictBadge(model.verdicts[number])
                }
                Text(claim.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !claim.citations.isEmpty {
                ChipFlow(spacing: 6) {
                    ForEach(claim.citations, id: \.self) { citation in
                        citationChip(citation)
                    }
                }
            }
            if let note = model.verdicts[number]?.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func verdictBadge(_ verdict: ClaimVerdict?) -> some View {
        switch verdict?.kind {
        case .supported?:
            Text("✓").foregroundStyle(.green).accessibilityLabel("Supported")
        case .partial?:
            Text("~").foregroundStyle(.orange).accessibilityLabel("Partly supported")
        case .unsupported?:
            Text("⚠").foregroundStyle(.red).accessibilityLabel("Unsupported")
        case nil:
            Text("·").foregroundStyle(.secondary).accessibilityLabel("Not verified")
        }
    }

    @ViewBuilder
    private func citationChip(_ citation: String) -> some View {
        if let reference = model.pageReference(for: citation, library: library) {
            Button {
                openPage = reference
            } label: {
                Label(reference.chipLabel, systemImage: "doc.text")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Text(citation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))
                .accessibilityLabel("Unknown source \(citation)")
        }
    }

    // MARK: Sources

    @ViewBuilder
    private var sourcesSection: some View {
        if !model.sources.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sources").font(.headline)
                ForEach(model.sources, id: \.self) { hit in
                    Button {
                        openPage = model.pageReference(for: hit)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(PageReference.shortTitle(hit.title)), p. \(hit.page)")
                                .font(.subheadline.weight(.semibold))
                            Text(hit.content.replacingOccurrences(of: "\n", with: " "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func ask() {
        questionFocused = false
        model.ask(settings: settings, preferences: preferences, library: library)
    }
}

/// Lays chips out left to right, wrapping onto new lines.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
