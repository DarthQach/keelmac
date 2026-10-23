import AssistantKit
import Foundation
import SafetyKit
import ScanKit
import Testing
@testable import KeelMac

@Suite("Assistant")
@MainActor
struct AssistantTests {
    @Test func largeFilesContextRendersMetadataAndCaps() {
        let rows = VisualFixtures.reviewRows
        let many = (0..<15).map { i in
            ReviewRow(item: ReviewItem(id: "m\(i)", name: "file\(i).zip", path: "/tmp/file\(i).zip", kind: .archive, bytes: 1_000_000_000, nodes: [],
                                       lastOpened: nil, owner: .none, removal: .trash(["/tmp/file\(i).zip"])), owner: nil, status: .free)
        }
        let c = ScreenContext.largeFiles(shown: rows, selected: rows + many, minBytes: 500_000_000, months: 6)
        let text = c.rendered(maxItems: 12, maxBytes: 100_000)
        #expect(text.hasPrefix("Screen: Review large files"))
        #expect(text.contains("Design system.fig [file]"))
        #expect(text.contains("locked, Sketch is open"))
        #expect(text.contains("Size 12 GB") || text.contains("Size 12,00 GB") || text.contains("Size 12.00 GB"))
        #expect(text.contains("and 8 more"))
        #expect(c.suggestions.first == "What are these files?")
        #expect(ScreenContext.largeFiles(shown: rows, selected: [rows[0]], minBytes: 1, months: 1).suggestions.first == "What is this file?")
        let capped = c.rendered(maxItems: 12, maxBytes: 200)
        #expect(capped.utf8.count <= 204)
        #expect(capped.hasSuffix("…"))
    }

    @Test func monitorContextListsProcesses() {
        let c = ScreenContext.monitor(MetricsMonitor())
        let text = c.rendered()
        #expect(text.contains("CPU: 18"))
        #expect(text.contains("WindowServer"))
        #expect(c.suggestions.contains("Why is CPU high?"))
        #expect(ScreenContext.routeOnly(.maintenance).rendered().contains("Maintenance"))
    }

    @Test func systemPromptNamesEveryRouteAndTheLanguage() {
        let es = AssistantPrompt.system(languageCode: "es")
        #expect(es.contains("Answer in Spanish"))
        for route in Route.allCases { #expect(es.contains("keelmac://open/\(route.rawValue)")) }
        #expect(es.contains("cannot delete"))
        #expect(AssistantPrompt.system(languageCode: "en").contains("Answer in English"))
        #expect(AssistantPrompt.contextBlock(.routeOnly(.cleanup)).hasPrefix("[What the user is looking at]\nScreen: Cleanup"))
    }

    @Test func healthToolRendersScoreAndFixes() {
        let app = AppModel()
        let text = GetHealthTool.render(app)
        #expect(text.hasPrefix("Health Score "))
        #expect(text.contains("/100"))
        #expect(text.contains("diskFree:"))
        #expect(text.contains("keelmac://open/"))
        #expect(GetMetricsTool.render(app).contains("CPU: 18"))
    }

    @Test func toolSpecsAreWellFormed() {
        let tools = AssistantTools.all(AppModel())
        #expect(tools.map(\.name) == ["get_health", "get_metrics", "list_top_processes", "list_large_files", "inspect_path", "get_cleanup_summary", "list_leftovers", "list_login_items"])
        for t in tools {
            #expect(t.spec.parameters["type"]?.stringValue == "object")
            #expect(!t.description.isEmpty)
        }
    }

    @Test func inspectPathNeverReadsContents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("km-assistant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        let sentinel = "SENTINEL-\(UUID().uuidString)"
        try Data(sentinel.utf8).write(to: file)
        let pathGuard = PathGuard(whitelist: Whitelist([]))
        let out = InspectPathTool.describe(path: file.path, verdict: pathGuard.verdict(for: file.path, context: .userFile), tree: nil, home: NSHomeDirectory())
        #expect(!out.contains(sentinel))
        #expect(out.contains("\"exists\" : true"))
        #expect(out.contains("\"kind\" : \"document\""))
        #expect(out.contains("\"bytes\""))
        let missing = InspectPathTool.describe(path: dir.path + "/nope", verdict: .allow, tree: nil, home: NSHomeDirectory())
        #expect(missing.contains("\"exists\" : false"))
        let keychain = NSHomeDirectory() + "/Library/Keychains"
        let protected = InspectPathTool.describe(path: keychain, verdict: pathGuard.verdict(for: keychain, context: .userFile), tree: nil, home: NSHomeDirectory())
        #expect(protected.contains("KeelMac refuses"))
    }

    @Test func modelStreamsToolAndAnswer() async throws {
        let call = ToolCall(name: "get_health")
        let backend = ScriptedBackend([[.toolCalls([call])], [.token("Score "), .token("82."), .done(nil)]])
        let model = AssistantModel()
        model.configure(tools: [StaticTool(name: "get_health", output: "Health Score 82/100")], backend: { _, _ in backend }) { .dashboard }
        #expect(model.isEnabled)
        #expect(model.status == .disabled)
        await model.refreshStatus()
        #expect(model.status == .idle)
        #expect(model.modelName == "m")
        model.send("How healthy is my Mac?")
        #expect(model.turns.count == 2)
        #expect(model.status == .loadingModel)
        try await waitUntil { model.status == .idle }
        try #require(model.turns.count == 3)
        #expect(model.turns[0].kind == .user("How healthy is my Mac?"))
        #expect(model.turns[1].kind == .tool(name: "get_health", output: "Health Score 82/100", isError: false))
        #expect(model.turns[2].kind == .assistant("Score 82."))
        #expect(!model.turns[2].isStreaming)
        #expect(backend.requests.first?.messages.last?.content.contains("Screen: Dashboard") == true)
        #expect(backend.requests.first?.messages.first?.content.contains("KeelMac") == true)
        model.clear()
        #expect(model.turns.isEmpty)
    }

    @Test func modelRetriesWithoutToolsWhenUnsupported() async throws {
        let backend = ScriptedBackend([[], [.token("Plain answer"), .done(nil)]], failFirst: .toolsUnsupported("m"))
        let model = AssistantModel()
        model.configure(tools: [StaticTool(name: "get_health", output: "x")], backend: { _, _ in backend }) { .monitor }
        await model.refreshStatus()
        model.send("hi")
        try await waitUntil { model.status == .idle }
        #expect(model.toolsUnavailable)
        #expect(backend.requests.count == 2)
        #expect(backend.requests[1].tools.isEmpty)
        #expect(model.turns.last?.kind == .assistant("Plain answer"))
    }

    @Test func backendFailureBecomesErrorAndDropsEmptyTurn() async throws {
        let backend = ScriptedBackend([[]], failFirst: .httpStatus(500, "boom"))
        let model = AssistantModel()
        model.configure(tools: [], backend: { _, _ in backend }) { .monitor }
        await model.refreshStatus()
        model.send("hi")
        try await waitUntil { if case .error = model.status { true } else { false } }
        #expect(model.turns.count == 1)
        #expect(model.canSend)
    }

    @Test func switchingProviderReconnectsAtThatServersAddress() async throws {
        let defaults = UserDefaults.standard
        let keys = [Preferences.Key.assistantProvider, Preferences.Key.assistantProviderChosen, Preferences.Key.assistantModel]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set("ollama", forKey: Preferences.Key.assistantProvider)

        let made = FactoryLog()
        let model = AssistantModel()
        model.configure(tools: [], backend: { provider, url in made.record(provider, url); return ScriptedBackend([]) }) { .dashboard }
        await model.refreshStatus()
        #expect(made.calls.last?.provider == .ollama)
        #expect(made.calls.last?.url.port == 11434)

        defaults.set("someone-elses-model", forKey: Preferences.Key.assistantModel)
        model.switchProvider(to: .lmStudio)
        try await waitUntil { made.calls.count == 2 && model.status == .idle }
        #expect(model.provider == .lmStudio)
        #expect(made.calls.last?.provider == .lmStudio)
        #expect(made.calls.last?.url.port == 1234)
        #expect(defaults.string(forKey: Preferences.Key.assistantModel) == "")
        #expect(defaults.bool(forKey: Preferences.Key.assistantProviderChosen))
        #expect(model.modelName == "m")
    }

    @Test func newerRefreshWinsOverASlowerOlderOne() async throws {
        let made = FactoryLog()
        let model = AssistantModel()
        model.configure(tools: [], backend: { provider, url in
            made.record(provider, url)
            return made.calls.count == 1 ? SlowUnreachableBackend() as any ChatBackend : ScriptedBackend([])
        }) { .dashboard }
        model.settingsChanged()
        try await waitUntil { made.calls.count == 1 }   // the first check is now waiting on the slow ping
        model.settingsChanged()
        try await waitUntil { model.status == .idle }
        try await Task.sleep(for: .milliseconds(300))   // longer than the slow backend's ping
        #expect(model.status == .idle)
        #expect(made.calls.count == 2)
    }

    @Test func firstEnableDetectsTheInstalledServer() {
        #expect(AssistantProvider.detectInitial { _ in true } == .ollama)
        #expect(AssistantProvider.detectInitial { _ in false } == .ollama)
        #expect(AssistantProvider.detectInitial { $0 == .lmStudio } == .lmStudio)
        #expect(AssistantProvider.detectInitial { $0 == .ollama } == .ollama)
        #expect(AssistantProvider.lmStudio.other == .ollama)
        #expect(AssistantProvider.ollama.hostKey == Preferences.Key.assistantHost)
        #expect(AssistantProvider.lmStudio.hostKey == Preferences.Key.assistantLMStudioHost)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out")
    }
}

/// Every (provider, address) the model asked its backend factory for.
private final class FactoryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(provider: AssistantProvider, url: URL)] = []
    var calls: [(provider: AssistantProvider, url: URL)] { lock.withLock { _calls } }
    func record(_ provider: AssistantProvider, _ url: URL) { lock.withLock { _calls.append((provider, url)) } }
}

/// Answers ping late and then fails, like a server that went away mid-check.
private struct SlowUnreachableBackend: ChatBackend {
    func ping() async throws {
        try await Task.sleep(for: .milliseconds(150))
        throw AssistantError.unreachable("slow")
    }
    func listModels() async throws -> [ModelInfo] { [] }
    func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> { AsyncThrowingStream { $0.finish() } }
}

private struct StaticTool: AssistantTool {
    let name: String
    let output: String
    var description: String { "static" }
    var parameters: JSONValue { .schema() }
    func call(_ arguments: JSONValue) async throws -> String { output }
}

private final class ScriptedBackend: ChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[ChatEvent]]
    private var failFirst: AssistantError?
    private var _requests: [ChatRequest] = []

    init(_ scripts: [[ChatEvent]], failFirst: AssistantError? = nil) {
        self.scripts = scripts
        self.failFirst = failFirst
    }

    var requests: [ChatRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    func ping() async throws {}
    func listModels() async throws -> [ModelInfo] { [ModelInfo(name: "m")] }

    func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let (events, failure): ([ChatEvent], AssistantError?) = lock.withLock {
            _requests.append(request)
            let f = failFirst
            failFirst = nil
            return (scripts.isEmpty ? [.done(nil)] : scripts.removeFirst(), f)
        }
        return AsyncThrowingStream { c in
            if let failure { c.finish(throwing: failure); return }
            for e in events { c.yield(e) }
            c.finish()
        }
    }
}
