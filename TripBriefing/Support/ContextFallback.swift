//
//  ContextFallback.swift
//  TripBriefing
//
//  When an on-device agent's prompt outgrows Apple Intelligence's context
//  window (4,096 tokens on iOS 26, 8,192 on 27), FoundationModels throws and the
//  SDK passes the error up unchanged. These helpers retry that one agent on the
//  cloud provider instead of failing the run. Passing on-device failures get the
//  same treatment after a few more tries. Any other error is rethrown as is.
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
        return text.contains("ToolCallError") && text.contains("GeneratedContent") && !isToolCallLimit(error)
    }

    /// Whether `error` is a tool ending an agent's turn because its calls are spent: PlacesSearch
    /// for the Local Guide, SearchTravelGuide for the Concierge, either search in the chat.
    /// FoundationModels wraps the tool's error in a ToolCallError, so the text is checked too.
    static func isToolCallLimit(_ error: Error) -> Bool {
        error is PlacesSearchSession.LimitReached || error is SearchLimitReached
            || "\(error)".contains("ToolCallLimitReached")
    }

    /// Whether `error` is FoundationModels failing to read the model's final answer as the output
    /// schema, for example prose around a fenced JSON block ("Failed to convert text into
    /// GeneratedContent"). Not a tool call, so `isBadToolCall` misses it: there is no
    /// "ToolCallError" in the text. The SDK passes the error up unchanged, so the typed case
    /// matches; the text check is for a wrapped error, as in `isContextOverflow`, or a later error
    /// type (iOS 27's `LanguageModelError` has no decoding case).
    static func isDecodingFailure(_ error: Error) -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *),
           let generationError = error as? LanguageModelSession.GenerationError,
           case .decodingFailure = generationError {
            return true
        }
        #endif
        let text = "\(error)"
        return text.contains("decodingFailure") || text.contains("Failed to convert text into")
    }

    /// Whether `error` is the on-device model refusing a request because the app made too many.
    /// The typed case moved to `LanguageModelError` on iOS 27, so the text covers both.
    static func isRateLimited(_ error: Error) -> Bool {
        "\(error)".contains("rateLimited")
    }

    /// Whether `error` is the on-device model stopping while it generates: `GenerationError` code
    /// -1 around `com.apple.tokengeneration` code 10. Apple does not document it, and it is no
    /// `GenerationError` case. On an iPhone it came right after a tool result, in 2 to 8 seconds.
    static func isTokenGenerationFailure(_ error: Error) -> Bool {
        "\(error)".contains("com.apple.tokengeneration")
    }

    /// Whether `error` is an on-device failure that can pass, so another try can work.
    static func isTransientModelFailure(_ error: Error) -> Bool {
        isRateLimited(error) || isTokenGenerationFailure(error)
    }

    /// What the user reads when a run fails: a plain sentence for the on-device failures that the
    /// tries did not clear, or the error itself.
    static func failureMessage(_ error: Error) -> String {
        if isRateLimited(error) {
            return "Apple's on-device model is busy. Try again in a moment."
        }
        if isTokenGenerationFailure(error) {
            return "Apple's on-device model could not answer. Try again in a moment."
        }
        return "\(error)"
    }

    /// Tries after the first one for an on-device failure that can pass.
    private static let transientRetries = 2

    /// Runs `primary` up to `transientRetries` more times after `failure`, waiting longer for a
    /// rate limit. The last failure is thrown as is.
    private static func retryAfterTransientFailure(
        _ failure: Error,
        primary: () async throws -> String
    ) async throws -> String {
        var failure = failure
        for attempt in 1...transientRetries {
            AppLog.warning("On-device model failed, agent run again", properties: ["Attempt": "\(attempt)", "Error": shortError(failure)])
            try await Task.sleep(for: isRateLimited(failure) ? .seconds(3) : .seconds(0.5))
            do {
                return try await primary()
            } catch where isTransientModelFailure(error) {
                failure = error
            }
        }
        throw failure
    }

    /// Runs `primary`, once more if the model made a tool call or gave a final answer
    /// FoundationModels could not decode. A second failure is thrown as is, never sent to `fallback`.
    /// When it fails because the on-device context is full: with a `fallback`, reports
    /// `onFallback` and runs `fallback` with the same prompt; without one, runs `primary` once
    /// more, because an overflow can also be the model's answer running on (a short prompt that
    /// worked 12 times out of 12 overflowed once), and a second try costs less than a failed run.
    /// After an on-device failure that can pass, runs `primary` again, then goes to `fallback`
    /// if those tries fail too. Without a `fallback`, the last failure is thrown.
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
            } catch where isDecodingFailure(error) {
                AppLog.warning("Answer did not match the output schema, agent run again", properties: ["Error": shortError(error)])
                return try await primary()
            } catch where isTransientModelFailure(error) {
                return try await retryAfterTransientFailure(error, primary: primary)
            }
        } catch where isContextOverflow(error) {
            guard let fallback else {
                AppLog.warning("On-device context full and no cloud fallback, agent run again on-device", properties: ["Error": shortError(error)])
                return try await primary()
            }
            onFallback()
            return try await fallback()
        } catch where isTransientModelFailure(error) {
            guard let fallback else { throw error }
            onFallback()
            return try await fallback()
        }
    }
}

extension RTSRunContext {
    /// `call(_:prompt:)`, run again once after a malformed tool call or an answer that does not
    /// match the output schema, and retried on `fallback`
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
