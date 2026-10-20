//
//  PlanView.swift
//  TripBriefing
//
//  Trip form, live per-agent progress, the briefing, the phrasebook, the
//  call tree, and a share button for the JSON trace.
//

import SwiftUI
import RailtracksSwiftUI

struct PlanView: View {
    @Environment(ProviderSettings.self) private var settings
    @Bindable var model: TripPlannerViewModel

    var body: some View {
        NavigationStack {
            Form {
                tripSection
                runSection
                progressSection
                // Sections appear as their agent finishes, and show the streamed text before that.
                if let weather = model.weatherReport {
                    WeatherView(report: weather)
                } else {
                    liveTextSection("Weather", agent: TripAgents.Name.weather)
                }
                if let itinerary = model.itinerary {
                    ItineraryView(itinerary: itinerary)
                } else {
                    liveTextSection("Itinerary", agent: TripAgents.Name.itinerary)
                }
                if let book = model.phraseBook {
                    PhraseBookView(book: book)
                } else {
                    liveTextSection("Phrasebook", agent: TripAgents.Name.phrasebook)
                }
                if let report = model.report {
                    BriefingView(report: report, guideSources: model.guideSources, guideArticleURL: model.guideArticleURL)
                } else {
                    liveTextSection("Briefing", agent: TripAgents.Name.concierge)
                }
                askSection
                callTreeSection
                traceSection
            }
            .groupedFormOnMac()
            .navigationTitle("Travel Assistant")
            .task {
                if settings.groundsTipsInWikivoyage { model.warmUpGuide() }
            }
        }
    }

    // MARK: Sections

    private var tripSection: some View {
        Section("Trip") {
            TextField("Destination", text: $model.request.destination)
                .capitalizesWords()
            DatePicker("From", selection: $model.request.startDate, displayedComponents: .date)
            DatePicker("To", selection: $model.request.endDate, in: model.request.startDate..., displayedComponents: .date)
            TextField("I speak…", text: $model.request.homeLanguage)
            TextField("Notes for the guide", text: $model.request.notes, axis: .vertical)
                .lineLimit(2...4)
        }
    }

    private var runSection: some View {
        Section {
            Button {
                model.run(settings: settings)
            } label: {
                HStack {
                    if model.isRunning { ProgressView().padding(.trailing, 6) }
                    Text(model.isRunning ? "Briefing in progress…" : "Build my briefing")
                        .fontWeight(.semibold)
                    Spacer()
                    Text(settings.agentProviderTitle)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .primaryActionOnMac()
            .disabled(model.isRunning || model.isPreparingGuide || settings.agentsUnavailableReason != nil)

            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
            if let elapsed = model.elapsed {
                Text("Finished in \(elapsed, format: .number.precision(.fractionLength(1))) s")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text(settings.groundsTipsInWikivoyage
                 ? "Three agents start together while the Wikivoyage guide is indexed; the Concierge runs when all three finish, calls the Packing List agent as a tool and searches the guide for its tips."
                 : "Three agents start together; the Concierge runs when all three finish and calls the Packing List agent as a tool.")
        }
    }

    private var progressSection: some View {
        Section("Agents") {
            ForEach(model.tracks) { track in
                TrackRow(track: track)
            }
        }
    }

    /// Shown in place of an agent's own section: a "writing" row while the agent runs, and its
    /// raw text if it finished but the text did not decode. Nothing before the agent starts.
    @ViewBuilder
    private func liveTextSection(_ title: String, agent: String) -> some View {
        let text = model.sectionText(for: agent)
        if model.isWriting(agent) {
            Section(title) {
                HStack(spacing: .spacingMD) {
                    ProgressView().controlSize(.small)
                    Text("Writing the \(title.lowercased())…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else if !text.isEmpty {
            Section(title) {
                Text(text)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        }
    }

    /// Where the briefing's index stands, pointing to the Chat tab that searches it. Shown once
    /// indexing has started.
    @ViewBuilder
    private var askSection: some View {
        if let status = model.tripNotesStatus {
            Section {
                Label(status, systemImage: "bubble.left.and.text.bubble.right")
                    .font(.callout)
            } header: {
                Text("Chat about this trip")
            } footer: {
                Text("Open Chat to ask about this briefing. The Trip Assistant searches it and the Wikivoyage guide, then answers from what it finds.")
            }
        }
    }

    private var callTreeSection: some View {
        Section("Call tree") {
            CallTreeView(viewModel: model.nodeTree, agentModels: model.agentModels)
                .frame(minHeight: 220, maxHeight: 320)
                .listRowInsets(EdgeInsets())
        }
    }

    private var traceSection: some View {
        Section("Trace") {
            if let url = model.traceURL {
                ShareLink(item: url) {
                    Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                        .lineLimit(1).truncationMode(.middle)
                }
                Text("Open in JSONTools or the visualizer to replay this run.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("The JSON trace appears here after a run.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Rows

private struct TrackRow: View {
    let track: TrackState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: track.systemImage)
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                Text(track.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            statusView
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch track.status {
        case .idle:
            Image(systemName: "circle").foregroundStyle(.quaternary)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                .help(message)
        }
    }
}
