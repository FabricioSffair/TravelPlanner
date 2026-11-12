//
//  AskIntents.swift
//  TripBriefing
//
//  Siri, Spotlight and Shortcuts actions. Each runs the same agents as the Chat
//  tab, in the app process, through the view models the App struct registers with
//  AppDependencyManager: the indexes live there, and a second copy would load the embedding
//  model twice. The question and answer also show in the app afterwards.
//

import AppIntents
import SwiftUI

// MARK: - Travel Assistant

struct AskTravelAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Travel Assistant"
    static let description = IntentDescription(
        "Answers a question about your latest trip briefing and its Wikivoyage guide, with the same Trip Assistant as the Chat tab."
    )

    @Parameter(title: "Question", requestValueDialog: "What do you want to know about your trip?")
    var question: String

    @Dependency private var planner: TripPlannerViewModel
    @Dependency private var settings: ProviderSettings

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Travel Assistant \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        IntentAnswer.reply(await Self.answer(question, planner: planner, settings: settings))
    }

    /// The Trip Assistant's answer, through the Chat tab's own send, so it also shows in Chat.
    @MainActor
    static func answer(_ question: String, planner: TripPlannerViewModel, settings: ProviderSettings) async -> IntentAnswer.Reply {
        if let reason = settings.agentsUnavailableReason {
            return IntentAnswer.Reply(reason)
        }
        // On-device agents running side by side can mix up tool arguments, so one run at a time.
        guard !planner.isRunning, !planner.isAnswering else {
            return IntentAnswer.Reply("Travel Assistant is busy with another answer. Try again in a moment.")
        }
        if let reason = await planner.prepareForIntent(settings: settings) {
            return IntentAnswer.Reply(reason)
        }
        guard let run = planner.sendChat(question, settings: settings) else {
            return IntentAnswer.Reply("Travel Assistant could not take the question. Try again in a moment.")
        }
        AppLog.info("Siri question sent")

        switch await IntentAnswer.wait(for: run) {
        case .stillRunning:
            return IntentAnswer.Reply(IntentAnswer.stillRunning(tab: "Chat"))
        case .finished(let message):
            guard let message, !message.text.isEmpty else {
                return IntentAnswer.Reply("Travel Assistant did not answer.")
            }
            if message.isError {
                return IntentAnswer.Reply("Travel Assistant could not answer: \(message.text)")
            }
            return IntentAnswer.Reply(
                CalendarDates.normalized(message.text, tripDays: planner.chatTripDays),
                sources: message.sources
            )
        }
    }
}

// MARK: - Siri phrases

/// Siri phrases and Spotlight actions, available as soon as the app is installed. A phrase can
/// only hold entity or enum parameters, so Siri asks for the question after the phrase.
struct TravelAssistantShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskTravelAssistantIntent(),
            phrases: [
                "Ask \(.applicationName) about my trip",
                "Ask \(.applicationName) travel assistant",
            ],
            shortTitle: "Ask About My Trip",
            systemImageName: "airplane.departure"
        )
        AppShortcut(
            intent: GetTripActivitiesIntent(),
            phrases: [
                "Get my \(.applicationName) activities",
                "List my \(.applicationName) trip activities",
            ],
            shortTitle: "Get Trip Activities",
            systemImageName: "map"
        )
    }
}

// MARK: - Shared

enum IntentAnswer {
    enum Outcome<Value> {
        case finished(Value)
        case stillRunning
    }

    /// How long an intent waits for its run, in seconds. On-device runs with tool calls can take
    /// longer than Siri waits for an answer, so after this the intent says where to find it.
    static let waitSeconds: Double = 20

    private struct StillRunning: Error {}

    /// The run's value, or `.stillRunning` after `waitSeconds`. Uses `withDeadline` rather than a
    /// task group, which would wait for the run to finish before returning. The run keeps going
    /// either way, and its answer lands in the app.
    static func wait<Value: Sendable>(for run: Task<Value, Never>) async -> Outcome<Value> {
        do {
            let value = try await withDeadline(
                seconds: waitSeconds,
                timeoutError: { StillRunning() },
                operation: { await run.value }
            )
            return .finished(value)
        } catch {
            return .stillRunning
        }
    }

    static func stillRunning(tab: String) -> String {
        "This is taking longer than usual. The answer will be in \(tab) when it is ready."
    }

    /// What an action answers: the text, and the sources its searches returned.
    struct Reply {
        let text: String
        var sources: [String] = []

        init(_ text: String, sources: [String] = []) {
            self.text = text
            self.sources = sources
        }
    }

    /// The text as the action's value and on screen, and without Markdown as the dialog. With
    /// `keepsLayout`, the dialog keeps the empty lines and shows list items with "•": Siri AI
    /// writes its reply from the dialog, so a flat dialog gives a flat reply.
    @MainActor
    static func reply(
        _ reply: Reply,
        keepsLayout: Bool = false
    ) -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        .result(
            value: reply.text,
            dialog: IntentDialog(stringLiteral: keepsLayout ? laidOut(reply.text) : spoken(reply.text)),
            view: IntentAnswerView(text: reply.text, sources: reply.sources)
        )
    }

    /// Markdown as plain text that keeps its layout: one empty line between blocks, "•" for each
    /// list item, no heading markers, no emphasis, links as their text.
    static func laidOut(_ markdown: String) -> String {
        var lines: [String] = []
        for line in markdown.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
                .replacing(#/^#+\s+/#, with: "")
                .replacing(#/^[-*•]\s+/#, with: "• ")
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let text = lines.joined(separator: "\n")
        let inline = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        return inline.map { String($0.characters) } ?? text
    }

    /// Markdown as plain sentences: no heading or list markers, no emphasis, links as their text.
    static func spoken(_ markdown: String) -> String {
        let lines = markdown
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                line.trimmingCharacters(in: .whitespaces)
                    .replacing(#/^(#+|[-*•]|\d+\.)\s+/#, with: "")
            }
            .joined(separator: "\n")
        let inline = try? AttributedString(
            markdown: lines,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        return inline.map { String($0.characters) } ?? lines
    }
}

/// The answer under Siri's dialog and in Shortcuts, with the sources the searches returned.
/// Draws the answer's Markdown line by line: headings, list items with "•", paragraphs, and a gap
/// for each empty line. `Text` alone draws inline Markdown only, so lists and line breaks were lost.
struct IntentAnswerView: View {
    let text: String
    let sources: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(Self.lines(text).enumerated()), id: \.offset) { _, line in
                    switch line {
                    case .heading(let text):
                        Text(Self.inline(text)).font(.headline)
                    case .item(let text):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Text(Self.inline(text))
                        }
                    case .paragraph(let text):
                        Text(Self.inline(text))
                    case .gap:
                        Color.clear.frame(height: 4)
                    }
                }
            }
            .font(.callout)
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sources.prefix(4), id: \.self) { source in
                        Label(source, systemImage: "doc.text.magnifyingglass")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        // Its own background, so the text and the background follow the same appearance. Without
        // it, a Mac in light mode drew dark text on Siri's dark panel.
        .background(.background, in: .rect(cornerRadius: 16))
    }

    enum Line {
        case heading(String)
        case item(String)
        case paragraph(String)
        case gap
    }

    /// "**Day 1**\n- Morning: …\n\n**Day 2**" → paragraph, item, gap, paragraph. Runs of empty
    /// lines become one gap, and none at the start or end.
    static func lines(_ markdown: String) -> [Line] {
        var lines: [Line] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let last = lines.last, case .gap = last { continue }
                if !lines.isEmpty { lines.append(.gap) }
            } else if let match = line.firstMatch(of: #/^#+\s+(.+)/#) {
                lines.append(.heading(String(match.1)))
            } else if let match = line.firstMatch(of: #/^[-*•]\s+(.+)/#) {
                lines.append(.item(String(match.1)))
            } else {
                lines.append(.paragraph(line))
            }
        }
        if let last = lines.last, case .gap = last { lines.removeLast() }
        return lines
    }

    /// Bold, italics, code and links within one line.
    private static func inline(_ text: String) -> AttributedString {
        try! AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }
}
