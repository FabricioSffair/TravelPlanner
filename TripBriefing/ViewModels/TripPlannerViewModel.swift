//
//  TripPlannerViewModel.swift
//  TripBriefing
//
//  Owns the per-run flow. A fresh RTSFlow is built for every run, so the view
//  model owns the call-tree model and the subscriptions, and attaches before
//  running because nodeStatusPublisher has no replay.
//

import Foundation
import Combine
import Observation
import RailtracksSwift
import RailtracksSwiftUI
import RailtracksSwiftRAG

enum TrackStatus: Equatable {
    case idle, queued, running, done, failed(String)
}

struct TrackState: Identifiable, Equatable {
    let id: String          // agent name, matched against RTSNodeStatus.nodeName
    let title: String
    var detail: String
    let systemImage: String
    var status: TrackStatus = .idle
}

@MainActor
@Observable
final class TripPlannerViewModel {

    var request = TripRequest.sample
    var isRunning = false
    var errorMessage: String?

    var tracks: [TrackState] = TripPlannerViewModel.freshTracks()

    var report: TripBriefingReport?
    var phraseBook: PhraseBook?
    var weatherReport: WeatherReport?
    var itinerary: Itinerary?
    var rawBriefing = ""
    var rawWeather = ""
    var rawItinerary = ""
    var rawPhrasebook = ""
    var traceURL: URL?
    var elapsed: TimeInterval?
    /// The model behind each agent, by agent name, for the call tree.
    var agentModels: [String: String] = [:]

    /// Wikivoyage sections the Concierge's guide searches returned, `Wikivoyage › City › Section`.
    var guideSources: [String] = []
    /// The article the guide was built from, when this run had one.
    var guideArticleURL: URL?

    /// Settings ▸ Prepare travel guide: running, and the last result.
    var isPreparingGuide = false
    var guidePreparationStatus: String?

    /// The Chat tab: the conversation, the message being typed, and whether an answer is coming.
    var chatMessages: [TripChatMessage] = []
    var chatDraft = ""
    var isAnswering = false
    /// "Indexing your briefing…", "Ready · 12 notes · on-device" or "Unavailable · reason".
    var tripNotesStatus: String?
    /// The Wikivoyage guide the chat searches, loaded on its own (cached) so the chat has it even
    /// when grounding was off or the guide was too late for the Concierge.
    private(set) var chatGuide: TravelGuide?
    /// "Loading the Wikivoyage guide…" or "Unavailable · reason"; `nil` once loaded or not tried.
    private(set) var chatGuideStatus: String?
    private var isLoadingChatGuide = false

    /// Whether a message can be sent now: something is indexed to search, and nothing runs.
    var canChat: Bool { (tripNotes != nil || chatGuide != nil) && !isAnswering && !isRunning }
    /// How many notes the chat can search, or `nil` before a briefing is indexed.
    var chatNoteCount: Int? { tripNotes?.noteCount }

    /// Id of the Travel Guide row. Not an agent, so no node status can match it.
    static let travelGuideTrackID = "travel-guide.index"

    /// How long the Concierge waits for the guide once the first three agents are done. After
    /// that it runs ungrounded, exactly as with grounding off.
    static let guideWaitAfterFirstPhase: Double = 10

    /// Identifies this run's guide, so a late result from an earlier run cannot touch the row.
    private var guideRunToken = UUID()
    /// The row has reached its final state for this run; later updates are ignored.
    private var guideSettled = false

    /// One per app: keeps the on-device embedding model loaded and the stores under Caches.
    private let guideLibrary = TravelGuideLibrary()
    private let guideSourceCollector = TravelGuideSourceCollector()

    /// This run's indexed briefing, and its guide when the guide was ready in time.
    private var tripNotes: TripNotes?
    /// The days of the trip the notes came from, which can differ from `request` once it is edited
    /// or after a restart.
    private var notesTripDays: [String]?
    private var tripGuide: TravelGuide?
    private let answerNotesCollector = TripAnswerSourceCollector()
    private let answerGuideCollector = TravelGuideSourceCollector()

    let nodeTree = RTSNodeTreeViewModel()

    private var cancellables = Set<AnyCancellable>()

    static func freshTracks() -> [TrackState] {
        [
            TrackState(id: TripAgents.Name.weather, title: "Weather Scout", detail: "GeocodePlace → DailyForecast", systemImage: "cloud.sun"),
            TrackState(id: TripAgents.Name.itinerary, title: "Local Guide", detail: "PlacesSearch (MapKit), PII guardrail", systemImage: "map"),
            TrackState(id: TripAgents.Name.phrasebook, title: "Phrasebook", detail: "structured output", systemImage: "character.book.closed"),
            TrackState(id: TripAgents.Name.concierge, title: "Concierge", detail: "composes the briefing", systemImage: "person.crop.rectangle"),
            TrackState(id: TripAgents.Name.packing, title: "Packing List", detail: "agent used as a tool", systemImage: "suitcase"),
        ]
    }

    /// Loads the on-device embedding model ahead of the first run, so its asset download is
    /// not on a run's critical path.
    func warmUpGuide() {
        let library = guideLibrary
        // On-device only: never builds a guide and never calls OpenAI, so it spends nothing.
        Task.detached { await library.warmUp() }
    }

    func run(settings: ProviderSettings) {
        guard !isRunning, !isPreparingGuide else { return }
        if let reason = settings.agentsUnavailableReason {
            errorMessage = reason
            return
        }

        reset()
        isRunning = true
        let started = Date()
        let guideToken = guideRunToken
        let guideTask = settings.groundsTipsInWikivoyage
            ? startGuide(for: request.destination, openAIKey: settings.embeddingOpenAIKey, token: guideToken)
            : nil

        let gateway = settings.makeGateway()
        // Named for the workflow it runs, so traces, the call tree and Conductr say "Trip Briefing".
        let flow = RTSFlow(title: "Trip Briefing")
        subscribe(to: flow)
        nodeTree.attach(to: flow)

        let cloud = settings.agentLLMProvider
        let phrasebookProvider = settings.phrasebookLLMProvider
        let input = request.asInput
        let embeddingKey = settings.embeddingOpenAIKey
        for agent in [TripAgents.Name.weather, TripAgents.Name.itinerary, TripAgents.Name.concierge, TripAgents.Name.packing] {
            agentModels[agent] = cloud.callTreeLabel
        }
        agentModels[TripAgents.Name.phrasebook] = phrasebookProvider.callTreeLabel
        let fallbackProvider = settings.contextFallbackProvider
        let overflowHint = Self.overflowHint(settings: settings)
        let runProperties = [
            "Showcase": "Travel Assistant",
            "Provider": cloud.callTreeLabel,
            "Destination": request.destination,
            "Days": "\(request.dayCount)",
            "Grounded": "\(guideTask != nil)",
        ]
        AppLog.info("Briefing started", properties: runProperties)
        let traceUpload = RailtownSetup.uploadTrace(of: flow)

        Task { [weak self] in
            defer {
                RailtownSetup.finishTraceUpload(traceUpload)
                self?.isRunning = false
                self?.elapsed = Date().timeIntervalSince(started)
            }
            do {
                let agents = try TripAgents.make(cloud: cloud, phrasebook: phrasebookProvider)
                var workflow = TripBriefingWorkflow(agents: agents)
                workflow.onAgentResult = { [weak self] agentName, text in
                    Task { @MainActor in self?.publishSection(for: agentName, text: text) }
                }
                if let fallbackProvider {
                    workflow.fallbackAgents = try TripAgents.make(cloud: fallbackProvider, phrasebook: fallbackProvider)
                    workflow.onFallback = { [weak self] agentName in
                        Task { @MainActor in self?.noteFallback(of: agentName, to: fallbackProvider) }
                    }
                }
                if let guideTask {
                    workflow.guideTool = { [weak self] in
                        await self?.awaitGuide(guideTask, token: guideToken)
                    }
                }
                let output = try await flow.run(workflow, input: input, gateway: gateway)
                self?.consume(output)
                AppLog.info("Briefing finished", properties: runProperties.merging([
                    "Seconds": String(format: "%.1f", Date().timeIntervalSince(started)),
                ]) { current, _ in current })
            } catch let RTSError.guardrailBlocked(name, stage, reason, _) {
                guideTask?.cancel()
                self?.errorMessage = "Blocked by \(name) at \(stage): \(reason)"
                AppLog.warning("Briefing blocked by a guardrail", properties: runProperties.merging([
                    "Guardrail": name, "Stage": "\(stage)",
                ]) { current, _ in current })
            } catch {
                guideTask?.cancel()
                AppLog.error(error, message: "Briefing failed", properties: runProperties.merging([
                    "ContextOverflow": "\(ContextFallback.isContextOverflow(error))",
                    "Seconds": String(format: "%.1f", Date().timeIntervalSince(started)),
                ]) { current, _ in current })
                self?.errorMessage = ContextFallback.isContextOverflow(error)
                    ? "\(error)\n\(overflowHint)"
                    : "\(error)"
            }
            self?.collectGuideSources()
            // Also after a failure: the sections that did finish (say, weather and itinerary
            // before a Concierge error) are still worth asking about.
            self?.indexTripNotes(openAIKey: embeddingKey)
        }
    }

    // MARK: - Travel guide

    /// Fetches and indexes the destination's Wikivoyage guide (or reuses the cached index) and
    /// resolves to the Concierge's search tool. Any failure resolves to `nil`: the run carries on
    /// without grounding, and the Travel Guide row says why.
    private func startGuide(for destination: String, openAIKey: String?, token: UUID) -> Task<RTSKnowledgeSearchTool?, Never> {
        tracks.append(TrackState(
            id: Self.travelGuideTrackID,
            title: "Travel Guide",
            detail: "indexing Wikivoyage…",
            systemImage: "book.pages",
            status: .running
        ))
        let library = guideLibrary
        let collector = guideSourceCollector
        return Task { [weak self] in
            do {
                let guide = try await library.guide(for: destination, openAIKey: openAIKey)
                let summary = await Self.readySummary(guide, library: library)
                guard let self, self.settleGuide(token: token, status: .done, detail: "ready · \(summary)") else {
                    return nil   // too late: the Concierge already went ahead without it
                }
                self.guideArticleURL = guide.articleURL
                self.tripGuide = guide
                self.chatGuide = guide
                return TravelGuideTool.make(guide: guide, collector: collector)
            } catch {
                if case RTSRAGError.embeddingModelMismatch = error {
                    await library.discard(destination: destination)
                }
                let reason = TravelGuideError.reason(for: error)
                AppLog.warning("Travel guide unavailable", properties: ["Destination": destination, "Reason": reason])
                self?.settleGuide(token: token, status: .failed(reason), detail: "unavailable · \(reason)")
                return nil
            }
        }
    }

    /// Called by the workflow once the first three agents are done. Waits at most
    /// ``guideWaitAfterFirstPhase`` for the guide, then gives up on it for this run.
    private func awaitGuide(_ task: Task<RTSKnowledgeSearchTool?, Never>, token: UUID) async -> RTSKnowledgeSearchTool? {
        do {
            return try await withDeadline(
                seconds: Self.guideWaitAfterFirstPhase,
                timeoutError: { TravelGuideError.timedOut("travel guide") },
                operation: { await task.value }
            )
        } catch {
            task.cancel()
            AppLog.warning("Travel guide too late for the Concierge", properties: ["WaitSeconds": "\(Int(Self.guideWaitAfterFirstPhase))"])
            settleGuide(token: token, status: .failed("timed out"), detail: "unavailable · timed out")
            return nil
        }
    }

    /// `Lisbon · on-device · 8 sections, indexed in 6.3 s` or `…, cached`
    private static func readySummary(_ guide: TravelGuide, library: TravelGuideLibrary) async -> String {
        let timings = await library.lastTimings
        let how = guide.fromCache
            ? "cached"
            : String(format: "indexed in %.1f s", timings.prepare + timings.fetch + timings.ingest)
        return "\(guide.articleTitle) · \(guide.embedderLabel) · \(guide.sections.count) sections, \(how)"
    }

    /// Sets the Travel Guide row's final state once per run. Returns false when the row already
    /// settled or belongs to another run.
    @discardableResult
    private func settleGuide(token: UUID, status: TrackStatus, detail: String) -> Bool {
        guard token == guideRunToken, !guideSettled else { return false }
        guideSettled = true
        guard let index = tracks.firstIndex(where: { $0.id == Self.travelGuideTrackID }) else { return true }
        tracks[index].status = status
        tracks[index].detail = detail
        return true
    }

    /// Settings ▸ Prepare travel guide: indexes the current destination now (or confirms the
    /// cached index), without running any agent. With the on-device model unavailable and an
    /// OpenAI key set, this is the one place that spends OpenAI embedding credits outside a run.
    func prepareGuide(settings: ProviderSettings) {
        guard !isRunning, !isPreparingGuide else { return }
        isPreparingGuide = true
        let destination = request.destination
        guidePreparationStatus = "Preparing \(destination)…"
        let library = guideLibrary
        let openAIKey = settings.embeddingOpenAIKey
        Task { [weak self] in
            defer { self?.isPreparingGuide = false }
            do {
                let guide = try await library.guide(for: destination, openAIKey: openAIKey)
                self?.guidePreparationStatus = "Ready · \(await Self.readySummary(guide, library: library))"
            } catch {
                if case RTSRAGError.embeddingModelMismatch = error {
                    await library.discard(destination: destination)
                }
                self?.guidePreparationStatus = "Unavailable · \(TravelGuideError.reason(for: error))"
            }
        }
    }

    private func collectGuideSources() {
        guideSources = guideSourceCollector.sourceLabels
    }

    // MARK: - Ask about this trip

    /// Embeds the finished briefing so the Trip Assistant can search it. Uses the guide's
    /// embedder choice; when no embedder is available, asking stays off and the status says why.
    private func indexTripNotes(openAIKey: String?) {
        let notes = TripNotes.notes(
            request: request,
            report: report,
            phraseBook: phraseBook,
            weather: weatherReport?.compactText ?? rawWeather,
            itinerary: itinerary?.compactText ?? rawItinerary
        )
        // Trip details alone: no agent produced anything worth asking about.
        guard notes.count > 1 else { return }
        let destination = request.destination
        let days = tripDays
        let library = guideLibrary
        let token = guideRunToken
        tripNotesStatus = "Indexing your briefing…"
        Task { [weak self] in
            do {
                let indexed = try await library.tripNotes(notes, destination: destination, openAIKey: openAIKey)
                guard let self, token == self.guideRunToken else { return }
                self.tripNotes = indexed
                self.notesTripDays = days
                TripNotesArchive(destination: destination, tripDays: days, notes: notes).save()
                self.tripNotesStatus = "Ready · \(indexed.noteCount) notes · \(indexed.embedderLabel)"
                AppLog.info("Trip notes indexed", properties: ["Notes": "\(indexed.noteCount)", "Embedder": indexed.embedderLabel])
            } catch {
                guard let self, token == self.guideRunToken else { return }
                self.tripNotesStatus = "Unavailable · \(TravelGuideError.reason(for: error))"
                AppLog.warning("Trip notes not indexed", properties: ["Reason": TravelGuideError.reason(for: error)])
            }
        }
    }

    /// Loads the destination's Wikivoyage guide for the chat when it is not loaded yet: reuses the
    /// briefing's guide, or the cached index, or builds it. Called when the Chat tab appears.
    func prepareChat(settings: ProviderSettings) {
        if chatGuide == nil, let tripGuide { chatGuide = tripGuide }
        guard chatGuide == nil, !isLoadingChatGuide else { return }
        isLoadingChatGuide = true
        chatGuideStatus = "Loading the Wikivoyage guide…"
        let library = guideLibrary
        let destination = request.destination
        let openAIKey = settings.embeddingOpenAIKey
        Task { [weak self] in
            defer { self?.isLoadingChatGuide = false }
            do {
                let guide = try await withDeadline(
                    seconds: 30,
                    timeoutError: { TravelGuideError.timedOut("travel guide") },
                    operation: { try await library.guide(for: destination, openAIKey: openAIKey) }
                )
                guard let self, self.request.destination == destination else { return }
                self.chatGuide = guide
                self.chatGuideStatus = nil
            } catch {
                self?.chatGuideStatus = "Unavailable · \(TravelGuideError.reason(for: error))"
                AppLog.warning("Chat guide unavailable", properties: ["Destination": destination, "Reason": TravelGuideError.reason(for: error)])
            }
        }
    }

    /// Sends `text` (or the draft) to the Trip Assistant, with the last few exchanges as context.
    /// Each send is its own flow attached to the call tree, so it shows as one more run.
    /// - Returns: the run, whose value is the finished reply; `nil` when nothing was sent.
    @discardableResult
    func sendChat(_ text: String? = nil, settings: ProviderSettings) -> Task<TripChatMessage?, Never>? {
        let question = (text ?? chatDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, canChat else { return nil }
        if let reason = settings.agentsUnavailableReason {
            chatMessages.append(TripChatMessage(role: .notice, text: reason))
            return nil
        }

        let history = chatMessages.historyPrompt()
        chatMessages.append(TripChatMessage(role: .user, text: question))
        if text == nil { chatDraft = "" }
        let reply = TripChatMessage(role: .assistant, text: "", model: settings.agentLLMProvider.callTreeLabel)
        chatMessages.append(reply)
        isAnswering = true

        answerNotesCollector.reset()
        answerGuideCollector.reset()
        let notesCollector = answerNotesCollector
        let guideCollector = answerGuideCollector
        let notes = tripNotes
        let guide = chatGuide
        let days = notesTripDays ?? tripDays
        func assistant(on provider: RTSLLMProvider) -> RTSAgent {
            TripAgents.tripAssistant(
                provider: provider,
                notesTool: notes.map { TripNotesTool.make(notes: $0, collector: notesCollector) },
                guideTool: guide.map { TravelGuideTool.make(guide: $0, collector: guideCollector) },
                tripDays: days
            )
        }
        let agent = assistant(on: settings.agentLLMProvider)
        let fallbackProvider = settings.contextFallbackProvider
        let fallbackAgent = fallbackProvider.map { assistant(on: $0) }
        let overflowHint = Self.overflowHint(settings: settings)
        let prompt = history.isEmpty ? question : "\(history)\n\nNEW QUESTION:\n\(question)"

        let gateway = settings.makeGateway()
        let flow = RTSFlow(title: TripAgents.Name.assistant)
        nodeTree.attach(to: flow)
        agentModels[TripAgents.Name.assistant] = settings.agentLLMProvider.callTreeLabel
        // Counts and sources only: the question and answer text stay out of the logs.
        let chatProperties = [
            "Showcase": "Travel Assistant",
            "Provider": settings.agentLLMProvider.callTreeLabel,
            "HasNotes": "\(notes != nil)",
            "HasGuide": "\(guide != nil)",
            "HistoryCharacters": "\(history.count)",
        ]
        let started = Date()
        let traceUpload = RailtownSetup.uploadTrace(of: flow)

        return Task { [weak self] in
            defer {
                RailtownSetup.finishTraceUpload(traceUpload)
                self?.isAnswering = false
            }
            var answer: String
            var failed = false
            do {
                // On overflow, a second run of the same flow: the tree shows the failed on-device
                // attempt, then the cloud one.
                answer = try await ContextFallback.run(
                    primary: { try await flow.run(agent: agent, prompt: prompt, gateway: gateway) },
                    fallback: fallbackAgent.map { fallbackAgent in
                        { try await flow.run(agent: fallbackAgent, prompt: prompt, gateway: gateway) }
                    },
                    onFallback: {
                        guard let fallbackProvider else { return }
                        self?.noteFallback(of: TripAgents.Name.assistant, to: fallbackProvider)
                        self?.updateMessage(reply.id) { $0.model = "Apple Intelligence → \(fallbackProvider.callTreeLabel)" }
                    }
                )
            } catch {
                failed = true
                answer = ContextFallback.isContextOverflow(error) ? "\(error)\n\(overflowHint)" : "\(error)"
                AppLog.error(error, message: "Chat answer failed", properties: chatProperties)
            }
            let sources = notesCollector.sourceLabels + guideCollector.sourceLabels
            if !failed {
                AppLog.info("Chat answered", properties: chatProperties.merging([
                    "Sources": "\(sources.count)",
                    "Seconds": String(format: "%.1f", Date().timeIntervalSince(started)),
                ]) { current, _ in current })
            }
            self?.updateMessage(reply.id) { message in
                message.text = answer
                message.isError = failed
                message.sources = sources
            }
            return self?.chatMessages.first { $0.id == reply.id }
        }
    }

    /// Gets the chat ready for Siri or Shortcuts, which usually start the app fresh: reloads the
    /// latest briefing's notes from disk and the destination's guide from Caches, when they are
    /// not loaded. Never downloads a guide.
    /// - Returns: why the chat cannot answer, or `nil` when it can.
    func prepareForIntent(settings: ProviderSettings) async -> String? {
        if tripNotes == nil, let archive = TripNotesArchive.load() {
            do {
                tripNotes = try await guideLibrary.tripNotes(
                    archive.notes,
                    destination: archive.destination,
                    openAIKey: settings.embeddingOpenAIKey
                )
                notesTripDays = archive.tripDays
                if let tripNotes {
                    tripNotesStatus = "Ready · \(tripNotes.noteCount) notes · \(tripNotes.embedderLabel)"
                }
            } catch {
                AppLog.warning("Saved trip notes not indexed", properties: ["Reason": TravelGuideError.reason(for: error)])
            }
        }
        if chatGuide == nil {
            let destination = tripNotes?.destination ?? request.destination
            chatGuide = try? await guideLibrary.cachedGuide(for: destination, openAIKey: settings.embeddingOpenAIKey)
        }
        guard tripNotes != nil || chatGuide != nil else {
            return "There is no trip to ask about yet. Open Travel Assistant and build a briefing first."
        }
        return nil
    }

    func clearChat() {
        guard !isAnswering else { return }
        chatMessages = []
    }

    private func updateMessage(_ id: UUID, _ change: (inout TripChatMessage) -> Void) {
        guard let index = chatMessages.firstIndex(where: { $0.id == id }) else { return }
        change(&chatMessages[index])
    }

    /// "Day 1 = 2026-10-14", one per day of the trip.
    private var tripDays: [String] {
        let calendar = Calendar(identifier: .gregorian)
        return (0..<request.dayCount).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: request.startDate).map {
                "Day \(offset + 1) = \(TripRequest.dateFormatter.string(from: $0))"
            }
        }
    }

    // MARK: - Context fallback

    /// Shows in the call tree and the agent rows that `agentName` reran on the cloud. The
    /// Concierge's fallback brings its own cloud Packing List, so that row changes with it.
    private func noteFallback(of agentName: String, to provider: RTSLLMProvider) {
        AppLog.warning("On-device context full, agent reran on the cloud", properties: [
            "Agent": agentName, "Provider": provider.callTreeLabel,
        ])
        var names = [agentName]
        if agentName == TripAgents.Name.concierge { names.append(TripAgents.Name.packing) }
        for name in names {
            agentModels[name] = "Apple Intelligence → \(provider.callTreeLabel)"
            if let index = tracks.firstIndex(where: { $0.id == name }) {
                tracks[index].detail = "on-device context full · reran on \(provider.callTreeLabel)"
            }
        }
    }

    /// What to add to a context-overflow error when no fallback ran.
    static func overflowHint(settings: ProviderSettings) -> String {
        if !settings.fallsBackWhenContextFull {
            return "The on-device model ran out of room. Turn on cloud fallback in Settings to rerun that agent on \(settings.cloudProvider.title)."
        }
        return "The on-device model ran out of room. Add a \(settings.cloudProvider.title) API key in Settings to rerun that agent on the cloud."
    }

    // MARK: - Wiring

    private func subscribe(to flow: RTSFlow) {
        cancellables.removeAll()

        flow.nodeStatusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.apply(status)
            }
            .store(in: &cancellables)

        flow.outputFileURLPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                if case let .success(url) = result { self?.traceURL = url }
            }
            .store(in: &cancellables)
    }

    private func apply(_ status: RTSNodeStatus) {
        guard let index = tracks.firstIndex(where: { $0.id == status.nodeName }) else { return }
        switch status.state {
        case .queued: tracks[index].status = .queued
        case .executing: tracks[index].status = .running
        case .completed:
            // The section itself comes from the workflow's `onAgentResult`.
            tracks[index].status = .done
        case .failed(let message): tracks[index].status = .failed(message)
        }
    }

    /// Each agent's finished text lands in its own section as soon as that agent completes, through
    /// the workflow's `onAgentResult`. `consume(_:)` repeats this at the end, so nothing is lost.
    private func publishSection(for agentName: String, text: String) {
        switch agentName {
        case TripAgents.Name.weather:
            rawWeather = text
            weatherReport = try? WeatherReport.decode(from: text)
        case TripAgents.Name.itinerary:
            rawItinerary = text
            // Merged by date: the workflow may call the Local Guide again for days its first
            // answer left out, and each of those calls completes with that one day alone.
            if let decoded = try? Itinerary.decode(from: text) {
                let known = Set(itinerary?.days.map(\.date) ?? [])
                let added = decoded.days.filter { !known.contains($0.date) }
                let merged = (itinerary?.days ?? []) + added
                itinerary = Itinerary(days: merged.sorted { $0.date < $1.date })
            }
        case TripAgents.Name.phrasebook:
            rawPhrasebook = text
            phraseBook = try? PhraseBook.decode(from: text)
        case TripAgents.Name.concierge:
            rawBriefing = text
            report = try? TripBriefingReport.decode(from: text)
            collectGuideSources()
        default:
            break
        }
    }

    /// An agent's finished text, or empty while it has not finished.
    func sectionText(for agentName: String) -> String {
        switch agentName {
        case TripAgents.Name.weather: rawWeather
        case TripAgents.Name.itinerary: rawItinerary
        case TripAgents.Name.phrasebook: rawPhrasebook
        case TripAgents.Name.concierge: rawBriefing
        default: ""
        }
    }

    func isWriting(_ agentName: String) -> Bool {
        tracks.first { $0.id == agentName }?.status == .running
    }

    private func consume(_ output: RTSOutput) {
        let pairs: [(String, String)] = [
            (TripBriefingWorkflow.OutputKey.weather, TripAgents.Name.weather),
            (TripBriefingWorkflow.OutputKey.itinerary, TripAgents.Name.itinerary),
            (TripBriefingWorkflow.OutputKey.phrasebook, TripAgents.Name.phrasebook),
            (TripBriefingWorkflow.OutputKey.briefing, TripAgents.Name.concierge),
        ]
        for (key, agent) in pairs {
            if case let .string(text)? = output[key] { publishSection(for: agent, text: text) }
        }
        // The workflow's itinerary is the final, date-keyed merge: it replaces what the
        // per-call merge collected, including any day a repair call dated wrongly.
        if case let .string(text)? = output[TripBriefingWorkflow.OutputKey.itinerary],
           let final = try? Itinerary.decode(from: text) {
            itinerary = final
        }
    }

    private func reset() {
        errorMessage = nil
        report = nil
        phraseBook = nil
        weatherReport = nil
        itinerary = nil
        rawBriefing = ""
        rawWeather = ""
        rawItinerary = ""
        rawPhrasebook = ""
        traceURL = nil
        elapsed = nil
        tripNotes = nil
        notesTripDays = nil
        tripGuide = nil
        tripNotesStatus = nil
        // A new briefing replaces what the chat searches, so earlier answers no longer apply.
        chatMessages = []
        chatGuide = nil
        chatGuideStatus = nil
        guideSources = []
        guideArticleURL = nil
        guideSourceCollector.reset()
        guideRunToken = UUID()
        guideSettled = false
        tracks = Self.freshTracks()
    }
}
