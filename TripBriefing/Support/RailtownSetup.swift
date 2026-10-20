//
//  RailtownSetup.swift
//  TripBriefing
//
//  Connects the app to Railtown through the railtown-swift-logger package, as two
//  pipelines with their own keys:
//
//  - RailtownLogger (logs key): error and message uploads. Once configured,
//    RailtracksSwift also reports any error escaping `flow.run` on its own
//    (`capturesRailtracksErrors`, on by default), and the app's `AppLog` calls go
//    through it.
//  - ConductrTraceUploader (agent runs key): each run's JSON agent trace, uploaded to
//    Conductr when the flow writes it.
//
//  Each is called at launch and whenever its key changes.
//

import Foundation
import Combine
import Logging
import RailtownLogger
import RailtracksSwift

enum RailtownSetup {
    /// Conductr host for trace uploads; the SDK adds the path. The test environment, as in the
    /// Whiteboard app.
    static let conductrHost = "testcndr.railtown.ai"

    private static let log = Logger(label: "io.railtown.TripBriefing.railtown")

    /// Configures error and message uploads with the logs key. Returns whether it was accepted.
    /// A missing or malformed key leaves uploads off; it never stops the app.
    @discardableResult
    static func configureLogger(apiKey: String) -> Bool {
        guard !apiKey.isEmpty else {
            log.info("No Railtown logs key: error and message uploads are off")
            return false
        }
        do {
            try RailtownLogger.configure(
                apiKey: apiKey,
                // Its diagnostics (batches uploaded, entries dropped) print to stdout, which is
                // how to see that uploads work.
                options: RailtownOptions(isInternalLoggingEnabled: true)
            )
            AppLog.info("Railtown logger configured")
            return true
        } catch {
            log.warning("Railtown logs key rejected, error and message uploads stay off: \(error)")
            return false
        }
    }

    /// Configures agent-run trace uploads with the agent runs key. Returns whether it was
    /// accepted.
    @discardableResult
    static func configureTraceUploads(apiKey: String) -> Bool {
        guard !apiKey.isEmpty else {
            log.info("No Conductr agent runs key: trace uploads are off")
            return false
        }
        do {
            try ConductrTraceUploader.shared.configure(
                apiKey: apiKey,
                apiBaseURL: conductrHost,
                isInternalLoggingEnabled: true
            )
            AppLog.info("Conductr trace uploads configured", properties: ["Host": conductrHost])
            return true
        } catch {
            log.warning("Conductr agent runs key rejected, trace uploads stay off: \(error)")
            return false
        }
    }

    /// Uploads `flow`'s agent trace when it is written. Call before `flow.run`, and pass the
    /// token to `finishTraceUpload` in a `defer` around the run: a run that never writes a trace
    /// never emits, and only that call releases the subscription. `nil` when not configured.
    static func uploadTrace(of flow: RTSFlow) -> UUID? {
        ConductrTraceUploader.shared.subscribe(to: flow.outputFileURLPublisher)
    }

    static func finishTraceUpload(_ token: UUID?) {
        ConductrTraceUploader.shared.cancelSubscription(token)
    }
}
