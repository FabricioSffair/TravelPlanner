//
//  AskViewModel.swift
//  PocketManuals
//
//  Owns one Ask run. A fresh RTSFlow per run; subscriptions attach before
//  running because nodeStatusPublisher has no replay.
//

import Combine
import Foundation
import Observation
import RailtracksSwift

/// A page of a manual to open in the viewer.
struct PageReference: Identifiable, Hashable {
    let docID: String
    let page: Int
    let title: String

    var id: String { ManualCitation.key(manualID: docID, page: page) }

    /// "Kitchen Companion, p. 12": the title without a trailing "(Publisher)".
    var chipLabel: String { "\(PageReference.shortTitle(title)), p. \(page)" }

    static func shortTitle(_ title: String) -> String {
        guard title.hasSuffix(")"), let open = title.lastIndex(of: "("), open > title.startIndex else { return title }
        let trimmed = title[..<open].trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }
}

@MainActor
@Observable
final class AskViewModel {

    enum StepState: Equatable {
        case idle, queued, running, done, skipped
        case failed(String)
    }

    static let suggestions = [
        "What internal temperature should chicken reach?",
        "What temperature should I set my water heater to?",
        "At what radon level should I fix my home?",
        "What should go in my pet's emergency kit?",
    ]

    var question = ""
    /// `nil` searches every indexed manual.
    var scopeID: String?
    var errorMessage: String?

    private(set) var isRunning = false
    private(set) var answererState: StepState = .idle
    private(set) var verifierState: StepState = .idle

    private(set) var answer: ManualAnswer?
    /// The Answerer's text when it could not be read as an answer.
    private(set) var undecodedAnswer: String?
    /// Keyed by 1-based claim number.
    private(set) var verdicts: [Int: ClaimVerdict] = [:]
    private(set) var verifierUnreadable = false
    /// Every passage the search tool returned this run.
    private(set) var sources: [ManualHit] = []
    /// Whether the last run used the manuals.
    private(set) var wasGrounded = true
    private(set) var askedQuestion: String?
    private(set) var elapsed: TimeInterval?

    private let collector = ManualSourceCollector()
    private var cancellables = Set<AnyCancellable>()

    // MARK: Run

    /// - Returns: the run, done when the answer and verdicts are in; `nil` when nothing ran and
    ///   `errorMessage` says why.
    @discardableResult
    func ask(settings: ProviderSettings, preferences: ManualsPreferences, library: ManualLibrary) -> Task<Void, Never>? {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !question.isEmpty else { return nil }
        if let reason = settings.agentsUnavailableReason {
            errorMessage = reason
            return nil
        }

        let grounded = preferences.groundsAnswers
        let searchable = library.searchableDocuments
        var scopeDescription = ""
        if grounded {
            if case .unavailable(let reason)? = library.embedderStatus {
                errorMessage = "Search is unavailable: \(reason)."
                return nil
            }
            if let scopeID, !searchable.contains(where: { $0.id == scopeID }) {
                self.scopeID = nil
            }
            if let scopeID, let manual = searchable.first(where: { $0.id == scopeID }) {
                scopeDescription = "the manual \"\(manual.title)\""
            } else if searchable.isEmpty {
                errorMessage = "Nothing is indexed yet. Index a sample (or import a PDF) in the Library tab."
                return nil
            } else {
                scopeDescription = "the user's manuals (\(searchable.map(\.title).joined(separator: "; ")))"
            }
        }

        reset()
        isRunning = true
        wasGrounded = grounded
        askedQuestion = question
        verifierState = grounded ? .idle : .skipped
        let started = Date()

        let cloud = settings.agentLLMProvider
        let fallbackProvider = settings.contextFallbackProvider
        let tool = grounded
            ? ManualSearchTool.make(
                index: library.index,
                manualID: scopeID,
                scopeDescription: scopeDescription,
                collector: collector
            )
            : nil
        func answerer(on provider: RTSLLMProvider) -> RTSAgent {
            if let tool {
                return AskAgents.groundedAnswerer(cloud: provider, searchTool: tool)
            }
            return AskAgents.ungroundedAnswerer(cloud: provider)
        }
        var workflow = AskWorkflow(
            answerer: answerer(on: cloud),
            verifier: grounded ? AskAgents.verifier(cloud: cloud) : nil,
            collector: collector
        )
        // The same agents on the cloud provider, used when an on-device prompt overflows.
        if let fallbackProvider {
            workflow.fallbackAnswerer = answerer(on: fallbackProvider)
            workflow.fallbackVerifier = grounded ? AskAgents.verifier(cloud: fallbackProvider) : nil
        }
        let overflowHint = TripPlannerViewModel.overflowHint(settings: settings)

        let gateway = settings.makeGateway()
        let flow = RTSFlow(title: AskAgents.Name.workflow)
        subscribe(to: flow)
        // The question text stays out of the logs.
        let properties = [
            "Showcase": "Pocket Manuals",
            "Provider": cloud.callTreeLabel,
            "Grounded": "\(grounded)",
            "Scope": scopeID == nil ? "library" : "one manual",
        ]
        let traceUpload = RailtownSetup.uploadTrace(of: flow)

        return Task { [weak self] in
            defer {
                RailtownSetup.finishTraceUpload(traceUpload)
                self?.isRunning = false
                self?.elapsed = Date().timeIntervalSince(started)
            }
            do {
                let output = try await flow.run(
                    workflow,
                    input: [AskWorkflow.InputKey.question: .string(question)],
                    gateway: gateway
                )
                self?.consume(output)
                AppLog.info("Manuals question answered", properties: properties.merging([
                    "Seconds": String(format: "%.1f", Date().timeIntervalSince(started)),
                ]) { current, _ in current })
            } catch {
                self?.errorMessage = ContextFallback.isContextOverflow(error)
                    ? "\(error)\n\(overflowHint)"
                    : "\(error)"
                AppLog.error(error, message: "Manuals question failed", properties: properties)
            }
            self?.sources = self?.collector.hits ?? []
            if self?.verifierState == .idle { self?.verifierState = .skipped }
        }
    }

    // MARK: Citations

    /// The page a citation points at. Accepts the citation key the Answerer is asked for, and
    /// falls back to a "<title>, p. <n>" display string should a model cite that instead.
    func pageReference(for citation: String, library: ManualLibrary) -> PageReference? {
        let trimmed = citation.trimmingCharacters(in: .whitespacesAndNewlines)
        if let marker = trimmed.range(of: "#page-", options: .backwards),
           let page = Int(trimmed[marker.upperBound...]) {
            let docID = String(trimmed[..<marker.lowerBound])
            if let document = library.documents.first(where: { $0.id == docID }) {
                return PageReference(docID: docID, page: page, title: document.title)
            }
        }
        if let hit = sources.first(where: { "\($0.title), p. \($0.page)" == trimmed }) {
            return PageReference(docID: hit.docID, page: hit.page, title: hit.title)
        }
        return nil
    }

    func pageReference(for hit: ManualHit) -> PageReference {
        PageReference(docID: hit.docID, page: hit.page, title: hit.title)
    }

    // MARK: Wiring

    private func subscribe(to flow: RTSFlow) {
        cancellables.removeAll()

        flow.nodeStatusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.apply(status) }
            .store(in: &cancellables)
    }

    private func apply(_ status: RTSNodeStatus) {
        let state: StepState
        switch status.state {
        case .queued: state = .queued
        case .executing: state = .running
        case .completed: state = .done
        case .failed(let message): state = .failed(message)
        }
        switch status.nodeName {
        case AskAgents.Name.answerer:
            answererState = state
            // Show the sources as soon as the answer is in, before the Verifier finishes.
            if state == .done { sources = collector.hits }
        case AskAgents.Name.verifier:
            verifierState = state
        default:
            break
        }
    }

    private func consume(_ output: RTSOutput) {
        if case let .string(text)? = output[AskWorkflow.OutputKey.answer] {
            if let decoded = try? ManualAnswer.decode(from: text) {
                answer = decoded
            } else {
                undecodedAnswer = text
            }
        }
        if case let .string(text)? = output[AskWorkflow.OutputKey.verification] {
            if let report = try? VerificationReport.decode(from: text) {
                let count = answer?.claims.count ?? 0
                for verdict in report.verdicts where (1...max(count, 1)).contains(verdict.claim) {
                    verdicts[verdict.claim] = verdict
                }
            } else {
                verifierUnreadable = true
            }
        }
    }

    private func reset() {
        errorMessage = nil
        answererState = .idle
        verifierState = .idle
        answer = nil
        undecodedAnswer = nil
        verdicts = [:]
        verifierUnreadable = false
        sources = []
        askedQuestion = nil
        elapsed = nil
        collector.reset()
    }
}
