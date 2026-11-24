//
//  ProviderSettings.swift
//  TripBriefing
//
//  Whether the agents run on-device with Apple Intelligence, on Private Cloud
//  Compute or on a cloud provider, where the keys live, and whether embeddings
//  may use OpenAI.
//

import Foundation
import Observation
import RailtracksSwift
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Where the agents run. Stored as the user's choice; ``ProviderSettings/resolvedAgentEngine`` is
/// what a run uses.
enum AgentEngine: String, CaseIterable, Identifiable {
    case onDevice, privateCloudCompute, cloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: "Apple Intelligence (on device)"
        case .privateCloudCompute: "Private Cloud Compute"
        case .cloud: "Cloud provider"
        }
    }

    /// Whether this build lists the engine. Private Cloud Compute only in the target with the
    /// `com.apple.developer.private-cloud-compute` entitlement: a signed app without it crashes on
    /// its first request.
    var isInThisBuild: Bool {
        self != .privateCloudCompute || ProviderSettings.privateCloudComputeInThisBuild
    }

    /// The Settings picker's rows, in display order.
    static var selectable: [AgentEngine] { allCases.filter(\.isInThisBuild) }
}

/// In display order: the Settings picker and key fields list them as declared. Apple
/// Intelligence and Private Cloud Compute, which need no key, sit above them as agent engines.
enum CloudProvider: String, CaseIterable, Identifiable {
    case anthropic, gemini, openAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .openAI: "OpenAI"
        }
    }

    var kind: RTSLLMProviderKind {
        switch self {
        case .anthropic: .anthropic
        case .gemini: .gemini
        case .openAI: .openAI
        }
    }

    var keychainAccount: String { "apikey.\(rawValue)" }

    /// A fast, inexpensive model per provider; enough for tool calling and JSON output.
    var llmProvider: RTSLLMProvider {
        switch self {
        case .anthropic:
            .anthropic(modelIDString: RTSAnthropicModelID.claudeSonnet46.modelIDString)
        case .gemini:
            .gemini(modelIDString: RTSGeminiModelID.gemini25Flash.modelIDString)
        case .openAI:
            .openAI(modelIDString: RTSOpenAIModelID.gpt4oMini.modelIDString)
        }
    }
}

@MainActor
@Observable
final class ProviderSettings {
    private static let providerDefaultsKey = "cloudProvider"
    private static let onDeviceDefaultsKey = "phrasebookOnDevice"
    private static let groundingDefaultsKey = "groundsTipsInWikivoyage"
    /// Before the engine choice: `true` meant on-device, `false` the cloud provider. Read once,
    /// when `agentEngineDefaultsKey` is not set.
    private static let agentsOnDeviceDefaultsKey = "agentsOnDevice"
    private static let agentEngineDefaultsKey = "agentEngine"
    private static let cloudEmbeddingsDefaultsKey = "allowsCloudEmbeddings"
    private static let contextFallbackDefaultsKey = "fallsBackWhenContextFull"

    var cloudProvider: CloudProvider {
        didSet { UserDefaults.standard.set(cloudProvider.rawValue, forKey: Self.providerDefaultsKey) }
    }

    /// Where the user chose to run every agent. Both app targets share these defaults, so the
    /// choice can be Private Cloud Compute in a build without it: runs read
    /// ``resolvedAgentEngine``, and the choice itself is never rewritten. With Apple Intelligence,
    /// runs refuse to start when the model is unavailable and say why. The one cloud fallback is
    /// ``fallsBackWhenContextFull``, and the call tree shows it. The Sign Translator stays on the
    /// cloud provider, because the on-device model ignores images.
    var agentEngine: AgentEngine {
        didSet { UserDefaults.standard.set(agentEngine.rawValue, forKey: Self.agentEngineDefaultsKey) }
    }

    /// What runs use: the chosen engine, except Private Cloud Compute when this build lacks it or
    /// the system says it is unavailable, which runs on-device instead.
    var resolvedAgentEngine: AgentEngine {
        if agentEngine == .privateCloudCompute && !Self.privateCloudComputeAvailable {
            return .onDevice
        }
        return agentEngine
    }

    /// With on-device or Private Cloud Compute agents: when one agent's prompt outgrows the
    /// model's context window, run that agent again on the cloud provider instead of failing the
    /// run. Needs that provider's key.
    var fallsBackWhenContextFull: Bool {
        didSet { UserDefaults.standard.set(fallsBackWhenContextFull, forKey: Self.contextFallbackDefaultsKey) }
    }

    /// Lets the travel guide and trip indexes embed with OpenAI when Apple's on-device embedding
    /// model is missing. Off by default: without it, nothing is sent to OpenAI for indexing.
    var allowsCloudEmbeddings: Bool {
        didSet { UserDefaults.standard.set(allowsCloudEmbeddings, forKey: Self.cloudEmbeddingsDefaultsKey) }
    }

    /// With cloud or Private Cloud Compute agents, run the phrasebook agent on Apple Intelligence
    /// when the device supports it.
    var phrasebookOnDevice: Bool {
        didSet { UserDefaults.standard.set(phrasebookOnDevice, forKey: Self.onDeviceDefaultsKey) }
    }

    /// Ground the Concierge's practical tips in the destination's Wikivoyage guide (on-device RAG).
    /// Off means the Concierge runs without the guide search, as before.
    var groundsTipsInWikivoyage: Bool {
        didSet { UserDefaults.standard.set(groundsTipsInWikivoyage, forKey: Self.groundingDefaultsKey) }
    }

    /// Mirrors the Keychain so SwiftUI fields can bind to it.
    private(set) var keys: [CloudProvider: String] = [:]

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
        cloudProvider = CloudProvider(rawValue: stored ?? "") ?? .anthropic
        phrasebookOnDevice = UserDefaults.standard.object(forKey: Self.onDeviceDefaultsKey) as? Bool ?? true
        groundsTipsInWikivoyage = UserDefaults.standard.object(forKey: Self.groundingDefaultsKey) as? Bool ?? true
        if let stored = UserDefaults.standard.string(forKey: Self.agentEngineDefaultsKey),
           let engine = AgentEngine(rawValue: stored) {
            agentEngine = engine
        } else {
            let onDevice = UserDefaults.standard.object(forKey: Self.agentsOnDeviceDefaultsKey) as? Bool ?? true
            agentEngine = onDevice ? .onDevice : .cloud
        }
        allowsCloudEmbeddings = UserDefaults.standard.object(forKey: Self.cloudEmbeddingsDefaultsKey) as? Bool ?? false
        fallsBackWhenContextFull = UserDefaults.standard.object(forKey: Self.contextFallbackDefaultsKey) as? Bool ?? true
        for provider in CloudProvider.allCases {
            keys[provider] = KeychainStore.read(provider.keychainAccount) ?? ""
        }
    }

    func setKey(_ value: String, for provider: CloudProvider) {
        keys[provider] = value
        KeychainStore.write(value, account: provider.keychainAccount)
    }

    func key(for provider: CloudProvider) -> String { keys[provider] ?? "" }

    // MARK: Railtown

    private static let railtownLogsAccount = "railtown.logs"
    /// Kept from when one key served both pipelines: that key carries on as the agent runs key.
    private static let conductrAgentRunsAccount = "railtown.conductr"

    /// Key for RailtownLogger: the app's logs and the SDK's error reports. Not a cloud provider:
    /// it never reaches an LLM.
    private(set) var railtownLogsKey: String = KeychainStore.read(ProviderSettings.railtownLogsAccount) ?? ""
    /// Key for ConductrTraceUploader: agent-run traces.
    private(set) var conductrAgentRunsKey: String = KeychainStore.read(ProviderSettings.conductrAgentRunsAccount) ?? ""

    /// Whether RailtownLogger accepted the logs key.
    private(set) var isLoggerConfigured = false
    /// Whether ConductrTraceUploader accepted the agent runs key.
    private(set) var isTraceUploadConfigured = false

    /// Stores the logs key and reconfigures the logger with it right away.
    func setRailtownLogsKey(_ value: String) {
        railtownLogsKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.write(railtownLogsKey, account: Self.railtownLogsAccount)
        isLoggerConfigured = RailtownSetup.configureLogger(apiKey: railtownLogsKey)
    }

    /// Stores the agent runs key and reconfigures trace uploads with it right away.
    func setConductrAgentRunsKey(_ value: String) {
        conductrAgentRunsKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.write(conductrAgentRunsKey, account: Self.conductrAgentRunsAccount)
        isTraceUploadConfigured = RailtownSetup.configureTraceUploads(apiKey: conductrAgentRunsKey)
    }

    /// Configures both pipelines with the stored keys. Called at launch.
    func configureRailtown() {
        isLoggerConfigured = RailtownSetup.configureLogger(apiKey: railtownLogsKey)
        isTraceUploadConfigured = RailtownSetup.configureTraceUploads(apiKey: conductrAgentRunsKey)
    }

    var hasCloudKey: Bool { !key(for: cloudProvider).isEmpty }

    /// One gateway per run, holding every key that is set. Sub-agents may use a
    /// different provider than their parent, so all keys travel together.
    func makeGateway() -> RTSLLMGateway {
        var apiKeys: [RTSLLMProviderKind: String] = [:]
        for provider in CloudProvider.allCases where !key(for: provider).isEmpty {
            apiKeys[provider.kind] = key(for: provider)
        }
        return RTSLLMGateway(apiKeys: apiKeys)
    }

    var cloudLLMProvider: RTSLLMProvider { cloudProvider.llmProvider }

    /// The provider for every agent except the Sign Translator.
    var agentLLMProvider: RTSLLMProvider { llmProvider(for: resolvedAgentEngine) }

    /// The provider an on-device or Private Cloud Compute agent is retried on when its context
    /// overflows, or `nil` when there is no fallback: cloud agents, the switch off, or no key for
    /// the cloud provider.
    var contextFallbackProvider: RTSLLMProvider? {
        (resolvedAgentEngine != .cloud && fallsBackWhenContextFull && hasCloudKey) ? cloudLLMProvider : nil
    }

    /// "Apple Intelligence", "Private Cloud Compute" or the cloud provider's name.
    var agentProviderTitle: String {
        switch resolvedAgentEngine {
        case .onDevice: "Apple Intelligence"
        case .privateCloudCompute: "Private Cloud Compute"
        case .cloud: cloudProvider.title
        }
    }

    /// Why the agents cannot run right now, or `nil` when they can.
    var agentsUnavailableReason: String? {
        switch resolvedAgentEngine {
        case .onDevice:
            return Self.onDeviceAvailable ? nil : Self.onDeviceStatusText
        case .privateCloudCompute:
            return nil
        case .cloud:
            return hasCloudKey ? nil : "Add a \(cloudProvider.title) API key in Settings first."
        }
    }

    /// The provider the phrasebook agent should use: on-device with on-device agents, or when
    /// allowed and available; otherwise the same provider as the other agents.
    var phrasebookLLMProvider: RTSLLMProvider {
        let engine = resolvedAgentEngine
        if engine == .onDevice { return .appleAI }
        return (phrasebookOnDevice && Self.onDeviceAvailable) ? .appleAI : llmProvider(for: engine)
    }

    /// The one place a Private Cloud Compute provider is built, and only in the target with the
    /// entitlement. `resolvedAgentEngine` never returns `.privateCloudCompute` in the other one.
    private func llmProvider(for engine: AgentEngine) -> RTSLLMProvider {
        switch engine {
        case .onDevice:
            return .appleAI
        case .privateCloudCompute:
            #if PRIVATE_CLOUD_COMPUTE
            return .privateCloudCompute()
            #else
            return .appleAI
            #endif
        case .cloud:
            return cloudLLMProvider
        }
    }

    /// The OpenAI key the indexes may embed with, or `nil` when cloud embeddings are off or no
    /// key is set.
    var embeddingOpenAIKey: String? {
        let key = key(for: .openAI)
        return (allowsCloudEmbeddings && !key.isEmpty) ? key : nil
    }

    static var onDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static var onDeviceStatusText: String {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "Apple Intelligence is available on this device."
            case .unavailable(let reason):
                return "Apple Intelligence unavailable: \(reason)."
            }
        }
        #endif
        return "Apple Intelligence needs iOS 26 or macOS 26."
    }

    /// Whether this build can reach Private Cloud Compute: the target with the entitlement, built
    /// with the OS 27 SDK.
    nonisolated static var privateCloudComputeInThisBuild: Bool {
        #if PRIVATE_CLOUD_COMPUTE && compiler(>=6.4)
        return true
        #else
        return false
        #endif
    }

    /// Whether the agents can run on Private Cloud Compute now. Reads the system's status only;
    /// it makes no request and spends none of the daily limit.
    static var privateCloudComputeAvailable: Bool {
        // XCODE26-SDK: `PrivateCloudComputeLanguageModel` exists only in the OS 27 SDK (Swift 6.4).
        #if PRIVATE_CLOUD_COMPUTE && compiler(>=6.4)
        if #available(iOS 27, macOS 27, *) {
            return PrivateCloudComputeLanguageModel().availability == .available
        }
        #endif
        return false
    }

    static var privateCloudComputeStatusText: String {
        #if PRIVATE_CLOUD_COMPUTE && compiler(>=6.4)
        if #available(iOS 27, macOS 27, *) {
            switch PrivateCloudComputeLanguageModel().availability {
            case .available:
                return "Private Cloud Compute is available on this device."
            case .unavailable(.deviceNotEligible):
                return "Private Cloud Compute unavailable: this device is not eligible."
            case .unavailable(.systemNotReady):
                return "Private Cloud Compute unavailable: the system is not ready yet."
            case .unavailable(let reason):
                return "Private Cloud Compute unavailable: \(reason)."
            }
        }
        return "Private Cloud Compute needs iOS 27 or macOS 27."
        #else
        return "Private Cloud Compute is not part of this build."
        #endif
    }
}
