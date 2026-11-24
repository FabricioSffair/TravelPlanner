//
//  SettingsView.swift
//  TripBriefing
//

import SwiftUI

/// The provider and keys, then Travel Assistant's own options.
struct SettingsView: View {
    @Environment(ProviderSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker("Run agents on", selection: engineSelection) {
                        ForEach(AgentEngine.selectable) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    Toggle("Fall back to \(settings.cloudProvider.title) when the context is full", isOn: $settings.fallsBackWhenContextFull)
                        .disabled(engineSelection.wrappedValue == .cloud)
                } footer: {
                    Text(agentsFooter)
                }

                Section {
                    Picker("Cloud provider", selection: $settings.cloudProvider) {
                        ForEach(CloudProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                } footer: {
                    Text(cloudFooter)
                }

                Section("API keys") {
                    ForEach(CloudProvider.allCases) { provider in
                        KeyField(provider: provider)
                    }
                }

                Section {
                    RailtownKeyField(
                        title: "Logs",
                        stored: settings.railtownLogsKey,
                        isAccepted: settings.isLoggerConfigured,
                        save: settings.setRailtownLogsKey
                    )
                    RailtownKeyField(
                        title: "Agent runs",
                        stored: settings.conductrAgentRunsKey,
                        isAccepted: settings.isTraceUploadConfigured,
                        save: settings.setConductrAgentRunsKey
                    )
                } header: {
                    Text("Railtown")
                } footer: {
                    Text(railtownFooter)
                }

                Section {
                    Toggle("Allow OpenAI embeddings", isOn: $settings.allowsCloudEmbeddings)
                } footer: {
                    Text("The travel guide and trip indexes use Apple's on-device embedding model. On: when that model is missing, they embed with OpenAI instead, which sends the indexed text to OpenAI and needs an OpenAI key. Off: indexing never leaves the device, and search is unavailable without the on-device model.")
                }

                TripBriefingSettingsSections()
            }
            .groupedFormOnMac()
            .navigationTitle("Settings")
        }
    }

    /// The stored engine, or on-device when this build does not list it: Private Cloud Compute
    /// chosen in the other app target, which shares these settings. Reading never rewrites it.
    private var engineSelection: Binding<AgentEngine> {
        Binding(
            get: { settings.agentEngine.isInThisBuild ? settings.agentEngine : .onDevice },
            set: { settings.agentEngine = $0 }
        )
    }

    private var agentsFooter: String {
        switch engineSelection.wrappedValue {
        case .cloud:
            return "Every agent runs on the cloud provider below. \(ProviderSettings.onDeviceStatusText)"
        case .onDevice:
            return "Every agent runs on-device. The Sign Translator still uses the cloud provider, because the on-device model ignores images. \(ProviderSettings.onDeviceStatusText)"
                + (ProviderSettings.onDeviceAvailable ? "" : " Runs cannot start until it is available.")
                + " " + fallbackNote(context: "on-device")
        case .privateCloudCompute:
            let status = ProviderSettings.privateCloudComputeStatusText
            let unavailable = ProviderSettings.privateCloudComputeAvailable
                ? ""
                : " Until it is available, the agents run on-device with Apple Intelligence."
            return "The agents run on Apple's Private Cloud Compute; the phrasebook can stay on-device (below). It needs a network connection, and each request counts against your daily Private Cloud Compute limit. The Sign Translator still uses the cloud provider. \(status)\(unavailable) "
                + fallbackNote(context: "Private Cloud Compute")
        }
    }

    /// What the fallback switch does, and whether it can act right now.
    /// - Parameter context: whose context window fills, "on-device" or "Private Cloud Compute".
    private func fallbackNote(context: String) -> String {
        guard settings.fallsBackWhenContextFull else {
            return "Cloud fallback is off: an agent whose prompt outgrows the \(context) context window fails the run."
        }
        let provider = settings.cloudProvider.title
        return settings.hasCloudKey
            ? "When one agent's prompt outgrows the \(context) context window, that agent alone reruns on \(provider), and the call tree shows it."
            : "Cloud fallback needs a \(provider) API key; without one, an agent whose prompt outgrows the \(context) context window fails the run."
    }

    private var railtownFooter: String {
        func state(_ key: String, _ accepted: Bool) -> String {
            accepted ? "on" : (key.isEmpty ? "off, no key" : "off, key not accepted")
        }
        return "Logs: the app's logs, and the errors RailtracksSwift reports when a run fails (railtown-swift-logger). Agent runs: each run's agent trace, prompts and tool results included, uploaded to Conductr. Logs are \(state(settings.railtownLogsKey, settings.isLoggerConfigured)); agent runs are \(state(settings.conductrAgentRunsKey, settings.isTraceUploadConfigured))."
    }

    private var cloudFooter: String {
        settings.resolvedAgentEngine == .cloud
            ? "Used by Weather Scout, Local Guide, Concierge, Packing List and the translator."
            : "Used by the Sign Translator."
    }
}

/// Travel Assistant's own options.
private struct TripBriefingSettingsSections: View {
    @Environment(ProviderSettings.self) private var settings
    /// For Prepare travel guide: the destination and the guide library live with the planner.
    @Environment(TripPlannerViewModel.self) private var planner

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Phrasebook on-device", isOn: $settings.phrasebookOnDevice)
                .disabled(!ProviderSettings.onDeviceAvailable || settings.resolvedAgentEngine == .onDevice)
        } footer: {
            switch settings.resolvedAgentEngine {
            case .onDevice:
                Text("The phrasebook runs on-device with the other agents.")
            case .privateCloudCompute:
                Text(ProviderSettings.onDeviceStatusText + (ProviderSettings.onDeviceAvailable ? " On: one Private Cloud Compute request less per briefing." : " The phrasebook runs on Private Cloud Compute."))
            case .cloud:
                Text(ProviderSettings.onDeviceStatusText + (ProviderSettings.onDeviceAvailable ? "" : " The phrasebook falls back to the cloud provider."))
            }
        }

        Section {
            Toggle("Ground tips in Wikivoyage", isOn: $settings.groundsTipsInWikivoyage)
            Button {
                planner.prepareGuide(settings: settings)
            } label: {
                HStack {
                    Text("Prepare travel guide")
                    Spacer()
                    if planner.isPreparingGuide { ProgressView() }
                }
            }
            .disabled(planner.isPreparingGuide || planner.isRunning || !planner.request.hasDestination)
            if let status = planner.guidePreparationStatus {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } footer: {
            Text("On: the destination's Wikivoyage guide is indexed while the first agents run, and the Concierge searches it before writing the practical tips. Off: the Concierge writes tips from the model alone. Useful for comparing the two. Embeddings run on-device when Apple's model is on this device, otherwise with OpenAI only when Allow OpenAI embeddings is on. Prepare travel guide indexes \(planner.request.destination) now, without running any agent.")
        }

        Section("Instruments") {
            Text("Profile this app with the Railtracks Instrumentation template to see the three parallel agent bars, the nested Packing List agent, and the tool I/O rows.")
                .font(.footnote)
        }
    }
}

private struct KeyField: View {
    @Environment(ProviderSettings.self) private var settings
    let provider: CloudProvider
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(provider.title).frame(width: 90, alignment: .leading)
            SecureField("paste key", text: $draft)
                .focused($focused)
                .neverCapitalizes()
                .autocorrectionDisabled()
                .onSubmit { settings.setKey(draft, for: provider) }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { settings.setKey(draft, for: provider) }
                }
            if !settings.key(for: provider).isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .onAppear { draft = settings.key(for: provider) }
    }
}

/// One Railtown key: saved to the Keychain on submit or when the field loses focus, which
/// reconfigures its pipeline right away. A checkmark when accepted, a warning when not.
private struct RailtownKeyField: View {
    let title: String
    let stored: String
    let isAccepted: Bool
    let save: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            SecureField("paste key", text: $draft)
                .focused($focused)
                .neverCapitalizes()
                .autocorrectionDisabled()
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
            if isAccepted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if !stored.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .onAppear { draft = stored }
    }

    private func commit() {
        guard draft != stored else { return }
        save(draft)
    }
}
