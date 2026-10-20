//
//  AskAgents.swift
//  PocketManuals
//
//  The Answerer and the Verifier. Names are what shows up in the call tree,
//  the JSON trace and the Instruments Agent Runs lane.
//

import Foundation
import RailtracksSwift

enum AskAgents {

    enum Name {
        static let workflow = "Ask Manuals"
        static let answerer = "Answerer"
        static let verifier = "Verifier"
    }

    /// Grounded: answers only from `searchTool`'s results and cites them.
    static func groundedAnswerer(cloud: RTSLLMProvider, searchTool: RTSKnowledgeSearchTool) -> RTSAgent {
        RTSAgent(
            llmProvider: cloud,
            name: Name.answerer,
            tools: [searchTool],
            systemMessage: """
            You answer questions using only the user's manuals. Always call \(searchTool.toolName) \
            before answering, asking for about 6 passages; search again with other wording, or once \
            per part of the question, when the results do not settle it. The question may need \
            more than one manual.

            Answer only from the search results, never from your own knowledge. Write the answer as \
            a few short claims, each one fact or instruction. Every claim cites the passages it \
            comes from in `citations`, using the exact `metadata.citationKey` values from the \
            results (they look like "<id>#page-<n>"), never titles or page numbers. Keep concrete \
            numbers and units exactly as the manual states them.

            If the results do not answer the question, set `notFound` to true and give at most one \
            claim saying plainly that the manuals do not cover it, with no citations. Do not guess.
            """,
            outputSchema: ManualAnswer.rtsSchema
        )
    }

    /// Ungrounded, for comparison: the same output shape from the model's own knowledge.
    static func ungroundedAnswerer(cloud: RTSLLMProvider) -> RTSAgent {
        RTSAgent(
            llmProvider: cloud,
            name: Name.answerer,
            systemMessage: """
            Answer the user's question from your own knowledge. Write the answer as a few short \
            claims, each one fact or instruction. You have no sources, so leave `citations` empty. \
            Set `notFound` to true only if you cannot answer at all.
            """,
            outputSchema: ManualAnswer.rtsSchema
        )
    }

    /// Checks each claim against the passages it was given. No tools.
    static func verifier(cloud: RTSLLMProvider) -> RTSAgent {
        RTSAgent(
            llmProvider: cloud,
            name: Name.verifier,
            systemMessage: """
            You check an answer against source passages. You receive numbered claims, each with \
            the citation keys it cites, and the passages retrieved for the answer, each under its \
            citation key. For every claim return one verdict, with `claim` set to its number:
            - "supported": the passages it cites state it, including any numbers and units.
            - "partial": the passages support part of it, or support it only loosely, or the \
            support is in a passage it did not cite.
            - "unsupported": no passage supports it, or the passages contradict it.
            `verdict` must be exactly one of those three words. `note` is one short sentence saying \
            why. Judge only from the passages, not from your own knowledge.
            """,
            outputSchema: VerificationReport.rtsSchema
        )
    }
}
