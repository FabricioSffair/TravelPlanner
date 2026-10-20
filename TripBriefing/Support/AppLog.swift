//
//  AppLog.swift
//  TripBriefing
//
//  The app's own events, sent to Railtown Conductr through RailtownLogger and
//  printed through swift-log. Uploads are a no-op until a Conductr key is set.
//
//  What gets logged: run outcomes and timings, fallbacks, retries, repairs and
//  indexing problems, with agent names, providers and error text. What does not:
//  prompts, retrieved passages, chat messages and the traveler's notes. (Agent
//  traces, which do hold prompts, are a separate upload; see RailtownSetup.)
//
//  The call site is forwarded, so Conductr shows where the event was logged,
//  not this file. Messages are interpolated literals, as RailtownMessage expects.
//

import Foundation
import Logging
import RailtownLogger

enum AppLog {
    private static let local = Logger(label: "io.railtown.TripBriefing")

    static func info(
        _ message: String,
        properties: [String: String] = [:],
        file: String = #fileID, function: String = #function, line: Int = #line
    ) {
        local.info("\(message) \(properties)")
        RailtownLogger.log("\(message)", level: .information, properties: properties, file: file, function: function, line: line)
    }

    static func warning(
        _ message: String,
        properties: [String: String] = [:],
        file: String = #fileID, function: String = #function, line: Int = #line
    ) {
        local.warning("\(message) \(properties)")
        RailtownLogger.log("\(message)", level: .warning, properties: properties, file: file, function: function, line: line)
    }

    /// Uploads `error` with its stack trace. `source: app` tells it apart from the copy the SDK
    /// uploads by itself when the same error escapes `flow.run`.
    static func error(
        _ error: any Error,
        message: String,
        properties: [String: String] = [:],
        file: String = #fileID, function: String = #function, line: Int = #line
    ) {
        local.error("\(message): \(error) \(properties)")
        RailtownLogger.capture(
            error,
            message: "\(message)",
            properties: properties.merging(["Source": "app"]) { current, _ in current },
            file: file, function: function, line: line
        )
    }
}
