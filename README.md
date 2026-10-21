# Travel Assistant

An iOS and macOS showcase for [RailtracksSwift](https://github.com/RailtownAI/Railtracks-swift): a trip briefing from parallel agents, a chat grounded in your briefing and Wikivoyage, and a sign translator.

Every run is traced to JSON, to the in-app call tree, and to Instruments through
RailtracksInstrumentationKit.

The code still uses the app's first name, Trip Briefing: the target, the bundle id `io.railtown.TripBriefing` and the `TripBriefing/` folders. Pocket Manuals, which shared this app for a while, is now its own repository.

## How it works

The Plan tab builds the trip briefing: one orchestrator node fans out three agents in parallel, then a concierge agent
composes the briefing using a packing-list agent exposed as a tool.

```
Trip Briefing (orchestrator, your code decides)
├── Weather Scout   agent · tools: GeocodePlace → DailyForecast (Open-Meteo)   ─┐
├── Local Guide     agent · tool: PlacesSearch (MapKit) · PII + length guardrails ├─ async let
├── Phrasebook      agent · no tools · @RTSSchema output · Apple Intelligence   ─┘
└── Concierge       agent · @RTSSchema output
    ├── Packing List      agent exposed as an RTSAgentTool
    └── SearchTravelGuide RTSKnowledgeSearchTool over the Wikivoyage guide (RAG)

Travel Guide (alongside the three tracks, not a node)
    Wikivoyage article → practical sections → on-device embeddings → file store
```

The Translate tab is a second, single-agent flow that sends a photo through the
`images:` path (cloud providers only).

### Travel tips grounded in Wikivoyage (RAG)

With **Ground tips in Wikivoyage** on (Settings, default on), the run also builds a
small retrieval index for the destination while Weather Scout, Local Guide and
Phrasebook are working, and the Concierge searches it before writing its four
practical tips (getting around, safety, etiquette, connectivity). The code is in
`TripBriefing/Knowledge/`:

- `TravelGuideIndex.swift` (Foundation + `RailtracksSwiftRAG` only) fetches the English
  Wikivoyage article as plain text through the MediaWiki Action API (city name first,
  then the full destination string; one request at a time, with a descriptive
  User-Agent), keeps the Understand, Get in, Get around, Eat, Drink, Stay safe,
  Respect, Cope, Connect and Talk sections (Eat and Drink carry dining etiquette), and
  turns each into an `RTSRAGDocument`. It chunks with `RTSRAGSentenceChunker` at 64% of
  `RTSRAGAppleEmbedding.maxInputCharacters` (see the integration notes), embeds
  on-device (no key), and ingests through `RTSRAGRetrievalRuntime` into an
  `RTSRAGFileStore` at `Caches/TravelGuides/<city>/`. A store that finished cleanly
  gets a `guide.json` manifest and is reused on later runs without fetching or
  embedding again. The manifest records an index format version
  (`TravelGuideLibrary.indexFormatVersion`); a store built with other sections or
  chunking is rebuilt. Bump it whenever either changes.
- **Embedder fallback.** Apple's on-device model (`RTSRAGAppleEmbedding`, no key) is used
  when its assets are already on the device, checked with
  `NLContextualEmbedding.hasAvailableAssets` so nothing downloads on the critical path,
  and only if it loads within 8 s. Otherwise, with an OpenAI key in Settings, the guide
  is embedded with OpenAI `text-embedding-3-small` (`RTSRAGOpenAIEmbedding`), which
  costs a little. With neither, the guide is unavailable and the briefing runs
  ungrounded. Each embedder has its own store
  (`Caches/TravelGuides/<city>/on-device/` or `.../openai-text-embedding-3-small/`),
  because a store is locked to one embedding model.
- **The iOS Simulator usually lacks the on-device embedding model.** Its asset request
  never completes there, so on a simulator expect OpenAI embeddings (with a key) or
  "unavailable". On a device that lacks the assets, the app asks for them once in the
  background, and later runs use them once they arrive.
- **Never blocks the briefing.** Once Weather Scout, Local Guide and Phrasebook finish,
  the Concierge waits at most 10 s for the guide, then runs ungrounded. The Travel Guide
  row then reads "unavailable · timed out".
- **Settings ▸ Prepare travel guide** indexes the current destination right away
  without running any agent. Use it to warm the cache before a demo or to check
  indexing on its own.
- `TravelGuideTool.swift` wraps the guide as `RTSKnowledgeSearchTool` named
  `SearchTravelGuide`, backed by an `RTSClosureKnowledgeSource` that cites each passage
  as `Wikivoyage › <City> › <Section>` and records it for the UI.

The Agents list shows a **Travel Guide** row (indexing, ready, or unavailable with
the reason). If the article is missing, the network fails or the embedding model is
unavailable, the Concierge runs exactly as it does with the toggle off. Under the
tips, a **Sources** footer lists the guide sections the searches returned, links the
article, and carries the attribution.

**Attribution.** Wikivoyage text is licensed under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Tips adapted from it
are shown with "Text adapted from Wikivoyage, CC BY-SA 4.0" and a link to the source
article; keep that footer if you change the UI.

## Demo script

1. Set a key in Settings, or keep the agents on Apple Intelligence.
2. Plan tab: keep the default destination, Lisbon, Portugal, and tap **Build my briefing**.
3. Watch the **Travel Guide** row in the Agents list go from indexing to ready (or
   unavailable, with the reason) while the three agents run in parallel.
4. Under the practical tips, open the **Sources** footer: the Wikivoyage sections the
   Concierge's searches returned, the article link, and the CC BY-SA attribution.

## Requirements

- Xcode 27 (the SDK's `main` needs it), iOS 18 deployment target. The phrasebook runs on-device only on iOS 26
  with Apple Intelligence available; otherwise it uses the cloud provider.
- This project uses the SDK's `main` branch from GitHub
  (`https://github.com/RailtownAI/Railtracks-swift.git`), with no local changes. The
  revision is pinned in `Package.resolved`; File > Packages > Update to Latest Package
  Versions moves it to the newest `main`. Xcode asks once to trust the `RTSMacro`
  macro; command-line builds pass `-skipMacroValidation`.
- The private `railtown-swift-logger` package resolves over SSH; for command-line
  builds set `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0='url.git@github.com:.insteadOf'
  GIT_CONFIG_VALUE_0='https://github.com/'` and pass `-scmProvider system`.
- Optional: two Railtown keys, entered in Settings under "Railtown". Both pipelines come
  from `railtown-swift-logger`, and each key turns on only its own:
  - **Logs**: `RailtownLogger`, for the app's own logs (`AppLog`) and the errors
    RailtracksSwift reports when a run fails.
  - **Agent runs**: `ConductrTraceUploader`, for each run's agent trace (host
    `testcndr.railtown.ai`), which includes prompts and tool results.

  Without a key, its pipeline stays off. With one, the logger's diagnostics print to the
  console, which shows whether batches upload.
- An API key for OpenAI, Anthropic or Gemini, entered once in the Settings tab and stored in
  the Keychain. They are handed to
  `RTSLLMGateway` per run.

## Run

1. Open `TripBriefing.xcodeproj`, select an iPhone simulator, a device or My Mac, and press ⌘R. The
   target and bundle id are still `TripBriefing` / `io.railtown.TripBriefing`, so keys
   saved by earlier builds stay in the Keychain. The home-screen name is "Travel Assistant".
2. Settings: pick a provider, and paste its key.
3. Follow the demo script above.

## Profile in Instruments

Install the Railtracks Instrumentation package (see the visualizer repo), then
Product → Profile with the **Railtracks Instrumentation** template. Agent Runs
shows three overlapping bars followed by two stacked ones; the Flow Tree nests
Packing List under Concierge; Tool I/O lists the geocode, forecast and Maps calls.

## Where the trace goes

`Documents/sessions/Trip Briefing_<sessionID>.json` inside the app sandbox (the flow
keeps the workflow's name, Trip Briefing). The
Plan tab shows a Share button for the file after each run.

## Integration notes

Things worth reporting back while building this app:

- `DailyForecastTool` takes four scalar parameters (`latitude`, `longitude`, `start`,
  `end`): the SDK's `main` has no object type for tool parameters.
- No streaming: the SDK's `main` has none. Each section appears when its agent finishes;
  `TripBriefingWorkflow` reports every agent's answer through its own `onAgentResult`
  callback, because `RTSNodeStatus` carries no output. Per-node progress comes from
  `nodeStatusPublisher`.
- The Travel Guide is not a node, so it does not appear in the call tree or trace;
  the Concierge's `SearchTravelGuide` calls do.
- On-device embedding caps input at 256 tokens, and `maxInputCharacters` (512) assumes
  two characters per token. Dense text (numbers, prices, Portuguese place names) runs
  denser, so chunks at the full 512 were dropped at ingest. Measured on Lisbon: every
  budget from 332 to 512 characters drops 1 to 11 chunks, and 307 to 331 drops none,
  so the chunker uses 64% (327 characters): 319 chunks, none dropped, about 5 s to index
  on a Mac.
- `MKLocalSearch` runs inside the SDK's `@Sendable` tool closure without issue,
  but its result types are not `Sendable`; fine in Swift 5 mode, worth checking
  under Swift 6 strict concurrency.
- Structured output plus a tool on the same agent (Concierge) depends on the
  provider supporting both in one request.
