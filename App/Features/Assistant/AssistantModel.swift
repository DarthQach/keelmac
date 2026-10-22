import AssistantKit
import Foundation
import SwiftUI

/// The Assistant panel's state: connection status, the transcript and the context screens publish.
@MainActor
@Observable
final class AssistantModel {
    enum Status: Equatable {
        case disabled, checking, unreachable(String), noModel, idle, loadingModel, streaming, error(String)
    }

    struct Turn: Identifiable, Equatable {
        enum Kind: Equatable {
            case user(String)
            case assistant(String)
            case tool(name: String, output: String, isError: Bool)
        }
        let id: UUID
        var kind: Kind
        var isStreaming: Bool

        init(id: UUID = UUID(), kind: Kind, isStreaming: Bool = false) {
            self.id = id
            self.kind = kind
            self.isStreaming = isStreaming
        }
    }

    private(set) var turns: [Turn] = []
    private(set) var status: Status = .disabled
    private(set) var models: [ModelInfo] = []
    /// Set after the server said the model can’t take tools; answers then use only what is on screen.
    private(set) var toolsUnavailable = false
    /// Written by `.assistantContext(_:)`; nil means "just the screen's name".
    var context: ScreenContext?
    var isPresented: Bool {
        didSet { if !VisualFixtures.enabled { UserDefaults.standard.set(isPresented, forKey: Preferences.Key.assistantPanelOpen) } }
    }
    var tools: [any AssistantTool] = []

    private var makeBackend: @Sendable (URL) -> any ChatBackend = { OllamaClient(baseURL: $0) }
    private var currentRoute: @MainActor () -> Route = { .dashboard }
    private var backend: (any ChatBackend)?
    private var session: ChatSession?
    private var streamTask: Task<Void, Never>?
    private var toolTurns: [String: UUID] = [:]

    init() {
        isPresented = VisualFixtures.enabled ? VisualFixtures.argument("-fixture-assistant") != nil
            : UserDefaults.standard.bool(forKey: Preferences.Key.assistantPanelOpen)
    }

    /// Called once by AppModel after its services exist.
    func configure(tools: [any AssistantTool], backend: (@Sendable (URL) -> any ChatBackend)? = nil, route: @escaping @MainActor () -> Route) {
        self.tools = tools
        if let backend { makeBackend = backend }
        currentRoute = route
        if VisualFixtures.enabled { seedFixture() }
    }

    // MARK: Preferences

    var isEnabled: Bool {
        VisualFixtures.enabled ? VisualFixtures.argument("-fixture-assistant") != "disabled"
            : UserDefaults.standard.bool(forKey: Preferences.Key.assistantEnabled)
    }

    var host: String {
        let h = UserDefaults.standard.string(forKey: Preferences.Key.assistantHost) ?? ""
        return h.isEmpty ? OllamaClient.defaultBaseURL.absoluteString : h
    }

    var baseURL: URL { URL(string: host) ?? OllamaClient.defaultBaseURL }

    /// The chosen model when Ollama still has it, else the first tool-capable one.
    var modelName: String {
        let preferred = UserDefaults.standard.string(forKey: Preferences.Key.assistantModel) ?? ""
        if !preferred.isEmpty, models.isEmpty || models.contains(where: { $0.name == preferred }) { return preferred }
        return models.first(where: { $0.supportsTools != false })?.name ?? models.first?.name ?? preferred
    }

    var effectiveContext: ScreenContext { context ?? .routeOnly(currentRoute()) }
    var suggestions: [String] { Array(effectiveContext.suggestions.prefix(3)) }
    var canSend: Bool { status == .idle || { if case .error = status { true } else { false } }() }

    // MARK: Connection

    func settingsChanged() {
        stop()
        backend = nil
        session = nil
        toolsUnavailable = false
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        guard isEnabled else { status = .disabled; return }
        status = .checking
        let b = currentBackend()
        do {
            try await b.ping()
            models = try await b.listModels()
        } catch let error as AssistantError {
            status = describe(error)
            return
        } catch {
            status = .unreachable(host)
            return
        }
        status = models.isEmpty ? .noModel : .idle
    }

    func testConnection() async -> Status {
        await refreshStatus()
        return status
    }

    func togglePanel() {
        isPresented.toggle()
        if isPresented, isEnabled, [.disabled, .noModel].contains(status) || { if case .unreachable = status { true } else { false } }() {
            Task { await refreshStatus() }
        }
    }

    private func currentBackend() -> any ChatBackend {
        if let backend { return backend }
        let b = makeBackend(baseURL)
        backend = b
        return b
    }

    // MARK: Conversation

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canSend else { return }
        turns.append(Turn(kind: .user(trimmed)))
        turns.append(Turn(kind: .assistant(""), isStreaming: true))
        status = .loadingModel
        run(trimmed, context: AssistantPrompt.contextBlock(effectiveContext), retried: false)
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        if let session { Task { await session.cancel() } }
        finish(nil)
    }

    /// Sends the last question again (after an error).
    func retryLast() {
        guard canSend, let last = turns.last(where: { if case .user = $0.kind { true } else { false } }), case .user(let text) = last.kind else { return }
        send(text)
    }

    func clear() {
        stop()
        turns = []
        toolTurns = [:]
        session = nil
        toolsUnavailable = false
        if case .error = status { status = .idle }
    }

    private func ensureSession() -> ChatSession {
        if let session { return session }
        let s = ChatSession(backend: currentBackend(), model: modelName, tools: tools, systemPrompt: AssistantPrompt.system(languageCode: AssistantPrompt.languageCode))
        session = s
        return s
    }

    private func run(_ text: String, context: String, retried: Bool) {
        let session = ensureSession()
        let prompt = AssistantPrompt.system(languageCode: AssistantPrompt.languageCode)
        streamTask = Task { [weak self] in
            await session.setSystemPrompt(prompt)
            let stream = await session.send(text, context: context)
            var failure: AssistantError?
            do {
                for try await event in stream { self?.apply(event) }
            } catch let error as AssistantError {
                failure = error
            } catch {
                failure = .unreachable(String(describing: error))
            }
            guard let self, !Task.isCancelled else { return }
            if let failure {
                if case .toolsUnsupported = failure, !retried {
                    await session.setUseTools(false)
                    toolsUnavailable = true
                    resetStreamingTurn()
                    run(text, context: context, retried: true)
                    return
                }
                finish(failure)
            } else {
                finish(nil)
            }
        }
    }

    private var streamingIndex: Int? { turns.lastIndex(where: \.isStreaming) }

    private func apply(_ event: SessionEvent) {
        switch event {
        case .token(let t):
            status = .streaming
            if let i = streamingIndex, case .assistant(let text) = turns[i].kind { turns[i].kind = .assistant(text + t) }
        case .thinking:
            status = .streaming
        case .toolStarted(let call):
            status = .streaming
            let turn = Turn(kind: .tool(name: call.name, output: "", isError: false))
            toolTurns[call.id] = turn.id
            turns.insert(turn, at: streamingIndex ?? turns.endIndex)
        case .toolFinished(let result):
            if let id = toolTurns[result.call.id], let i = turns.firstIndex(where: { $0.id == id }) {
                turns[i].kind = .tool(name: result.call.name, output: result.output, isError: result.isError)
            }
        case .finished(let message):
            if let i = streamingIndex {
                turns[i].kind = .assistant(message.content)
                turns[i].isStreaming = false
            }
        }
    }

    private func resetStreamingTurn() {
        if let i = streamingIndex { turns[i].kind = .assistant("") }
    }

    private func finish(_ error: AssistantError?) {
        if let i = streamingIndex {
            turns[i].isStreaming = false
            if case .assistant(let text) = turns[i].kind, text.isEmpty, error != nil || status == .loadingModel { turns.remove(at: i) }
        }
        switch error {
        case nil, .cancelled?: status = isEnabled ? .idle : .disabled
        case .some(let e): status = describe(e)
        }
    }

    private func describe(_ error: AssistantError) -> Status {
        switch error {
        case .unreachable: return .unreachable(host)
        case .cancelled: return .idle
        case .modelNotFound(let m): return .error(String(localized: "Ollama no longer has the model \(m). Pick another one in Settings."))
        case .toolsUnsupported(let m): return .error(String(localized: "The model \(m) can’t use lookups."))
        case .httpStatus(let code, let message): return .error(String(localized: "Ollama answered \(code): \(message)"))
        case .decoding: return .error(String(localized: "KeelMac couldn’t read Ollama’s reply."))
        case .toolFailed(_, let message): return .error(message)
        case .tooManyToolRounds: return .error(String(localized: "The model kept looking things up without answering. Try asking more specifically."))
        }
    }

    // MARK: Fixtures (UI tests and screenshots)

    private func seedFixture() {
        switch VisualFixtures.argument("-fixture-assistant") {
        case "disabled": status = .disabled
        case "unreachable": status = .unreachable(host)
        case "noModel": status = .noModel
        case "error":
            models = [ModelInfo(name: "qwen3:8b", capabilities: ["completion", "tools"])]
            seedTranscript()
            status = .error(String(localized: "Ollama answered \(500): \("model runner has stopped")"))
        case "empty":
            models = [ModelInfo(name: "qwen3:8b", capabilities: ["completion", "tools"])]
            status = .idle
        case "open", "ready":
            models = [ModelInfo(name: "qwen3:8b", capabilities: ["completion", "tools"])]
            seedTranscript()
            status = .idle
        default: break
        }
    }

    private func seedTranscript() {
        turns = [
            Turn(kind: .user(String(localized: "What is this file?"))),
            Turn(kind: .tool(name: "inspect_path", output: "{\"bytes\": \"11 GB\", \"kind\": \"archive\"}", isError: false)),
            Turn(kind: .assistant(String(localized: "Design system.fig is an 11 GB Figma archive in Documents, last opened six months ago. Sketch is open and holds it, so the row is locked. Quit Sketch first, then Review large files › Move to Trash. The file goes to the Trash, where you can put it back."))),
        ]
    }
}
