# Railtracks Showcase

Two iOS showcases for [RailtracksSwift](../Railtracks-swift) in one app:

- **Travel Assistant**: a trip briefing from parallel agents, a chat grounded in your briefing and Wikivoyage, and a sign translator.
- **Pocket Manuals**: ask your PDF manuals; answers cite the page and get verified.

Every run is traced to JSON, to the in-app call tree, and to Instruments through
RailtracksInstrumentationKit.

## How the app is put together

- **Picker.** On first launch the root shows "Railtracks Showcase" with two large
  cards, one per demo. The choice is saved in `UserDefaults` under
  `showcase.selected` (absent until the first pick).
- **Switching.** Settings opens with a **Showcase** picker that swaps the root
  immediately and lands on the other demo's Settings tab. Each demo keeps its own
  tabs: Plan, Chat, Translate, Settings for Travel Assistant; Library, Ask, Settings for
  Pocket Manuals.
- **One Settings view, shared keys.** Both demos use the same `SettingsView`:
  Showcase, then the cloud provider and the API keys (`ProviderSettings`, Keychain
  service `io.railtown.TripBriefing.apikeys`), then the current demo's own options.
  Keys and provider are entered once. Pocket Manuals' index gets the shared OpenAI
  key for its embedding fallback, and is told when it changes.
- **State survives switching.** `TripBriefingApp` creates every long-lived object
  once (`ProviderSettings`, the Travel Assistant view models, Pocket Manuals'
  `ManualLibrary` with its `ManualIndex`, `AskViewModel` and `ManualsPreferences`)
  and injects them, so a run, an answer or indexing in progress keeps going while
  the other demo is showing.
- **Code layout.** Travel Assistant was called Trip Briefing, and its code still uses that
  name (`TripBriefing/Views`,
  `ViewModels`, `Agents`, `Flow`, `Knowledge`, …). The showcase shell is in
  `TripBriefing/Showcase/`. Pocket Manuals is in `TripBriefing/PocketManuals/`
  (`Knowledge/`, `Library/`, `Ask/`, `Views/`, `Samples/`). It came from the
  standalone `PocketManuals` repo (`../PocketManuals`), with its own key storage,
  provider enum and settings replaced by the shared ones; its preferences live in
  `ManualsPreferences` under `manuals.`-prefixed `UserDefaults` keys.

## Travel Assistant

Its Plan tab builds the trip briefing: one orchestrator node fans out three agents in parallel, then a concierge agent
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

## Pocket Manuals

A RAG showcase: you import PDF manuals, the app indexes each one page by page, and
questions are answered from your own manuals with page-level citations. Tabs:
**Library** (PDF import, bundled samples, indexing), **Ask** (grounded answers with
page citations, checked by a verifier) and **Settings** (the shared one).

### The library

- **Import PDF** copies the file to `Documents/Manuals/<id>.pdf` (`<id>` is a UUID),
  reads the title and page count with PDFKit, and indexes it immediately.
- Swiping to delete removes the document, its file, and its pages from the index.
- The list is saved as JSON at `Application Support/PocketManuals/library.json`.
- **Samples** are bundled from `TripBriefing/PocketManuals/Samples/`. The synchronized
  folder copies them flat into the bundle, and the app looks in both places. They show
  up as *Not indexed* and are indexed only when you tap **Index**, never at launch,
  because on a device without the on-device model that would spend your OpenAI key.

### Ask

One `RTSOrchestratorNode` (`AskWorkflow`, traced as "Ask Manuals") runs two agents on
the provider chosen in Settings:

1. **Answerer.** Calls `SearchManuals`, an `RTSKnowledgeSearchTool` over
   `ManualIndex.search`, and replies with `{ claims: [{ text, citations }], notFound }`,
   each citation a `"<docID>#page-N"` key.
2. **Verifier.** No tools. Gets the numbered claims and the collected passages and
   returns a verdict per claim: supported, partial or unsupported (✓, ~, ⚠).

**Ground answers in my manuals** (on by default, in Ask and in Settings) switches the
search tool and the Verifier off for a with/without comparison. The scope picker
searches all manuals or one. Tapping a citation chip or a source opens the manual at
that page.

### The index and its embedder

`ManualIndex` (an actor) keeps one `RTSRAGFileStore` per embedder at
`Application Support/ManualIndex/<embedder-id>/`. It embeds on-device with Apple's
`NLContextualEmbedding` when its assets are already present (loaded within 8 s);
otherwise with OpenAI `text-embedding-3-small` if the shared OpenAI key is set;
otherwise it is unavailable and Settings shows why. The iOS 18 simulator has no
on-device embedding model, so there indexing needs an OpenAI key. **Re-index
library** (Settings) indexes every document again with the active embedder, skipping
pages already stored for it.

### Sample manuals

Four sample PDFs ship in `TripBriefing/PocketManuals/Samples/`. Each sample's title in
the library is its file name. All four are US federal government works, public domain
(17 U.S.C. §105); may contain third-party images.

| Sample | Publisher | Source |
|---|---|---|
| Kitchen Companion (USDA) | U.S. Department of Agriculture (govinfo copy) | https://www.govinfo.gov/content/pkg/GOVPUB-A110-PURL-LPS99050/pdf/GOVPUB-A110-PURL-LPS99050.pdf |
| Energy Saver Guide (DOE) | U.S. Department of Energy (Energy Saver Guide 2022) | https://www.energy.gov/sites/default/files/2022-08/energy-saver-guide-2022.pdf |
| Citizens Guide to Radon (EPA) | U.S. Environmental Protection Agency (A Citizen's Guide to Radon) | https://www.epa.gov/sites/default/files/2016-12/documents/2016_a_citizens_guide_to_radon.pdf |
| Prepare Your Pets for Disasters (Ready.gov) | Ready.gov | https://www.ready.gov/sites/default/files/2023-06/ready.gov_prepare-pets-for-disasters.pdf |

## Demo scripts

### Travel Assistant

1. Pick **Travel Assistant**, and set a key in Settings.
2. Plan tab: keep the default destination, Lisbon, Portugal, and tap **Build my briefing**.
3. Watch the **Travel Guide** row in the Agents list go from indexing to ready (or
   unavailable, with the reason) while the three agents run in parallel.
4. Under the practical tips, open the **Sources** footer: the Wikivoyage sections the
   Concierge's searches returned, the article link, and the CC BY-SA attribution.

### Pocket Manuals

1. Pick **Pocket Manuals** (or switch in Settings ▸ Showcase).
2. Library tab: tap **Index** on each of the four samples. On a simulator this needs
   the OpenAI key.
3. Ask tab: tap each suggestion and check the cited page:

| Question | Expected citation |
|---|---|
| What temperature should I set my water heater to? | Energy Saver Guide p. 22, 120 °F |
| At what radon level should I fix my home? | Citizen's Guide to Radon p. 6, 4 pCi/L |
| What should go in my pet's emergency kit? | Prepare Your Pets p. 2 |
| What internal temperature should chicken reach? | Kitchen Companion p. 28, 165 °F. Retrieval ranks that page 5th for this wording; the Answerer is told to search again with other wording to reach it |

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
- An API key for OpenAI, Anthropic or Gemini, entered once in the Settings tab and
  shared by both demos. Keys are stored in the Keychain and handed to
  `RTSLLMGateway` per run.

## Run

1. Open `TripBriefing.xcodeproj`, select an iPhone simulator or device, ⌘R. The
   target and bundle id are still `TripBriefing` / `io.railtown.TripBriefing` (keys
   saved by earlier builds stay in the Keychain); the home-screen name is
   "Railtracks Showcase".
2. Pick a demo on the first screen.
3. Settings tab: pick a provider, paste its key.
4. Follow the demo scripts below.

## Profile in Instruments (Travel Assistant)

Install the Railtracks Instrumentation package (see the visualizer repo), then
Product → Profile with the **Railtracks Instrumentation** template. Agent Runs
shows three overlapping bars followed by two stacked ones; the Flow Tree nests
Packing List under Concierge; Tool I/O lists the geocode, forecast and Maps calls.

## Where the trace goes (Travel Assistant)

`Documents/sessions/Trip Briefing_<sessionID>.json` inside the app sandbox (the flow
keeps the workflow's name, Trip Briefing). The
Plan tab shows a Share button for the file after each run.

## Integration notes (Travel Assistant)

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
