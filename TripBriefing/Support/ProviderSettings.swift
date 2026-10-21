//
//  ProviderSettings.swift
//  TripBriefing
//
//  Whether the agents run on-device with Apple Intelligence or on a cloud
//  provider, where the keys live, and whether embeddings may use OpenAI.
//

import Foundation
import Observation
import RailtracksSwift
#if canImport(FoundationModels)
import FoundationModels
#endif

/// In display order: the Settings picker and key fields list them as declared. Apple
/// Intelligence, which needs no key, sits above them as its own switch.
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
    private static let agentsOnDeviceDefaultsKey = "agentsOnDevice"
    private static let cloudEmbeddingsDefaultsKey = "allowsCloudEmbeddings"
    private static let contextFallbackDefaultsKey = "fallsBackWhenContextFull"

    var cloudProvider: CloudProvider {
        didSet { UserDefaults.standard.set(cloudProvider.rawValue, forKey: Self.providerDefaultsKey) }
    }

    /// Run every agent on Apple Intelligence. When the model is unavailable, runs refuse to start
    /// and say why. The one cloud fallback is ``fallsBackWhenContextFull``, and the call tree
    /// shows it. The Sign Translator stays on the cloud provider, because the on-device model
    /// ignores images.
    var agentsOnDevice: Bool {
        didSet { UserDefaults.standard.set(agentsOnDevice, forKey: Self.agentsOnDeviceDefaultsKey) }
    }

    /// With on-device agents: when one agent's prompt outgrows the on-device context window, run
    /// that agent again on the cloud provider instead of failing the run. Needs that provider's key.
    var fallsBackWhenContextFull: Bool {
        didSet { UserDefaults.standard.set(fallsBackWhenContextFull, forKey: Self.contextFallbackDefaultsKey) }
    }

    /// Lets the travel guide and trip indexes embed with OpenAI when Apple's on-device embedding
    /// model is missing. Off by default: without it, nothing is sent to OpenAI for indexing.
    var allowsCloudEmbeddings: Bool {
        didSet { UserDefaults.standard.set(allowsCloudEmbeddings, forKey: Self.cloudEmbeddingsDefaultsKey) }
    }

    /// With cloud agents, run the phrasebook agent on Apple Intelligence when the device supports it.
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
        agentsOnDevice = UserDefaults.standard.object(forKey: Self.agentsOnDeviceDefaultsKey) as? Bool ?? true
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
    var agentLLMProvider: RTSLLMProvider { agentsOnDevice ? .appleAI : cloudLLMProvider }

    /// The provider an on-device agent is retried on when its context overflows, or `nil` when
    /// there is no fallback: cloud agents, the switch off, or no key for the cloud provider.
    var contextFallbackProvider: RTSLLMProvider? {
        (agentsOnDevice && fallsBackWhenContextFull && hasCloudKey) ? cloudLLMProvider : nil
    }

    /// "Apple Intelligence" or the cloud provider's name.
    var agentProviderTitle: String { agentsOnDevice ? "Apple Intelligence" : cloudProvider.title }

    /// Why the agents cannot run right now, or `nil` when they can.
    var agentsUnavailableReason: String? {
        if agentsOnDevice {
            return Self.onDeviceAvailable ? nil : Self.onDeviceStatusText
        }
        return hasCloudKey ? nil : "Add a \(cloudProvider.title) API key in Settings first."
    }

    /// The provider the phrasebook agent should use: on-device with on-device agents, or when
    /// allowed and available; otherwise the same cloud provider as everything else.
    var phrasebookLLMProvider: RTSLLMProvider {
        if agentsOnDevice { return .appleAI }
        return (phrasebookOnDevice && Self.onDeviceAvailable) ? .appleAI : cloudLLMProvider
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
}
