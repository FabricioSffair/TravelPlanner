//
//  SettingsView.swift
//  TripBriefing
//

import SwiftUI

/// One Settings tab for both showcases: the showcase switch, the shared provider and keys, then
/// the current showcase's own options.
struct SettingsView: View {
    @Environment(ShowcaseSelection.self) private var showcase
    @Environment(ProviderSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker("Showcase", selection: showcaseBinding) {
                        ForEach(Showcase.allCases) { item in
                            Label(item.title, systemImage: item.systemImage).tag(item)
                        }
                    }
                } header: {
                    Text("Showcase")
                } footer: {
                    Text("Switches the demo right away. The provider and API keys below are shared by both.")
                }

                Section {
                    Toggle("Run agents on Apple Intelligence", isOn: $settings.agentsOnDevice)
                    Toggle("Fall back to \(settings.cloudProvider.title) when the context is full", isOn: $settings.fallsBackWhenContextFull)
                        .disabled(!settings.agentsOnDevice)
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
                    Text("Search indexes use Apple's on-device embedding model. On: when that model is missing, they embed with OpenAI instead, which sends the indexed text to OpenAI and needs an OpenAI key. Off: indexing never leaves the device, and search is unavailable without the on-device model.")
                }

                switch currentShowcase {
                case .tripBriefing:
                    TripBriefingSettingsSections()
                case .pocketManuals:
                    ManualsSettingsSection()
                }
            }
            .groupedFormOnMac()
            .navigationTitle("Settings")
        }
    }

    private var currentShowcase: Showcase { showcase.selected ?? .tripBriefing }

    private var agentsFooter: String {
        let status = ProviderSettings.onDeviceStatusText
        guard settings.agentsOnDevice else {
            return "Off: the agents run on the cloud provider below. \(status)"
        }
        let available = ProviderSettings.onDeviceAvailable
        switch currentShowcase {
        case .tripBriefing:
            return "On: every agent runs on-device. The Sign Translator still uses the cloud provider, because the on-device model ignores images. \(status)"
                + (available ? "" : " Runs cannot start until it is available.")
                + " " + fallbackNote
        case .pocketManuals:
            return "On: the Answerer and the Verifier run on-device. \(status)"
                + (available ? "" : " Questions cannot run until it is available.")
                + " " + fallbackNote
        }
    }

    /// What the fallback switch does, and whether it can act right now.
    private var fallbackNote: String {
        guard settings.fallsBackWhenContextFull else {
            return "Cloud fallback is off: an agent whose prompt outgrows the on-device context window fails the run."
        }
        let provider = settings.cloudProvider.title
        return settings.hasCloudKey
            ? "When one agent's prompt outgrows the on-device context window, that agent alone reruns on \(provider), and the call tree shows it."
            : "Cloud fallback needs a \(provider) API key; without one, an agent whose prompt outgrows the on-device context window fails the run."
    }

    private var railtownFooter: String {
        func state(_ key: String, _ accepted: Bool) -> String {
            accepted ? "on" : (key.isEmpty ? "off, no key" : "off, key not accepted")
        }
        return "Logs: the app's logs, and the errors RailtracksSwift reports when a run fails (railtown-swift-logger). Agent runs: each run's agent trace, prompts and tool results included, uploaded to Conductr. Logs are \(state(settings.railtownLogsKey, settings.isLoggerConfigured)); agent runs are \(state(settings.conductrAgentRunsKey, settings.isTraceUploadConfigured))."
    }

    private var cloudFooter: String {
        switch currentShowcase {
        case .tripBriefing:
            settings.agentsOnDevice
                ? "Used by the Sign Translator."
                : "Used by Weather Scout, Local Guide, Concierge, Packing List and the translator."
        case .pocketManuals:
            settings.agentsOnDevice
                ? "Not used while the agents run on Apple Intelligence."
                : "The provider that answers questions about your manuals."
        }
    }

    /// Switches the root right away; the picker never offers "none".
    private var showcaseBinding: Binding<Showcase> {
        Binding(
            get: { currentShowcase },
            set: { showcase.selected = $0 }
        )
    }
}

/// Travel Assistant's own options, unchanged from its standalone Settings.
private struct TripBriefingSettingsSections: View {
    @Environment(ProviderSettings.self) private var settings
    /// For Prepare travel guide: the destination and the guide library live with the planner.
    @Environment(TripPlannerViewModel.self) private var planner

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Phrasebook on-device", isOn: $settings.phrasebookOnDevice)
                .disabled(!ProviderSettings.onDeviceAvailable || settings.agentsOnDevice)
        } footer: {
            if settings.agentsOnDevice {
                Text("The phrasebook runs on-device with the other agents.")
            } else {
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
            .disabled(planner.isPreparingGuide || planner.isRunning)
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
