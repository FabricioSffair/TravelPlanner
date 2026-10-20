//
//  TripChatView.swift
//  TripBriefing
//
//  Chat with the Trip Assistant. It searches what was indexed for this trip,
//  shown at the top: the finished briefing and the destination's Wikivoyage
//  guide. Each answer lists the passages it drew on and the model that wrote it.
//

import SwiftUI

struct TripChatView: View {
    @Environment(ProviderSettings.self) private var settings
    @Bindable var model: TripPlannerViewModel
    @FocusState private var inputFocused: Bool

    private static let suggestions = [
        "Will it rain during my trip?",
        "What is the plan for day 2?",
        "How do I get from the airport to the city?",
        "Is it safe to walk around at night?",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: .spacing3XL) {
                            IndexedSourcesCard(model: model)
                            if model.chatMessages.isEmpty {
                                suggestionsView
                            }
                            ForEach(model.chatMessages) { message in
                                ChatBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.spacing4XL)
                    }
                    .onChange(of: model.chatMessages) {
                        guard let last = model.chatMessages.last else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                inputBar
            }
            .navigationTitle("Chat")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear", systemImage: "trash") { model.clearChat() }
                        .disabled(model.chatMessages.isEmpty || model.isAnswering)
                }
            }
            .task { model.prepareChat(settings: settings) }
        }
    }

    private var suggestionsView: some View {
        VStack(alignment: .leading, spacing: .spacingMD) {
            Text("Try asking")
                .font(.headline)
            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button {
                    model.sendChat(suggestion, settings: settings)
                } label: {
                    Label(suggestion, systemImage: "text.bubble")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, .spacingXL)
                        .padding(.vertical, .spacingMD)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: .radiusSM))
                }
                .buttonStyle(.plain)
                .hoverOpacity()
                .disabled(!model.canChat)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: .spacingMD) {
            TextField(placeholder, text: $model.chatDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { send() }
                .padding(.horizontal, .spacingXL)
                .padding(.vertical, .spacingMD)
                .background(.quinary, in: RoundedRectangle(cornerRadius: .radiusLG))
            Button(action: send) {
                if model.isAnswering {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(!model.canChat || model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, .spacing3XL)
        .padding(.vertical, .spacingXL)
        .background(.bar)
    }

    private var placeholder: String {
        if model.isRunning { return "Wait for the briefing to finish…" }
        return model.canChat || model.isAnswering
            ? "Ask about your trip"
            : "Nothing to search yet"
    }

    private func send() {
        model.sendChat(settings: settings)
        inputFocused = true
    }
}

/// What the chat can search: the briefing's notes and the Wikivoyage guide, with their state.
private struct IndexedSourcesCard: View {
    let model: TripPlannerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: .spacingXL) {
            Text("Searching")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            sourceRow(
                symbol: "airplane.departure",
                title: "Your briefing",
                detail: briefingDetail,
                ready: model.chatNoteCount != nil
            )
            sourceRow(
                symbol: "book.pages",
                title: model.chatGuide.map { "Wikivoyage › \($0.articleTitle)" } ?? "Wikivoyage",
                detail: guideDetail,
                ready: model.chatGuide != nil
            )
        }
        .padding(.spacingXL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: .radiusMD))
        .overlay {
            RoundedRectangle(cornerRadius: .radiusMD).strokeBorder(.separator, lineWidth: 1)
        }
    }

    private var briefingDetail: String {
        if let count = model.chatNoteCount {
            return "\(count) notes: weather, day-by-day plan, packing list, tips and phrasebook"
        }
        return model.tripNotesStatus ?? "Build a briefing in Plan to add it."
    }

    private var guideDetail: String {
        if let guide = model.chatGuide {
            return "\(guide.sections.count) sections, \(guide.embedderLabel): \(guide.sections.joined(separator: ", "))"
        }
        return model.chatGuideStatus ?? "Not loaded."
    }

    private func sourceRow(symbol: String, title: String, detail: String, ready: Bool) -> some View {
        HStack(alignment: .top, spacing: .spacingXL) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(.quinary, in: RoundedRectangle(cornerRadius: .radiusSM))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: .spacingSM) {
                    Text(title).font(.body.weight(.medium))
                    Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.caption)
                        .foregroundStyle(ready ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ChatBubble: View {
    let message: TripChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, .spacingXL)
                    .padding(.vertical, .spacingMD)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: .radiusMD))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: .spacingMD) {
                if message.text.isEmpty {
                    HStack(spacing: .spacingMD) {
                        ProgressView().controlSize(.small)
                        Text("Searching your briefing and the guide…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(message.text)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .foregroundStyle(message.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !message.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(message.sources, id: \.self) { source in
                            Label(source, systemImage: source.hasPrefix("Wikivoyage") ? "book.pages" : "airplane.departure")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let model = message.model, !message.text.isEmpty {
                    Label(model, systemImage: model.hasPrefix("Apple Intelligence") && !model.contains("→") ? "sparkles" : "cloud")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.spacingXL)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: .radiusMD))
            .padding(.trailing, 40)
        case .notice:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
