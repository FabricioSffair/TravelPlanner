//
//  AskSchemas.swift
//  PocketManuals
//
//  Structured outputs for the Ask flow. `@RTSSchema` synthesizes `rtsSchema`
//  so the agents return exactly these shapes; `decode(from:)` reads them back.
//

import Foundation
import RailtracksSwift

/// One statement in an answer and the passages it rests on.
@RTSSchema
struct ManualClaim: Codable, Hashable {
    let text: String
    /// `citationKey`s (`<docID>#page-N`) of the passages that support the claim.
    let citations: [String]
}

/// The Answerer's output.
@RTSSchema
struct ManualAnswer: Codable, Hashable {
    let claims: [ManualClaim]
    /// True when the manuals do not cover the question.
    let notFound: Bool
}

/// The Verifier's judgement of one claim.
@RTSSchema
struct ClaimVerdict: Codable, Hashable {
    /// 1-based claim number, as numbered in the Verifier's prompt.
    let claim: Int
    /// "supported", "partial" or "unsupported". The schema macro has no enums, so the prompt
    /// constrains it and ``ClaimVerdict/kind`` reads it leniently.
    let verdict: String
    let note: String
}

/// The Verifier's output.
@RTSSchema
struct VerificationReport: Codable, Hashable {
    let verdicts: [ClaimVerdict]
}

extension ClaimVerdict {
    enum Kind: String {
        case supported, partial, unsupported
    }

    /// `nil` for a value outside the three the prompt allows.
    var kind: Kind? {
        Kind(rawValue: verdict.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
