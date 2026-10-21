//
//  AskIntents.swift
//  TripBriefing
//
//  Siri, Spotlight and Shortcuts actions for both showcases. Each runs the same agents as its
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
        AppLog.info("Siri question sent", properties: ["Showcase": "Travel Assistant"])

        switch await IntentAnswer.wait(for: run) {
        case .stillRunning:
            return IntentAnswer.Reply(IntentAnswer.stillRunning(tab: "Chat in Travel Assistant"))
        case .finished(let message):
            guard let message, !message.text.isEmpty else {
                return IntentAnswer.Reply("Travel Assistant did not answer.")
            }
            if message.isError {
                return IntentAnswer.Reply("Travel Assistant could not answer: \(message.text)")
            }
            return IntentAnswer.Reply(message.text, sources: message.sources)
        }
    }
}

// MARK: - Pocket Manuals

struct AskPocketManualsIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Pocket Manuals"
    static let description = IntentDescription(
        "Answers a question from your indexed PDF manuals, with the page each statement comes from."
    )

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask your manuals?")
    var question: String

    @Dependency private var ask: AskViewModel
    @Dependency private var library: ManualLibrary
    @Dependency private var settings: ProviderSettings
    @Dependency private var preferences: ManualsPreferences

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Pocket Manuals \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        IntentAnswer.reply(await Self.answer(question, ask: ask, library: library, settings: settings, preferences: preferences))
    }

    /// The Ask tab's answer to `question` over every searchable manual, through the tab's own
    /// view model, so it also shows in Ask.
    @MainActor
    static func answer(
        _ question: String,
        ask: AskViewModel,
        library: ManualLibrary,
        settings: ProviderSettings,
        preferences: ManualsPreferences
    ) async -> IntentAnswer.Reply {
        guard !ask.isRunning else {
            return IntentAnswer.Reply("Pocket Manuals is busy with another question. Try again in a moment.")
        }
        // A fresh launch has not checked the embedder yet, and no manual is searchable until it has.
        if library.embedderStatus == nil {
            await library.refreshEmbedderStatus()
        }
        ask.question = question
        ask.scopeID = nil
        guard let run = ask.ask(settings: settings, preferences: preferences, library: library) else {
            return IntentAnswer.Reply(ask.errorMessage ?? "Pocket Manuals could not take the question.")
        }
        AppLog.info("Siri question sent", properties: ["Showcase": "Pocket Manuals"])

        switch await IntentAnswer.wait(for: run) {
        case .stillRunning:
            return IntentAnswer.Reply(IntentAnswer.stillRunning(tab: "Ask in Pocket Manuals"))
        case .finished:
            return finishedAnswer(ask: ask, library: library)
        }
    }

    /// The claims as sentences, each followed by the pages it cites, e.g.
    /// "Cook chicken to 165 °F (Kitchen Companion, p. 12)." A claim the Verifier found
    /// unsupported says so.
    @MainActor
    private static func finishedAnswer(ask: AskViewModel, library: ManualLibrary) -> IntentAnswer.Reply {
        if let error = ask.errorMessage {
            return IntentAnswer.Reply("Pocket Manuals could not answer: \(error)")
        }
        guard let answer = ask.answer else {
            return IntentAnswer.Reply(ask.undecodedAnswer ?? "Pocket Manuals did not answer.")
        }
        if answer.notFound || answer.claims.isEmpty {
            return IntentAnswer.Reply("Your manuals do not cover that.")
        }
        var pages: [String] = []
        let sentences = answer.claims.enumerated().map { number, claim in
            let labels = claim.citations.compactMap { ask.pageReference(for: $0, library: library)?.chipLabel }
            pages.append(contentsOf: labels.filter { !pages.contains($0) })
            var sentence = claim.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.hasSuffix(".") { sentence.removeLast() }
            // The on-device model sometimes starts a claim mid-sentence, in lowercase.
            sentence = sentence.prefix(1).uppercased() + sentence.dropFirst()
            if !labels.isEmpty { sentence += " (\(labels.joined(separator: "; ")))" }
            if ask.verdicts[number + 1]?.kind == .unsupported {
                sentence += ". The cited page does not support this"
            }
            return sentence + "."
        }
        return IntentAnswer.Reply(sentences.joined(separator: " "), sources: pages)
    }
}

// MARK: - Siri phrases

/// Siri phrases and Spotlight actions, available as soon as the app is installed. A phrase can
/// only hold entity or enum parameters, so Siri asks for the question after the phrase.
struct RailtracksShortcuts: AppShortcutsProvider {
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
            intent: AskPocketManualsIntent(),
            phrases: [
                "Ask \(.applicationName) about my manuals",
                "Search my manuals in \(.applicationName)",
            ],
            shortTitle: "Ask My Manuals",
            systemImageName: "book.pages"
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

    /// The text as the action's value and on screen, and without Markdown as the spoken dialog.
    @MainActor
    static func reply(_ reply: Reply) -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        .result(
            value: reply.text,
            dialog: IntentDialog(stringLiteral: spoken(reply.text)),
            view: IntentAnswerView(text: reply.text, sources: reply.sources)
        )
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
struct IntentAnswerView: View {
    let text: String
    let sources: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text((try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(text))
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
    }
}
