# Module contracts · KeelMac

> Part of 04-plan.md. The app target depends on these public APIs; packages may add more, but must keep these names and shapes. If a contract proves wrong during the build, fix this file first, then the code.

## Shared rules for every package
- Swift 6 language mode, `platforms: [.macOS(.v14)]`, swift-tools-version 6.0, strict concurrency clean (zero warnings).
- Public value types are `Sendable` structs/enums; stateful readers are actors or `final class … : @unchecked Sendable` guarded by a lock.
- No user-facing English sentences are built in packages. Return values, enums and numbers; the app localizes. Exceptions: rule titles/details come from `cleanup-rules.json` as `{"en": …, "es": …}`; operation log reasons use `RefusalReason.englishDescription`.
- Every removal goes through `SafetyKit.SafeRemover` (never `FileManager.removeItem` directly) with the right `PathContext`.
- Every external command goes through `SafetyKit.CommandRunning` with an absolute executable and an argument array. Never a shell string.
- Tests use Swift Testing (`import Testing`) and build fixtures in a temp directory; no test reads or changes the real home folder, the real Trash, launchd, or the network.

## Package layout
| Package | Products | Depends on | Owner |
|---|---|---|---|
| `Packages/SafetyKit` | SafetyKit | — | main session (done) |
| `Packages/MetricsKit` | MetricsKit | — | agent |
| `Packages/ScanKit` | ScanKit | — | agent |
| `Packages/CleanKit` | CleanKit | SafetyKit | agent |
| `Packages/AppsKit` | AppsKit | SafetyKit | agent |
| `Packages/MaintenanceKit` | HelperShared, HelperCore, MaintenanceKit | SafetyKit | agent |
| `Packages/InsightsKit` | DuplicatesKit, ReportKit | SafetyKit | agent |
| `Packages/AssistantKit` | AssistantKit | — | main session (M10) |
| `Packages/ProjectsKit` | ProjectsKit | SafetyKit | main session (M11) |

## SafetyKit (implemented)
`PathContext` (cleanup, userFile, uninstall, helper) · `PathGuard(home:userName:uid:whitelist:)` with `verdict(for:context:) -> PathVerdict` and `expandTilde` · `Whitelist(patterns)` · `GlobMatcher` · `SafeRemover(pathGuard:mode:context:)` with `remove([RemovalRequest]) -> [RemovalOutcome]` and injectable `trasher` · `DeleteMode` · `OperationEntry`, `OperationKind`, `OperationResult`, `OperationLogging`, `InMemoryOperationLog`, `OperationLogExporter` · `CommandRunning`, `ProcessCommandRunner`, `RecordingCommandRunner`, `CommandResult` · `FullDiskAccess.isGranted()`, `.settingsURL`.

## MetricsKit
```swift
public struct CPUSample: Sendable { public let total: Double /*0…1*/; public let user: Double; public let system: Double; public let perCore: [Double] }
public enum MemoryPressure: Int, Sendable, Codable { case normal = 1, warning = 2, critical = 4 }
public struct MemorySample: Sendable { totalBytes, usedBytes, appBytes, wiredBytes, compressedBytes, cachedBytes, swapUsedBytes: UInt64; pressure: MemoryPressure }
public struct DiskSample: Sendable { volumeName: String; totalBytes, availableBytes, usedBytes: Int64 }   // available = important-usage capacity (what Finder shows)
public struct NetworkSample: Sendable { bytesInPerSecond, bytesOutPerSecond: Double; totalIn, totalOut: UInt64 }
public struct BatteryInfo: Sendable, Equatable { isPresent: Bool; chargePercent: Int?; isCharging, isPluggedIn: Bool; cycleCount: Int?; designCapacity, maxCapacity: Int? /*mAh*/; maxCapacityPercent: Double?; condition: String? /*"Normal", "Service Recommended"…*/; temperatureCelsius: Double?; adapterWatts: Int?; timeRemainingMinutes: Int? }
public struct ProcessSample: Sendable, Identifiable { id: Int32 /*pid*/; name: String; userName: String; uid: UInt32; cpuPercent: Double /*100 = one core*/; memoryBytes: UInt64 /*phys footprint*/; bundleIdentifier: String?; isOwnedByCurrentUser: Bool }
public struct SystemInfo: Sendable { modelName, modelIdentifier, chip, macOSVersion: String; coreCount: Int; memoryBytes: UInt64; bootDate: Date; static func current() -> SystemInfo }
public struct MetricsSnapshot: Sendable { date: Date; cpu: CPUSample?; memory: MemorySample?; disk: DiskSample?; network: NetworkSample?; battery: BatteryInfo?; temperatureCelsius: Double?; processes: [ProcessSample] }
public actor MetricsSampler { public init(); public func sample(includeProcesses: Bool, includeTemperature: Bool) -> MetricsSnapshot }
public struct RingBuffer<Element: Sendable>: Sendable { init(capacity:); mutating func append(_:); var elements: [Element] /*oldest first*/; var count; var last }
public enum BatteryReader { static func read() -> BatteryInfo?; static func parse(registry: [String: Any], powerSource: [String: Any]?) -> BatteryInfo }
public enum TemperatureReader { static func socCelsius() -> Double? }
```
Memory used follows Activity Monitor: app + wired + compressed. CPU% per process from `proc_pidinfo(PROC_PIDTASKINFO)` time deltas converted with `mach_timebase_info`. Quitting processes is the app's job (AppKit), not MetricsKit's.

## ScanKit
```swift
public struct NodeID: Hashable, Sendable, Codable { public let raw: Int32 }
public struct ScanNodeInfo: Sendable, Identifiable { id: NodeID; name: String; path: String; isDirectory: Bool; bytes: Int64 /*allocated*/; fileCount: Int; modified: Date }
public struct ScanTree: Sendable, Codable {
    var root: NodeID; var scannedAt: Date; var rootPath: String; var lastEventID: UInt64; var unreadable: [String]
    func info(_ id: NodeID) -> ScanNodeInfo; func children(of: NodeID) -> [NodeID] /*size desc, dirs and the largest files*/
    func parent(of: NodeID) -> NodeID?; func lookup(path: String) -> NodeID?; func ancestors(of: NodeID) -> [NodeID] /*root first*/
}
public struct ScanProgress: Sendable { filesCounted: Int; bytesCounted: Int64; currentPath: String; elapsed: TimeInterval; unreadableCount: Int }
public enum ScanEvent: Sendable { case progress(ScanProgress), finished(ScanTree) }
public actor DiskScanner { public init(); func scan(root: String, exclusions: [String]) -> AsyncThrowingStream<ScanEvent, Error>; func rescan(_ tree: ScanTree, exclusions: [String]) -> AsyncThrowingStream<ScanEvent, Error> /*FSEvents replay since lastEventID; falls back to full*/; func rescan(_ tree: ScanTree, folder: String, exclusions: [String]) -> AsyncThrowingStream<ScanEvent, Error> }
public enum ScanCache { static func save(_ tree: ScanTree, to url: URL) throws; static func load(from url: URL) throws -> ScanTree }
public enum TreemapLayout { static func squarify(sizes: [Double], in rect: CGRect) -> [CGRect] /*same order as sizes*/ }
public struct SunburstSegment: Sendable { id: NodeID; depth: Int; startAngle, endAngle: Double /*radians*/ }
public enum SunburstLayout { static func layout(tree: ScanTree, root: NodeID, maxDepth: Int, minAngle: Double) -> [SunburstSegment] }
public struct LargeFile: Sendable, Identifiable { id: String /*path*/; path: String; bytes: Int64; modified: Date; lastOpened: Date? }
public enum LargeFileFinder { static func find(in tree: ScanTree, minBytes: Int64, notOpenedSince: Date?, lastOpened: (String) -> Date?) -> [LargeFile]; static func spotlightLastOpened(_ path: String) -> Date? }
public enum FileKind: String, Sendable, CaseIterable { document, video, audio, image, archive /*and disk images*/, aiModel, virtualMachine, other; static func of(path: String) -> FileKind /*by extension*/ }
public enum ReviewOwner: Sendable, Hashable { ollama, lmStudio, huggingFace, app(bundleID: String) /*~/Library/(Group )Containers*/, appSupport(folder: String), none }
public enum ReviewRemoval: Sendable, Hashable { trash([String]), ollamaRemove(model: String) /*`ollama rm`, keeps Ollama's index valid*/ }
public struct ReviewItem: Sendable, Identifiable, Hashable { id: String; name: String; path: String; kind: FileKind; bytes: Int64; nodes: [NodeID]; lastOpened: Date?; owner: ReviewOwner; removal: ReviewRemoval }
public enum ReviewFinder { static func find(in tree: ScanTree, home: String, minBytes: Int64, notOpenedSince: Date?, lastOpened: (String) -> Date?) -> [ReviewItem] /*largest first; AI models one item per model (Ollama manifests, LM Studio and Hugging Face folders, model folders inside app data); files inside packages (.app, .photoslibrary…), Mail, Messages and the Trash are skipped*/; static func isModelStorage(_ path: String, home: String) -> Bool /*inside Ollama, LM Studio or Hugging Face model storage*/ }
public struct SystemDataItem: Sendable, Identifiable { id: String; kind: SystemDataKind; paths: [String]; bytes: Int64?; needsFullDiskAccess: Bool; cleanupCategory: String? /*matches CleanKit category raw value*/ }
public enum SystemDataKind: String, Sendable, CaseIterable { simulators, localSnapshots, swap, appCaches, temporaryFiles, systemCaches, logs, iosBackups, xcode, mailDownloads, other }
public enum SystemDataBreakdown { static func measure(home: String, runner: …) async -> [SystemDataItem] }
```
The scanner scans the Data volume (`/System/Volumes/Data` when the root is `/`), stays on one device, counts hard links once, and records unreadable folders. Files ≥ 50 MB are kept as nodes so large files and the treemap can show them.

## CleanKit
```swift
public enum CleanupCategory: String, Sendable, Codable, CaseIterable { developer, userCaches, browserCaches, logs, installers, iosBackups, docker, languageFiles, trash }
public struct LocalizedText: Sendable, Codable, Equatable { en: String; es: String; func value(for languageCode: String) -> String }
public struct CleanupRule: Sendable, Codable, Identifiable { id; category; title, detail: LocalizedText; kind: RuleKind (.paths/.command); paths: [String]; exclude: [String]; minAgeDays: Int; optIn: Bool; needsAdmin: Bool; needsFullDiskAccess: Bool; skipIfRunning: [String] /*bundle ids*/; keepNewest: Int; command: CommandSpec?; measure: [String]?; requiresTool: String? }
public struct RuleSet: Sendable, Codable { schemaVersion: Int; rules: [CleanupRule]; static func bundled() throws -> RuleSet }
public struct CleanupItem: Sendable, Identifiable, Hashable { id: String; ruleID: String; path: String /*or the command line for command items*/; bytes: Int64; modified: Date?; isCommand: Bool }
public enum GroupStatus: Sendable, Equatable { case ready, needsFullDiskAccess, toolMissing, appRunning(String), failed(String) }
public struct CleanupGroup: Sendable, Identifiable { id: String /*rule id*/; rule: CleanupRule; items: [CleanupItem]; bytes: Int64; status: GroupStatus; selectedByDefault: Bool }
public struct CleanupPlan: Sendable { createdAt: Date; groups: [CleanupGroup]; func bytes(selected: Set<String>) -> Int64; func defaultSelection() -> Set<String> }
public struct CleanupEnvironment: Sendable { home: String; hasFullDiskAccess: Bool; runningBundleIDs: Set<String>; now: Date; uid: UInt32 }
public actor CleanupPlanner { init(rules: RuleSet, pathGuard: PathGuard, environment: CleanupEnvironment, runner: CommandRunning); func plan() async -> CleanupPlan }
public struct CleanupResult: Sendable { batchID: UUID; outcomes: [RemovalOutcome]; commandResults: [String: CommandResult]; bytesFreed: Int64 }
public struct CleanupExecutor: Sendable { init(remover: SafeRemover, runner: CommandRunning, log: OperationLogging); func execute(_ plan: CleanupPlan, selected: Set<String>) async -> CleanupResult }
```
Executor removes only selected item ids that exist in the plan; it never re-expands globs. Trash rule (`trash`) empties with `.permanent` regardless of mode, only for items in the plan.

## AppsKit
```swift
public struct InstalledApp: Sendable, Identifiable, Hashable { id: String /*path*/; name, path: String; bundleID: String?; version: String?; teamID: String?; bytes: Int64?; lastUsed: Date?; isApple: Bool }
public enum AppInventory { static func scan(folders: [String]) async -> [InstalledApp]; static func defaultFolders(home: String) -> [String] }
public struct RelatedFile: Sendable, Identifiable, Hashable { id: String /*path*/; path: String; bytes: Int64; location: RelatedLocation; isShared: Bool /*unchecked by default*/ }
public enum RelatedLocation: String, Sendable, CaseIterable { applicationSupport, caches, preferences, containers, groupContainers, savedState, logs, launchAgents, cookies, httpStorages, webKit, other }
public enum RelatedFileMatcher { static func find(for app: InstalledApp, home: String, installed: [InstalledApp]) -> [RelatedFile] }
public struct LeftoverGroup: Sendable, Identifiable { id: String /*bundle id*/; displayName: String; files: [RelatedFile]; bytes: Int64 }
public enum OrphanFinder { static func find(home: String, installed: [InstalledApp]) -> [LeftoverGroup] }
public final class TrashWatcher: @unchecked Sendable { init(trashPath: String, onAppTrashed: @escaping @Sendable (_ appPath: String, _ bundleID: String?, _ name: String) -> Void); func start(); func stop() }
public enum LaunchDomain: String, Sendable { userAgent, globalAgent, globalDaemon }
public struct LaunchItem: Sendable, Identifiable, Hashable { id: String /*plist path*/; label: String; plistPath: String; program: String?; domain: LaunchDomain; schedule: LaunchSchedule; ownerName: String?; ownerInstalled: Bool; isDisabled: Bool }
public enum LaunchSchedule: Sendable, Hashable { case atLoad, keepAlive, interval(Int), calendar, onDemand }
public struct LaunchItemStore: Sendable { init(home: String, uid: UInt32, runner: CommandRunning, installed: [InstalledApp]); func list() async -> [LaunchItem]; func setEnabled(_ item: LaunchItem, _ enabled: Bool) async -> CommandResult /*user agents only*/ }
public enum RunningApps { static func bundleIDs() -> Set<String>; static func isRunning(bundleID: String) -> Bool }
```

## MaintenanceKit (HelperShared, HelperCore, MaintenanceKit)
```swift
// HelperShared
public let helperMachServiceName = "mx.cvillegas.keelmac.helper"
public let helperProtocolVersion = 1
@objc public protocol KeelMacHelperProtocol { func protocolVersion(reply: @escaping (Int) -> Void); func perform(_ request: Data, reply: @escaping (Data) -> Void) }
public enum HelperOperation: Codable, Sendable, Equatable { case flushDNS, rebuildSpotlight, runPeriodic, thinLocalSnapshots(bytes: Int64), removeSystemItems(paths: [String]), launchd(label: String, plistPath: String, action: LaunchdAction) }
public enum LaunchdAction: String, Codable, Sendable { enable, disable, remove }
public struct HelperResponse: Codable, Sendable { exitCode: Int32; output: String; outcomes: [HelperItemOutcome] }
public enum HelperCommandMap { static func invocations(for op: HelperOperation) -> [(executable: String, arguments: [String])] }
public enum CodeSigningRequirement { static func client(teamID: String, bundleID: String) -> String; static func helper(teamID: String, bundleID: String) -> String }
// HelperCore (linked by the KeelMacHelper daemon; testable without XPC)
public struct HelperExecutor: Sendable { init(runner: CommandRunning, remover: SafeRemover); func perform(_ op: HelperOperation) async -> HelperResponse }
public final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate { init(executor:, requirement: String) }
// MaintenanceKit
public enum MaintenanceTaskID: String, Sendable, CaseIterable { flushDNS, rebuildLaunchServices, rebuildSpotlight, verifyStartupDisk, clearFontCaches, thinLocalSnapshots, runPeriodic }
public struct MaintenanceTask: Sendable, Identifiable { id: MaintenanceTaskID; commandLine: String /*exactly what runs, shown in the UI*/; needsAdmin: Bool; userInvocations: [(String, [String])]; helperOperation: HelperOperation? }
public enum MaintenanceCatalog { static let all: [MaintenanceTask] }
public enum MaintenanceEvent: Sendable { case output(String), finished(exitCode: Int32, duration: TimeInterval) }
public enum HelperStatus: Sendable { case notRegistered, requiresApproval, enabled, notFound, unavailable(String) }
public final class HelperClient: @unchecked Sendable { init(); var status: HelperStatus; func register() throws; func unregister() async throws; func perform(_ op: HelperOperation) async throws -> HelperResponse; func openApprovalSettings() }
public struct MaintenanceRunner: Sendable { init(runner: CommandRunning, helper: HelperClient?); func run(_ task: MaintenanceTask) -> AsyncStream<MaintenanceEvent> }
```

## InsightsKit (DuplicatesKit, ReportKit)
```swift
// DuplicatesKit
public struct DuplicateFile: Sendable, Identifiable, Hashable { id: String /*path*/; path: String; bytes: Int64; modified: Date; created: Date? }
public struct DuplicateGroup: Sendable, Identifiable { id: String /*full hash*/; bytesEach: Int64; files: [DuplicateFile]; var wastedBytes: Int64 }
public struct DuplicateProgress: Sendable { stage: Stage (.listing, .groupingBySize, .hashingHeads, .hashingFull); done: Int; total: Int }
public actor DuplicateFinder { init(pathGuard: PathGuard); func find(roots: [String], minBytes: Int64, progress: @escaping @Sendable (DuplicateProgress) -> Void) async throws -> [DuplicateGroup] }
public enum AutoSelectRule: Sendable, Hashable { case newest, oldest, preferredFolder(String); func filesToRemove(in group: DuplicateGroup) -> [DuplicateFile] /*always keeps exactly one*/ }
// ReportKit
public struct HealthInputs: Sendable, Codable, Equatable { sampledAt: Date; diskTotal, diskAvailable: Int64; pressureWarningFraction, pressureCriticalFraction: Double; batteryMaxCapacityPercent: Double?; batteryCycles: Int?; reclaimableBytes: Int64?; startupItems: Int; orphanStartupItems: Int }
public enum HealthFactorKind: String, Sendable, Codable, CaseIterable { diskFree, memoryPressure, battery, reclaimable, startupItems }
public enum FixRoute: String, Sendable, Codable { storageMap, monitor, cleanup, loginItems }
public struct HealthFactor: Sendable, Identifiable { id: HealthFactorKind; points: Int; maxPoints: Int; fix: FixRoute? }
public enum HealthBand: String, Sendable { good, fair, poor }  // ≥80, 60–79, <60
public struct HealthReport: Sendable { score: Int; band: HealthBand; factors: [HealthFactor] }
public enum HealthScore { static func compute(_ inputs: HealthInputs) -> HealthReport }
public enum LoadLine { static let fraction = 0.85; static func marginBytes(total: Int64, used: Int64) -> Int64 /*positive = above the line (room left), negative = below*/ }
public struct AlertThresholds: Sendable, Codable, Equatable { diskFreeBelowBytes: Int64?; memoryRedMinutes: Int?; temperatureAboveCelsius: Double?; batteryCapacityBelowPercent: Double?; static let defaults }
public struct AlertSample: Sendable { date: Date; diskAvailable: Int64?; pressure: Int /*MemoryPressure raw*/?; temperatureCelsius: Double?; batteryMaxCapacityPercent: Double? }
public enum AlertKind: String, Sendable, Codable { diskLow, memoryRed, temperatureHigh, batteryWorn }
public struct AlertEvent: Sendable, Equatable { kind: AlertKind; value: Double; threshold: Double }
public struct AlertEngine: Sendable, Codable { init(thresholds:); mutating func evaluate(_ sample: AlertSample) -> [AlertEvent] /*fires once per crossing, re-arms after recovery with hysteresis, 6 h cool-down per kind*/ }
public enum CoffeePrompt { static let minimumBytes: Int64 = 2_000_000_000; static func shouldShow(freedBytes: Int64, lastShown: Date?, dismissedForever: Bool, now: Date) -> Bool /*30 days*/ }
public struct SnapshotValue: Sendable, Codable, Identifiable, Equatable { id: UUID; date: Date; volumeTotal, volumeUsed: Int64; batteryMaxCapacityPercent: Double?; reclaimableBytes: Int64; entries: [String: Int64] }
public struct FolderChange: Sendable, Identifiable, Equatable { id: String /*path*/; oldBytes: Int64?; newBytes: Int64?; delta: Int64 }
public enum SnapshotDiff { static func compare(old: SnapshotValue, new: SnapshotValue) -> [FolderChange] /*sorted by delta desc*/ }
public enum SnapshotTaker { static func folders(home: String) -> [String]; static func take(home: String, volumeTotal: Int64, volumeUsed: Int64, battery: Double?, reclaimable: Int64, measure: @Sendable (String) async -> Int64) async -> SnapshotValue; static func allocatedSize(of path: String) -> Int64 }
public struct WeeklyReport: Sendable, Equatable { usedDelta: Int64; batteryNow: Double?; batteryDelta: Double?; topGrowth: [FolderChange]; reclaimable: Int64; static func make(current: SnapshotValue, previous: SnapshotValue?) -> WeeklyReport; func markdown(appVersion: String) -> String }
```

## AssistantKit (M10)
Pure Foundation, no dependencies. Everything public is a `Sendable` value type except the `ChatSession` actor and the lock-guarded `StubTransport`.
```swift
public enum JSONValue: Sendable, Hashable, Codable { null, bool, number, string, array, object; subscript(key:)/subscript(index:); stringValue/intValue/doubleValue/boolValue/arrayValue/objectValue; static func schema(properties:required:); static func property(_ type:_ description:enum:) }  // literal-expressible
public enum ChatRole: String { system, user, assistant, tool }
public struct ToolCall: Sendable, Codable, Hashable, Identifiable { id: String /*the server's, or minted on parse*/; name: String; arguments: JSONValue }
public struct ToolResult: Sendable, Hashable { call: ToolCall; output: String; isError: Bool }
public struct ChatMessage: Sendable, Codable, Hashable { role; content; toolCalls: [ToolCall]; toolName: String?; toolCallID: String? /*OpenAI-style servers need it*/; static func system/user/assistant(_:toolCalls:)/tool(name:output:)/tool(call:output:) }
public struct ToolSpec: Sendable, Codable, Hashable { name, description: String; parameters: JSONValue }
public protocol AssistantTool: Sendable { name, description: String; parameters: JSONValue; func call(_ arguments: JSONValue) async throws -> String }   // + `spec`
public struct ModelInfo: Sendable, Codable, Hashable, Identifiable { name; sizeBytes: Int64?; parameterSize: String?; family: String?; capabilities: [String]; supportsTools: Bool? }
public struct ChatOptions: Sendable, Hashable { temperature = 0.2; numCtx = 8192; keepAlive = "10m" }
public struct ChatRequest: Sendable, Hashable { model; messages; tools: [ToolSpec]; think = false; options }
public struct ChatUsage: Sendable, Hashable { promptTokens, completionTokens: Int?; totalDuration: TimeInterval? }
public enum ChatEvent: Sendable, Hashable { token(String), thinking(String), toolCalls([ToolCall]), done(ChatUsage?) }
public protocol ChatBackend: Sendable { func ping() async throws; func listModels() async throws -> [ModelInfo]; func chat(_: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> }
public enum AssistantProvider: String, CaseIterable, Sendable, Codable { ollama, lmStudio; var defaultBaseURL: URL; func makeClient(baseURL:transport:) -> any ChatBackend }   // names, bundle IDs, download links are the app's
public enum AssistantError: Error, Sendable, Hashable { unreachable(String), httpStatus(Int, String), modelNotFound(String), toolsUnsupported(String), decoding(String), cancelled, toolFailed(name: String, String), tooManyToolRounds }
public protocol HTTPTransport: Sendable { func data(for: URLRequest) async throws -> (status: Int, body: Data); func lines(for: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) }
public struct URLSessionTransport: HTTPTransport { init(session: URLSession = .shared) }
public final class StubTransport: HTTPTransport { init(handler: @Sendable (URLRequest) throws -> (Int, Data)); var requests: [URLRequest] }
public struct OllamaClient: ChatBackend { static let defaultBaseURL /*http://localhost:11434*/; init(baseURL:transport:) }   // GET api/version, GET api/tags, POST api/chat stream:true; 404 "not found" → modelNotFound, 400 "does not support tools" → toolsUnsupported, URLError → unreachable; `<think>…</think>` in content becomes `.thinking`
public struct LMStudioClient: ChatBackend { static let defaultBaseURL /*http://localhost:1234*/; init(baseURL:transport:) }   // GET v1/models (ping, must decode), GET api/v1/models else api/v0/models (LM Studio answers unknown routes 200 + {"error"}, so the fallback keys on the body), POST v1/chat/completions stream:true (SSE, one JSON per `data:` line, tool calls accumulated by index, arguments as a JSON string, tool results carry tool_call_id); trained_for_tool_use / "tool_use" → capabilities "tools"; loaded models listed first; keepAlive → ttl seconds; numCtx and think are not sent
public enum SessionEvent: Sendable, Hashable { token(String), thinking(String), toolStarted(ToolCall), toolFinished(ToolResult), finished(ChatMessage) }
public actor ChatSession { init(backend:model:tools:systemPrompt:maxToolRounds: 4, maxHistory: 24, options:); var messages: [ChatMessage]; var useTools: Bool; func send(_ text: String, context: String?) -> AsyncThrowingStream<SessionEvent, Error>; func cancel(); func reset(systemPrompt:); func setSystemPrompt(_:); func setUseTools(_:) }
```
`send` prepends `context` to the wire user message (the UI shows only `text`), streams tokens, runs tool calls in order (a throwing tool becomes an `isError` result the model can read), loops up to `maxToolRounds`, trims history past `maxHistory` without splitting an assistant/tool pair, and rolls the turn back on failure (a stopped reply keeps its partial text). Tools are the app's: they read services and never remove, run or change anything.

## ProjectsKit (M11)
Depends on SafetyKit only. Read-only checks; the only writer is `BackupExecutor`, and only for a plan the user previewed. Every command is `/usr/bin/git` with `-C <folder>` or the user's `gh`, as an argument array.
```swift
public enum ProjectSkipList { static let directories: Set<String> /*.git node_modules .build build DerivedData Pods vendor dist target .venv venv __pycache__ .next .gradle .swiftpm*/; static let files /*.DS_Store*/ }
public enum ProjectTools { static let git = "/usr/bin/git"; static let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]; static func gh(isExecutable:) -> String?; static func commandLine(_ executable: String, _ arguments: [String]) -> String /*shell-quoted, display only*/ }
public enum RepoSlug { static func make(_ folderName: String) -> String /*[A-Za-z0-9._-], diacritics folded, ≤ 100, "project" when empty*/; static func isValid(_:) -> Bool }
public struct FolderMeasure: Sendable, Hashable { bytes: Int64 /*allocated, everything, hard links once*/; fileCount: Int; newestModified: Date? /*files outside skipped folders, .DS_Store ignored*/; ownModified: Date?; unreadable: Int }
public enum FolderWalker { static func measure(_ path: String, skipping:ignoringFiles:) -> FolderMeasure /*fts FTS_PHYSICAL|FTS_NOCHDIR|FTS_XDEV*/ }
public struct RemoteInfo: Sendable, Hashable { name; url; ownerRepo: String? /*github.com in https, ssh, scp-like and git forms*/; var isGitHub; var webURL: URL? }
public struct BranchInfo: Sendable, Hashable { name; sha; upstream: String?; ahead; behind: Int; upstreamGone: Bool }
public struct TagInfo: Sendable, Hashable { name; sha }
public struct GitState: Sendable, Hashable { isWorktree: Bool; headBranch, headSHA: String?; hasCommits: Bool; uncommittedCount, stashCount: Int; branches: [BranchInfo]; tags: [TagInfo]; remotes: [RemoteInfo]; lastCommitDate: Date?; ignoredPaths: [String] /*≤ 20, outside generated folders*/; ignoredCount: Int; var githubRemote: RemoteInfo? /*origin first*/; var isDetached: Bool }
public enum GitHubAvailability: Sendable, Hashable { case available(login: String, gh: String), off, ghMissing, notSignedIn, failed(CommandFailure) }
public enum GitHubCheck: Sendable, Hashable { case off, checked, failed(CommandFailure), notApplicable }
public enum CommandFailure: Error, Sendable, Hashable { case authentication, repositoryNotFound, repositoryExists(String), offline, rejected, identityMissing, toolMissing, timedOut, other(exit: Int32, message: String); static func classify(_: CommandResult) -> CommandFailure }
public enum ProjectReason: Sendable, Hashable { case uncommittedChanges(Int), stashes(Int), noCommits, detachedHead, noRemote, remoteNotGitHub(String), unpushedCommits(branch: String, ahead: Int?), branchNotPushed(String), remoteAhead(String), tagsNotOnGitHub(Int), verificationFailed(CommandFailure) }
public enum ProjectVerdict: Sendable, Hashable { case safeToRemove, keep, notBackedUp([ProjectReason]), noGit, linkedWorktree, symlink, unreadable(String?); var rank: Int; var reasons: [ProjectReason] }
public struct ProjectScan: Sendable, Identifiable, Hashable { id /*path*/; path; name; root; git: GitState?; github: GitHubCheck; measure: FolderMeasure?; lastChange: Date?; isStale: Bool; verdict: ProjectVerdict; removalRefusal: RefusalReason? /*PathContext.userFile*/; scannedAt: Date; var isTrashCandidate /*safeToRemove && github == .checked && removalRefusal == nil*/; var needsVerification; var canBackUp; var githubURL: URL? }
public struct ProjectScanOptions: Sendable, Equatable { staleAfterDays = 180; verifyWithGitHub = false; skipDirectories; now; concurrency = 4 }
public struct ProjectEntry: Sendable, Hashable { root; path; kind: .directory/.symlink/.unreadable; var name }
public struct ProjectListing: Sendable, Hashable { entries: [ProjectEntry]; unreadableRoots: [String] }
public enum ProjectScanEvent: Sendable { case listed(ProjectListing), github(GitHubAvailability), project(ProjectScan), finished([ProjectScan]) }
public struct ProjectScanner: Sendable { init(runner: CommandRunning, pathGuard: PathGuard, git: String = ProjectTools.git, gh: String? = ProjectTools.gh(), measure:); func listProjects(in roots: [String]) -> ProjectListing; func githubAvailability(verify: Bool) async -> GitHubAvailability /*gh api user --jq .login; exit 4 → notSignedIn*/; func scan(roots: [String], options:) -> AsyncStream<ProjectScanEvent>; func scan(_ entry: ProjectEntry, options:) async -> ProjectScan; static func order(_:_:) -> Bool }
public enum ProjectClassifier { static func isStale(lastCommit:newestModified:limitDays:now:) -> Bool /*both old, missing counts as old*/; static func localReasons(_: GitState) -> [ProjectReason]; static func trackingReasons(_: GitState) -> [ProjectReason]; static func remoteBranchName(_:remote:) -> String; static func missingTags(_:remoteTags:) -> Int; static func verdict(git:reasons:isStale:) -> ProjectVerdict }
public enum GitParsers { static func status(_:) -> StatusSummary /*porcelain v2 --branch --show-stash --ignored*/; static func refs(_:) -> RefList; static func remotes(_:) -> [RemoteInfo]; static func ownerRepo(fromURL:) -> String?; static func commitDate(_:) -> Date?; static func lsRemote(_:) -> (heads: [String: String], tags: [String: String]) }
public enum GitHubParsers { static func login(fromAPI:) -> String?; static func isRepoNotFound(_:) -> Bool; static func isNameTaken(_:) -> Bool; static func repoURL(fromCreate:) -> URL? }
public struct BackupStep: Sendable, Hashable, Identifiable { enum Kind { writeGitignore, gitInit, gitAdd, gitCommit, checkRepoName, createRepo, pushNewBranches, pushAll, pushTags }; kind; executable; arguments; timeout; var commandLine: String; static let gitignore: String }
public struct BackupPlan: Sendable, Hashable { projectPath; projectName; steps: [BackupStep]; repository /*owner/name*/; remoteName /*origin, or github beside a non-GitHub origin*/; createsRepository: Bool; commits: Bool; stashesLeft: Int; var repositoryURL: URL? }
public enum BackupPlanProblem: Error, Sendable, Hashable { case githubUnavailable(GitHubAvailability), detachedHead, linkedWorktree, nothingToBackUp, notAFolder, invalidRepositoryName }
public enum BackupPlanner { static func plan(for: ProjectScan, github: GitHubAvailability, commitMessage: String, repositoryName: String? = nil, git:, fileExists:) -> Result<BackupPlan, BackupPlanProblem> }
public struct BackupStepOutcome: Sendable, Equatable { step; status: .ran/.failed(CommandFailure)/.skipped; result: CommandResult? }
public struct BackupResult: Sendable, Equatable { batchID: UUID; outcomes: [BackupStepOutcome]; var succeeded: Bool; var failure: BackupStepOutcome? }
public struct BackupExecutor: Sendable { init(runner: CommandRunning, log: OperationLogging, writeFile:); func execute(_ plan: BackupPlan, title: String, onStep:) async -> BackupResult }
```
Check commands: `git --no-optional-locks -C <p> status --porcelain=v2 --branch --show-stash --ignored`, `for-each-ref --format=%(refname)%09%(objectname)%09%(upstream:short)%09%(upstream:track) refs/heads refs/tags`, `git -C <p> remote -v`, `git --no-optional-locks -C <p> log -1 --format=%ct --exclude=refs/stash --all`; with verification, `git -C <p> ls-remote --heads --tags <github remote>`, then for each branch whose commit differs from GitHub's branch of the same name, `rev-list --ignore-missing --count <branch> --not <every GitHub head and tag>` (0 means every commit is on GitHub, so a merged branch that was never pushed passes; otherwise `unpushedCommits` with the count, `branchNotPushed` when GitHub has no such branch, or `remoteAhead` when GitHub's commit isn't on this Mac, checked with `cat-file -e`). Without verification, a branch with no upstream counts only when `rev-list --count <branch> --not --remotes` is above 0. A project is a repository only when `<folder>/.git` exists, so a root that is itself a repository doesn't leak into its subfolders. The executor stops at the first failure (later steps `.skipped`), maps `gh repo view` exit 0 to `repositoryExists`, writes `.gitignore` only when none exists, and logs one `OperationEntry(kind: .projects)` per step that ran with the command line as its path.

## Implementation notes (2026-10-22, after the packages were built)
The packages kept every name above and added these (see each package's sources for signatures):
- **MetricsKit:** `ProcessSample.path/isRestricted`; `SystemInfo.macOSBuild/uptime(now:)`; `BatteryInfo.absent/applying(_:)`. System Information's exact "Maximum Capacity" needs `system_profiler SPPowerDataType -json` (run by the app hourly through `CommandRunning`, parsed by `BatteryReader.parseSystemProfiler`). On macOS 27 battery values live under `AppleSmartBatteryPack/BatteryData`. Root and other users' processes report 0 CPU/memory (the kernel refuses them).
- **ScanKit:** `SystemDataBreakdown.measure(home:runner:)` takes a `ScanCommandRunner` (ScanKit has no SafetyKit dependency); cache is a binary `KSC1` file; only files ≥ 50 MB are tree nodes; `DiskScanner.lastRescan` reports incremental/folder/full. Measured: full scan of `/` 24–27 s, 128–134 MB peak.
- **CleanKit:** rules gain `measureWith`, `toolPaths`, `filter`, `itemInfo`, `deletesPermanently`; `GroupStatus` gains `.toolNotResponding`, `.needsHelper`; `CleanupResult` splits bytes moved/deleted/freed by commands. Schema: `Packages/CleanKit/RULES.md`.
- **AppsKit (login item advice):** `LaunchItem.startsOnItsOwn` (schedule isn't `.onDemand`) and `countsTowardStartup` (enabled and starts on its own): only these feed the Health Score's startup items. `LaunchAdvisor.advise(_ items: [LaunchItem], installed: [InstalledApp], now: Date) -> [String: LaunchAdvice]` (keyed by item id) returns `LaunchAdvice { action: LaunchAdviceAction (.remove, .turnOff); reason: LaunchAdviceReason (.appGone, .duplicate(otherPath:), .updater, .appUnused(lastUsed:)); isStrong: Bool }` for enabled items only; the app localizes the reasons. `.updater` applies only to periodic checks (at login, interval, calendar): a kept-alive updater is a service the app depends on and is never advised.
- **ReportKit (login item advice):** `HealthScore.startupPoints(total:orphans:) -> Int` so the app can project the factor after recommended changes.
- **AppsKit:** `RelatedFile.needsHelper/modified/reason`; `RelatedLocation` gains `applicationScripts`, `launchDaemons`, `privilegedHelperTools`; `LaunchItemStore.apply(_:enabled:) -> LaunchToggleOutcome` and `unload(_:)`. Cookies files are matched but refused by PathGuard (`Library/Cookies` is protected) by design.
- **MaintenanceKit:** `HelperOperation.dumpBackgroundItems`; `HelperResponse.rejection/timedOut`; `MaintenanceEvent.failed(_:)`; launchd lsregister flags are `-gc -f -all local,system,user` on macOS 27; `runPeriodic` is unavailable on macOS 27 (`/usr/sbin/periodic` removed). The helper moves removed system items to the caller's `~/.Trash/KeelMac`; if TCC refuses that, the item is reported failed and nothing is deleted.
- **AssistantKit (LM Studio, 2026-10-23):** `AssistantError.wrapping(_:)` is the shared transport/decoding mapper for both clients; `OpenAIStream.swift` holds the internal `SSEParser`, `OpenAIWire`, `OpenAIToolCallAccumulator` and `OpenAIStreamParser`. A model LM Studio wasn't trained for tools still gets a prompt-based fallback instead of a 400, so `toolsUnsupported` only ever comes from Ollama; the app relies on `supportsTools == false` instead.
- **ScanKit (M10):** `ReviewFinder.relative(_:to:)` and `ReviewFinder.owner(ofRelative:)` are public so the app's `inspect_path` tool can name the owning app without re-implementing the container rules.
- **InsightsKit:** `HealthFactor.details` carries raw values for the "why" sentence; `DuplicateFinder.search` returns unreadable paths; `WeeklyReport.markdown` is English by design.
- **SafetyKit (M11):** `OperationKind.projects` for Projects removals and Back up steps.
- **SafetyKit (after review):** cache roots (DerivedData, Archives, DeviceSupport, `.npm/_cacache`, Homebrew/CocoaPods/Yarn/SwiftPM caches, pnpm store) are container folders: their contents may be cleaned, the roots never. `SafeRemover.with(mode:)` added.
