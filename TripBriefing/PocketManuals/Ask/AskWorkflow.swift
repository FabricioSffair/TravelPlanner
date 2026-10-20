//
//  AskWorkflow.swift
//  PocketManuals
//
//  The orchestrator node. The Answerer runs first; when it is grounded and
//  answered, the Verifier checks its claims against exactly the passages the
//  search tool returned. Every `context.call` is traced as a child of this node.
//

import Foundation
import RailtracksSwift

struct AskWorkflow: RTSOrchestratorNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let nodeName = AskAgents.Name.workflow

    let answerer: RTSAgent
    /// `nil` when grounding is off: nothing was retrieved, so there is nothing to verify against.
    let verifier: RTSAgent?
    let collector: ManualSourceCollector
    /// The same agents on the cloud provider, rerun when an on-device prompt overflows the
    /// context window. `nil` means no fallback.
    var fallbackAnswerer: RTSAgent?
    var fallbackVerifier: RTSAgent?

    enum InputKey {
        static let question = "question"
    }

    enum OutputKey {
        /// The Answerer's raw JSON (`ManualAnswer`).
        static let answer = "answer"
        /// The Verifier's raw JSON (`VerificationReport`); absent when it did not run.
        static let verification = "verification"
    }

    func run(_ input: RTSInput, context: RTSRunContext) async throws -> RTSOutput {
        guard case let .string(question)? = input[InputKey.question],
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw RTSError.missingInput(InputKey.question)
        }

        let answerJSON = try await context.call(answerer, fallback: fallbackAnswerer, prompt: question, onFallback: { _ in })
        var output: RTSOutput = [OutputKey.answer: .string(answerJSON)]

        guard let verifier,
              let answer = try? ManualAnswer.decode(from: answerJSON),
              !answer.notFound, !answer.claims.isEmpty
        else {
            return output
        }
        let passages = collector.passagesByCitation
        guard !passages.isEmpty else { return output }

        let verification = try await context.call(
            verifier,
            fallback: fallbackVerifier,
            prompt: Self.verifierPrompt(question: question, answer: answer, passages: passages),
            onFallback: { _ in }
        )
        output[OutputKey.verification] = .string(verification)
        return output
    }

    static func verifierPrompt(
        question: String,
        answer: ManualAnswer,
        passages: [(citationKey: String, title: String, page: Int, text: String)]
    ) -> String {
        let claims = answer.claims.enumerated().map { number, claim in
            let cited = claim.citations.isEmpty ? "none" : claim.citations.joined(separator: ", ")
            return "\(number + 1). \(claim.text)\n   cites: \(cited)"
        }.joined(separator: "\n")
        let sources = passages.map { passage in
            "[\(passage.citationKey)] \(passage.title), p. \(passage.page)\n\(passage.text)"
        }.joined(separator: "\n\n")
        return """
        QUESTION:
        \(question)

        CLAIMS:
        \(claims)

        PASSAGES:
        \(sources)
        """
    }
}
