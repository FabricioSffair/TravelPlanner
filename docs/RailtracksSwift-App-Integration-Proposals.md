# RailtracksSwift App Integration Proposals

Five additions to RailtracksSwift would cut an app's integration from roughly 400 lines of plumbing to a few dozen, without changing any existing API. They come from building the Trip Briefing iOS app against version 0.1.16: every item below replaces code that app had to write by hand.

Today an app builds an `RTSFlow` per run, subscribes to three Combine publishers before running, hops to the main actor in each sink, matches agents to UI rows by name string, decodes structured output by hand, reads orchestrator inputs with chains of `guard case`, writes its own Keychain wrapper, checks Apple Intelligence availability through FoundationModels, and declares each tool as a five-member struct with manual argument parsing.

Each section gives the public shape, what it sits on internally, and the catch.

## 1. Observable run model (RTSRun)

**Why.** Every app re-implements the same lifecycle, and gets at least one detail wrong: subscribing after `run` (statuses lost), forgetting `receive(on: .main)` (SwiftUI updates off the main actor), or not resetting state between runs. The SDK already knows the correct order; it should own it.

**Current behavior.** The app builds and wires the flow itself, per run:

```swift
let flow = RTSFlow(title: "Trip Briefing")
flow.nodeStatusPublisher.receive(on: DispatchQueue.main)
    .sink { [weak self] in self?.apply($0) }.store(in: &cancellables)
flow.partialOutputPublisher.receive(on: DispatchQueue.main)
    .sink { [weak self] in self?.liveText[$0.agentName] = $0.accumulated }.store(in: &cancellables)
flow.outputFileURLPublisher.receive(on: DispatchQueue.main)
    .sink { [weak self] in if case let .success(url) = $0 { self?.traceURL = url } }.store(in: &cancellables)
nodeTree.attach(to: flow)
Task { [weak self] in
    defer { self?.isRunning = false }
    do { self?.consume(try await flow.run(workflow, input: input, gateway: gateway)) }
    catch { self?.errorMessage = "\(error)" }
}
```

plus `apply(_:)`, `publishSection`, `sectionText`, `reset()` and the `TrackState` model: about 200 lines in `TripPlannerViewModel.swift`.

**Suggested behavior.** The SDK owns the lifecycle; the app owns one object and reads from it:

```swift
@State private var run = RTSRun(TripBriefingWorkflow(agents: agents))
run.start(input: request, gateway: gateway)
// run.phase, run.status(of:), run.liveText(for:), run.output(of:as:), run.traceURL, run.cancel()
```

`RTSRun` replaces the 200-line view model every app writes to drive a flow. It lives in `RailtracksSwiftUI` because it is `@MainActor @Observable`; the core stays headless. One `RTSRun` outlives many runs, the same way `RTSNodeTreeViewModel` already outlives flows.

```swift
@MainActor @Observable
public final class RTSRun<Workflow: RTSOrchestratorNode> {
    public enum Phase { case idle, running, finished(Workflow.Output), failed(RTSError) }
    public private(set) var phase: Phase
    public private(set) var nodes: [UUID: RTSNodeStatus]        // latest status per invocation
    public private(set) var liveText: [RTSAgentID: String]        // streamed text per agent
    public private(set) var outputs: [RTSAgentID: RTSOutput]      // from status.output on .completed
    public private(set) var traceURL: URL?
    public let tree: RTSNodeTreeViewModel

    public init(_ workflow: Workflow, configuration: RTSConfiguration = .default)
    public func start(input: Workflow.Input, gateway: RTSLLMGateway)
    public func cancel()

    public func status(of agent: RTSAgent) -> RTSNodeStatus.State?
    public func liveText(for agent: RTSAgent) -> String
    public func output<T: RTSSchemaConvertible>(of agent: RTSAgent, as: T.Type) -> T?
}
```

App side, the whole integration becomes:

```swift
@State private var run = RTSRun(TripBriefingWorkflow(agents: agents))

Button("Build my briefing") { run.start(input: request, gateway: gateway) }
RTSAgentProgressList(run)
Text(run.liveText(for: agents.weather))
if let report = run.output(of: agents.concierge, as: TripBriefingReport.self) { BriefingView(report) }
```

**Internals.** `start` does exactly what Trip Briefing's view model does today: build an `RTSFlow`, subscribe to statuses, partial output and the trace URL before running, attach the tree, then run inside a stored `Task` so `cancel()` can cancel it. Every value is updated on the main actor. Nothing new is needed in the core beyond the async sequences (section 2) and agent identity (section 3).

**Catch.** Agents are matched today by `nodeName`, a string. `RTSRun` needs a stable `RTSAgentID` carried on `RTSNodeStatus` and `RTSPartialOutput`, otherwise two agents with the same name collide and a typo shows nothing. That id is a one-line addition to `RTSAgent` and to both event types.


## 2. Async sequences on RTSFlow

**Why.** Combine forces every consumer to hold a `Set<AnyCancellable>`, hop to the main actor by hand, and cancel manually. SwiftUI's `.task` already ties an async loop to a view's lifetime, and Swift concurrency is where the SDK's own internals live.

**Current behavior.**

```swift
private var cancellables = Set<AnyCancellable>()

flow.nodeStatusPublisher
    .receive(on: DispatchQueue.main)
    .sink { [weak self] status in self?.apply(status) }
    .store(in: &cancellables)
// repeated for partialOutputPublisher and outputFileURLPublisher; cancellables.removeAll() before each run
```

**Suggested behavior.**

```swift
.task(id: run.id) {
    for await status in flow.statuses { apply(status) }      // ends when the view disappears or the flow completes
}
```

Async sequences are the core-side half of the run model and what keeps `RTSRun` small. They sit beside the existing Combine publishers, which stay for compatibility.

```swift
extension RTSFlow {
    public var statuses: AsyncStream<RTSNodeStatus>
    public var partialOutputs: AsyncStream<RTSPartialOutput>
    public func partialOutputs(for agent: RTSAgent) -> AsyncStream<RTSPartialOutput>
    public var trace: AsyncStream<Result<URL, Error>>
}
```

In a view, cancellation becomes structured: the view disappears, the loop ends, nothing to store.

```swift
.task(id: run.id) {
    for await status in flow.statuses { rows[status.nodeID] = status }
}
```

**Internals.** Each property creates a fresh `AsyncStream(bufferingPolicy: .unbounded)` fed from the existing subject, so several consumers can iterate independently. The streams finish when the collector signals completion, which `awaitCompletion()` already does. This also removes Combine from the app's side of the contract, which matters if the core is ever built for Linux.

**Catch.** Same as the publishers: a stream created after `run` starts misses the first statuses. `RTSRun` hides this; direct users need the rule documented once.


## 3. Typed inputs and outputs

**Why.** Dictionary keys are strings checked at runtime. A misspelled key or a schema that drifted from the struct shows up as `nil` in the UI, not as a build error, and every call site repeats the same decode.

**Current behavior.** Output, in the app:

```swift
let text = try await context.call(agents.phrasebook, prompt: prompt)
let book = try? PhraseBook.decode(from: text)            // nil on any mismatch, no diagnostic
```

Input, in the orchestrator:

```swift
guard case let .string(destination)? = input["destination"], !destination.isEmpty else { throw RTSError.missingInput("destination") }
guard case let .string(start)? = input["startDate"] else { throw RTSError.missingInput("startDate") }
guard case let .string(end)? = input["endDate"] else { throw RTSError.missingInput("endDate") }
let dayCount: Int = { if case let .number(n)? = input["dayCount"] { return Int(n) }; return 1 }()
// … two more
```

**Suggested behavior.**

```swift
let book: PhraseBook = try await context.call(agents.phrasebook, prompt: prompt)   // throws RTSError.decodingFailed with the agent name

struct TripBriefingWorkflow: RTSOrchestratorNode {
    func run(_ input: TripRequest, context: RTSRunContext) async throws -> TripBriefingReport { … }
}
```

Typed calls turn key typos into compile errors and delete the hand decoding at every call site. Three layers, each useful on its own.

**Typed outputs on calls.** `RTSSchemaConvertible` already provides `decode(from:)`; the overloads are thin:

```swift
extension RTSRunContext {
    public func call<T: RTSSchemaConvertible>(
        _ agent: some RTSAgentNode, prompt: String, as: T.Type = T.self
    ) async throws -> T {
        let text = try await call(agent, prompt: prompt)
        do { return try T.decode(from: text) }
        catch { throw RTSError.decodingFailed("\(agent.agentName) did not return \(T.self): \(error)") }
    }
}
extension RTSFlow {
    public func run<T: RTSSchemaConvertible>(agent:, prompt:, gateway:, as: T.Type) async throws -> T
}
```

App side: `let book: PhraseBook = try await context.call(agents.phrasebook, prompt: p)`.

Catch: the overload should confirm at session build that the agent declares `outputSchema == T.rtsSchema`, or set it when the agent has none. Otherwise a configuration mistake surfaces as a decoding error at runtime.

**Typed orchestrators.** Associated types with defaults, so every existing conformer compiles unchanged:

```swift
public protocol RTSOrchestratorNode: RTSFunctionNode {
    associatedtype Input: Decodable = RTSInput
    associatedtype Output: Encodable = RTSOutput
    func run(_ input: Input, context: RTSRunContext) async throws -> Output
}
```

The invoker keeps calling the dictionary-typed requirement; a protocol extension bridges by decoding `RTSInput` into `Input` and encoding `Output` back. `RTSValue` is already `Codable`, so the bridge is a small `Decoder` over the enum rather than a JSON round trip. Trip Briefing's `run` becomes `func run(_ input: TripRequest, context:) async throws -> TripBriefingReport` and six `guard case` lines disappear. The trace still records the dictionary form, so the JSON format does not change.

**Typed tool inputs** arrive with the tool macro (section 5), which uses the same `RTSValue` decoder.

**Agent identity.** Add `public let agentID: RTSAgentID` to `RTSAgent`, carried on `RTSNodeStatus` and `RTSPartialOutput`, so the run model and views bind to an agent value instead of its name.

## 4. Keys, availability and preflight

**Why.** Every app writes the same Keychain wrapper, imports FoundationModels just to ask whether Apple Intelligence is available, and discovers a missing key only when the run throws. Provider selection is SDK territory; the app should only choose.

**Current behavior.**

```swift
// KeychainStore.swift: 50 lines of SecItemAdd / SecItemCopyMatching
let gateway = RTSLLMGateway(apiKeys: [.openAI: KeychainStore.read("apikey.openAI") ?? ""])

#if canImport(FoundationModels)
if #available(iOS 26, *), case .available = SystemLanguageModel.default.availability { onDevice = true }
#endif
let phrasebookProvider: RTSLLMProvider = onDevice ? .appleAI : cloud

guard settings.hasCloudKey else { errorMessage = "Add a key in Settings first."; return }   // app-side guess
```

**Suggested behavior.**

```swift
let gateway = RTSLLMGateway(credentials: RTSKeychainCredentials())
let phrasebook = RTSAgent(llmProvider: .appleAI(fallback: cloud), …)

let issues = await gateway.validate(agents: [weather, guide, phrasebook, concierge])
runButton.disabled = issues.contains { $0.severity == .blocking }
```

Provider choice should be one line in the app, with no Keychain code and no FoundationModels import. Three pieces.

**Credential provider.** Keep `RTSLLMGateway(apiKeys:)` and add a resolver the gateway consults at session build, which is the only place a key is needed:

```swift
public protocol RTSCredentialProvider: Sendable {
    func apiKey(for kind: RTSLLMProviderKind) async throws -> String?
}
public struct RTSKeychainCredentials: RTSCredentialProvider {
    public init(service: String = "io.railtown.railtracks")
    public func set(_ key: String?, for kind: RTSLLMProviderKind) throws   // what a settings screen calls
}
extension RTSLLMGateway {
    public init(credentials: some RTSCredentialProvider)
}
```

`session(...)` becomes `async`, which every caller already is. The SDK ships the Keychain implementation and an in-memory one; Trip Briefing's `KeychainStore.swift` and the key half of `ProviderSettings` go away.

**On-device availability and fallback.** Two additions on the provider enum:

```swift
extension RTSLLMProvider {
    public static var isOnDeviceAvailable: Bool      // wraps #available + SystemLanguageModel.default.availability
    public static func appleAI(fallback: RTSLLMProvider) -> RTSLLMProvider
}
```

The gateway's `.appleAI` branch already throws `providerUnavailable` on an old OS; the same branch checks availability and, with a fallback, builds the fallback session instead. `model_provider` in the trace records what actually ran, so evaluations can compare the two populations.

App side: `llmProvider: .appleAI(fallback: .openAI(modelIDString: "gpt-4o-mini"))` replaces the `#if canImport(FoundationModels)` block and the manual provider swap.

**Preflight.** The checks that today surface at different points of a run, some only as log warnings, exposed before it:

```swift
public struct RTSPreflightIssue: Sendable { public let severity: Severity; public let message: String }
extension RTSLLMGateway {
    public func validate(agents: [any RTSAgentNode]) async -> [RTSPreflightIssue]
}
```

It reports: a missing key for a used provider, on-device unavailable with no fallback, tools Apple Intelligence will drop, images on a text-only provider, tool-name collisions after sanitizing, and an unwritable trace directory. The app disables the run button on the result instead of guessing.

## 5. Tool macro (@RTSTool)

**Why.** A tool is the unit integrators write most. Today each one is a struct with five members, a schema written separately from the closure that reads it, and hand-written `guard case` parsing per parameter. The schema and the code drift, and the boilerplate is the first thing a new integrator complains about.

**Current behavior.** `DailyForecastTool.swift` in Trip Briefing, trimmed:

```swift
struct DailyForecastTool: RTSToolNode {
    let id = UUID()
    let toolName = "DailyForecast"
    var inputs: RTSInput = [:]
    let callableRoutine = RTSClosure { inputs in
        guard case let .object(location)? = inputs["location"] else { throw RTSError.missingInput("location") }
        guard case let .number(latitude)? = location["latitude"] else { throw RTSError.missingInput("location.latitude") }
        guard case let .number(longitude)? = location["longitude"] else { throw RTSError.missingInput("location.longitude") }
        guard case let .object(range)? = inputs["range"] else { throw RTSError.missingInput("range") }
        guard case let .string(start)? = range["start"] else { throw RTSError.missingInput("range.start") }
        guard case let .string(end)? = range["end"] else { throw RTSError.missingInput("range.end") }
        let result = try await OpenMeteoClient.dailyForecast(latitude: latitude, longitude: longitude, start: start, end: end)
        return ["source": .string(result.source), "days": .array(result.days.map { … })]
    }
    var toolDescription = "Daily weather (max/min °C, condition, rain chance) for a location over an inclusive date range."
    var parameterSchema: RTSToolSchema {
        RTSToolSchema(parameters: [
            .init(name: "location", description: "Coordinates from GeocodePlace", type: .object([
                .init(name: "latitude", description: "Latitude in degrees", type: .number),
                .init(name: "longitude", description: "Longitude in degrees", type: .number),
            ])),
            .init(name: "range", description: "Inclusive trip dates, yyyy-MM-dd", type: .object([
                .init(name: "start", description: "First day", type: .string),
                .init(name: "end", description: "Last day", type: .string),
            ])),
        ])
    }
}
```

**Suggested behavior.**

```swift
@RTSTool("Daily weather (max/min °C, condition, rain chance) for a location over an inclusive date range.")
func dailyForecast(
    @RTSParam("Coordinates from GeocodePlace") location: Coordinate,
    @RTSParam("Inclusive trip dates, yyyy-MM-dd") range: DateRange
) async throws -> Forecast {
    try await OpenMeteoClient.dailyForecast(location, range)
}
```

A tool becomes an annotated function of about 8 lines instead of a 30-line struct, and its schema is derived from the signature so it cannot drift from the code.

**Syntax.**

```swift
@RTSTool("Daily weather for a location over a date range")
func dailyForecast(
    @RTSParam("Coordinates from GeocodePlace") location: Coordinate,
    @RTSParam("Inclusive dates, yyyy-MM-dd") range: DateRange,
    units: String = "C"
) async throws -> Forecast

@RTSSchema struct Coordinate: Codable { let latitude: Double; let longitude: Double }
@RTSSchema struct DateRange: Codable { let start: String; let end: String }
```

Registration stays as it is: `tools: [dailyForecastTool()]`, where `dailyForecastTool` is the generated factory.

**Expansion.** The peer macro emits `struct DailyForecastTool: RTSToolNode` with:

- `toolName` = the function name, `toolDescription` = the macro argument
- `parameterSchema` built from the parameter list: `String` → `.string`, `Double` / `Int` / `Float` → `.number`, `Bool` → `.bool`, `[T]` → `.array`, any `@RTSSchema` type → `.object` from its `rtsSchema` properties; the description from `@RTSParam`, or the parameter name when absent
- `callableRoutine` that decodes `inputs` into the parameters through the `RTSValue` decoder from section 3, calls the function, and encodes the `Encodable` return value into `RTSOutput`

The type-to-schema table already exists in `RTSSchemaMacro` (lines 87 to 115) and is reused. Object parameters from the current branch are what make structured arguments expressible.

**Constraints.**

- Optional parameters and defaulted parameters map to non-required arguments, so `RTSToolSchema.Parameter` gains `isRequired`, which the schema converters pass through to the provider.
- The function must be at file scope or `static`. The generated struct is `Sendable` and cannot capture `self`; an instance method is rejected with a diagnostic rather than silently captured.
- The return type must be `Encodable`. A plain `String` return is wrapped as `["result": .string(…)]` so existing prompts keep working.
- The struct protocol remains the escape hatch for tools that need `isRequired` for Apple Intelligence, custom `inputs`, or hand-written schemas.

