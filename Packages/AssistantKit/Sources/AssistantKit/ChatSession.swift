import Foundation

public enum SessionEvent: Sendable, Hashable {
    case token(String)
    case thinking(String)
    case toolStarted(ToolCall)
    case toolFinished(ToolResult)
    case finished(ChatMessage)
}

/// One conversation: keeps the wire history, streams replies and runs the model's tool calls.
public actor ChatSession {
    private let backend: any ChatBackend
    public let model: String
    private let tools: [any AssistantTool]
    private let maxToolRounds: Int
    private let maxHistory: Int
    private let options: ChatOptions
    public private(set) var messages: [ChatMessage]
    /// Off after the server says the model can't take tools.
    public private(set) var useTools = true
    private var current: Task<Void, Never>?

    public init(backend: any ChatBackend, model: String, tools: [any AssistantTool], systemPrompt: String,
                maxToolRounds: Int = 4, maxHistory: Int = 24, options: ChatOptions = .init()) {
        self.backend = backend
        self.model = model
        self.tools = tools
        self.maxToolRounds = maxToolRounds
        self.maxHistory = maxHistory
        self.options = options
        self.messages = [.system(systemPrompt)]
    }

    public func setUseTools(_ on: Bool) { useTools = on }

    public func setSystemPrompt(_ prompt: String) {
        if messages.first?.role == .system { messages[0] = .system(prompt) } else { messages.insert(.system(prompt), at: 0) }
    }

    public func reset(systemPrompt: String) {
        current?.cancel()
        current = nil
        messages = [.system(systemPrompt)]
    }

    public func cancel() {
        current?.cancel()
    }

    /// `context` (what the user is looking at) travels with the wire message; callers display `text` alone.
    public func send(_ text: String, context: String?) -> AsyncThrowingStream<SessionEvent, Error> {
        current?.cancel()
        let (stream, continuation) = AsyncThrowingStream<SessionEvent, Error>.makeStream()
        let task = Task { await self.run(text: text, context: context, continuation: continuation) }
        current = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(text: String, context: String?, continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation) async {
        let mark = messages.count
        let wire = context.map { "\($0)\n\n\(text)" } ?? text
        messages.append(.user(wire))
        trimHistory()
        var content = ""
        do {
            var round = 0
            while true {
                try Task.checkCancellation()
                let request = ChatRequest(model: model, messages: messages, tools: useTools ? tools.map(\.spec) : [], options: options)
                content = ""
                var calls: [ToolCall] = []
                for try await event in backend.chat(request) {
                    switch event {
                    case .token(let t): content += t; continuation.yield(.token(t))
                    case .thinking(let t): continuation.yield(.thinking(t))
                    case .toolCalls(let c): calls += c
                    case .done: break
                    }
                }
                try Task.checkCancellation()
                if calls.isEmpty || round >= maxToolRounds {
                    if !calls.isEmpty, content.isEmpty { throw AssistantError.tooManyToolRounds }
                    let final = ChatMessage.assistant(content)
                    messages.append(final)
                    continuation.yield(.finished(final))
                    continuation.finish()
                    return
                }
                round += 1
                messages.append(.assistant(content, toolCalls: calls))
                for call in calls {
                    continuation.yield(.toolStarted(call))
                    let result = await execute(call)
                    continuation.yield(.toolFinished(result))
                    messages.append(.tool(call: call, output: result.output))
                }
            }
        } catch is CancellationError {
            keepPartial(content, mark: mark)
            continuation.finish(throwing: AssistantError.cancelled)
        } catch let error as AssistantError {
            if error == .cancelled { keepPartial(content, mark: mark) } else { messages.removeSubrange(mark...) }
            continuation.finish(throwing: error)
        } catch {
            messages.removeSubrange(mark...)
            continuation.finish(throwing: error)
        }
    }

    /// A stopped reply keeps what was said; a reply that never started leaves no trace.
    private func keepPartial(_ content: String, mark: Int) {
        if content.isEmpty { messages.removeSubrange(mark...) } else { messages.append(.assistant(content)) }
    }

    private func execute(_ call: ToolCall) async -> ToolResult {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            return ToolResult(call: call, output: "No tool named \(call.name).", isError: true)
        }
        do {
            return ToolResult(call: call, output: try await tool.call(call.arguments), isError: false)
        } catch {
            return ToolResult(call: call, output: "\(call.name) failed: \(error)", isError: true)
        }
    }

    /// Drops the oldest turns past `maxHistory`, keeping the system prompt and never starting on an orphan tool result.
    private func trimHistory() {
        guard messages.count > maxHistory + 1 else { return }
        var cut = messages.count - maxHistory
        while cut < messages.count, messages[cut].role == .tool { cut += 1 }
        messages.removeSubrange(1..<cut)
    }
}
