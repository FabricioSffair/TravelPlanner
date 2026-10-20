//
//  ContextFallback.swift
//  TripBriefing
//
//  When an on-device agent's prompt outgrows Apple Intelligence's context
//  window (4,096 tokens on iOS 26, 8,192 on 27), FoundationModels throws and the
//  SDK passes the error up unchanged. These helpers retry that one agent on the
//  cloud provider instead of failing the run. Any other error is rethrown as is.
//
//  The SDK has no fallback of its own; this is the app-side version of what an
//  `RTSAgent(..., fallback:)` could do inside the gateway.
//

import Foundation
import RailtracksSwift
#if canImport(FoundationModels)
import FoundationModels
#endif

enum ContextFallback {

    /// Whether `error` is the on-device model running out of context. Checks the typed
    /// FoundationModels error first, then the text: the error can arrive wrapped
    /// ("inferenceFailed" around a DecoderModelError), so nested errors are walked too.
    static func isContextOverflow(_ error: Error) -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *),
           let generationError = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = generationError {
            return true
        }
        #endif
        // Two wordings seen: "Content contains 10866 tokens, which exceeds the maximum allowed
        // context size of 8192." (typed, before generating) and "Provided 8,831 tokens, but the
        // maximum allowed is 8,192." (wrapped in inferenceFailed, mid tool loop).
        let text = "\(error)"
        if text.contains("maximum allowed") || text.contains("exceededContextWindowSize") {
            return true
        }
        return (error as NSError).underlyingErrors.contains { isContextOverflow($0) }
    }

    /// The first 300 characters of `error`, enough for the cause without the agent dump.
    static func shortError(_ error: Error) -> String {
        let text = "\(error)"
        if let range = text.range(of: "underlyingError: ") {
            return String(text[range.upperBound...].prefix(300))
        }
        return String(text.prefix(300))
    }

    /// Whether `error` is FoundationModels rejecting a tool call's arguments, for example the
    /// model calling DailyForecast with GeocodePlace's `place` ("GeneratedContent does not
    /// contain a property 'latitude'"). The model picks its arguments afresh on a retry.
    static func isBadToolCall(_ error: Error) -> Bool {
        let text = "\(error)"
        return text.contains("ToolCallError") && text.contains("GeneratedContent")
    }

    /// Runs `primary`, once more if the model made a tool call FoundationModels could not decode.
    /// When it fails because the on-device context is full: with a `fallback`, reports
    /// `onFallback` and runs `fallback` with the same prompt; without one, runs `primary` once
    /// more, because an overflow can also be the model's answer running on (a short prompt that
    /// worked 12 times out of 12 overflowed once), and a second try costs less than a failed run.
    static func run(
        primary: () async throws -> String,
        fallback: (() async throws -> String)?,
        onFallback: () -> Void
    ) async throws -> String {
        do {
            do {
                return try await primary()
            } catch where isBadToolCall(error) {
                AppLog.warning("Malformed tool call, agent run again", properties: ["Error": shortError(error)])
                return try await primary()
            }
        } catch where isContextOverflow(error) {
            guard let fallback else {
                AppLog.warning("On-device context full and no cloud fallback, agent run again on-device", properties: ["Error": shortError(error)])
                return try await primary()
            }
            onFallback()
            return try await fallback()
        }
    }
}

extension RTSRunContext {
    /// `call(_:prompt:)`, run again once after a malformed tool call, and retried on `fallback`
    /// when the on-device context overflows.
    /// - Parameter onFallback: receives the agent's name when the retry starts.
    func call(
        _ agent: RTSAgent,
        fallback: RTSAgent?,
        prompt: String,
        onFallback: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await ContextFallback.run(
            primary: { try await call(agent, prompt: prompt) },
            fallback: fallback.map { fallback in { try await call(fallback, prompt: prompt) } },
            onFallback: { onFallback(agent.agentName) }
        )
    }
}
