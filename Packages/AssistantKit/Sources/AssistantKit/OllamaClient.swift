import Foundation

/// Ollama's HTTP API: `/api/version`, `/api/tags` and streaming `/api/chat` with tools.
public struct OllamaClient: ChatBackend {
    public static let defaultBaseURL = URL(string: "http://localhost:11434")!
    public let baseURL: URL
    private let transport: any HTTPTransport

    public init(baseURL: URL = OllamaClient.defaultBaseURL, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func ping() async throws {
        _ = try await get("api/version", timeout: 5)
    }

    public func listModels() async throws -> [ModelInfo] {
        let data = try await get("api/tags", timeout: 5)
        let tags: OllamaWire.Tags
        do { tags = try JSONDecoder().decode(OllamaWire.Tags.self, from: data) } catch { throw AssistantError.decoding("tags") }
        return tags.models.map {
            ModelInfo(name: $0.name, sizeBytes: $0.size, parameterSize: $0.details?.parameter_size, family: $0.details?.family, capabilities: $0.capabilities ?? [])
        }
    }

    public func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appending(path: "api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONEncoder().encode(OllamaWire.ChatRequestBody(request))
                    req.timeoutInterval = 300   // between chunks; the first load of a big model is slow
                    let (status, lines) = try await transport.lines(for: req)
                    if status != 200 {
                        var text = ""
                        for try await line in lines { text += line }
                        throw Self.error(status: status, body: text, model: request.model)
                    }
                    var filter = ThinkTagFilter()
                    for try await line in lines {
                        try Task.checkCancellation()
                        for event in try OllamaStreamParser.events(fromLine: line) {
                            if case .token(let t) = event {
                                let (text, thinking) = filter.feed(t)
                                if !thinking.isEmpty { continuation.yield(.thinking(thinking)) }
                                if !text.isEmpty { continuation.yield(.token(text)) }
                            } else {
                                if case .done = event {
                                    let rest = filter.flush()
                                    if !rest.isEmpty { continuation.yield(.token(rest)) }
                                }
                                continuation.yield(event)
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AssistantError.cancelled)
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func get(_ path: String, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.timeoutInterval = timeout
        let (status, body): (Int, Data)
        do { (status, body) = try await transport.data(for: req) } catch { throw Self.map(error) }
        guard status == 200 else { throw Self.error(status: status, body: String(decoding: body, as: UTF8.self), model: "") }
        return body
    }

    static func map(_ error: Error) -> AssistantError { .wrapping(error) }

    static func error(status: Int, body: String, model: String) -> AssistantError {
        let message = (try? JSONDecoder().decode(OllamaWire.ErrorBody.self, from: Data(body.utf8)))?.error
            ?? body.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 404, message.localizedCaseInsensitiveContains("not found") { return .modelNotFound(model) }
        if status == 400, message.localizedCaseInsensitiveContains("does not support tools") { return .toolsUnsupported(model) }
        return .httpStatus(status, message)
    }
}

/// One NDJSON line of `/api/chat` → events.
enum OllamaStreamParser {
    static func events(fromLine line: String) throws -> [ChatEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let chunk: OllamaWire.Chunk
        do { chunk = try JSONDecoder().decode(OllamaWire.Chunk.self, from: Data(trimmed.utf8)) } catch { throw AssistantError.decoding(String(trimmed.prefix(200))) }
        if let error = chunk.error { throw AssistantError.httpStatus(200, error) }
        var events: [ChatEvent] = []
        if let t = chunk.message?.thinking, !t.isEmpty { events.append(.thinking(t)) }
        if let c = chunk.message?.content, !c.isEmpty { events.append(.token(c)) }
        if let calls = chunk.message?.tool_calls, !calls.isEmpty {
            events.append(.toolCalls(calls.map { ToolCall(name: $0.function.name, arguments: $0.function.arguments ?? .object([:])) }))
        }
        if chunk.done == true {
            events.append(.done(ChatUsage(promptTokens: chunk.prompt_eval_count, completionTokens: chunk.eval_count,
                                          totalDuration: chunk.total_duration.map { Double($0) / 1_000_000_000 })))
        }
        return events
    }
}

/// Some models write `<think>…</think>` into the content even with thinking off; this routes that span to `.thinking`.
struct ThinkTagFilter {
    private enum State { case start, inside, passthrough }
    private static let open = "<think>", close = "</think>"
    private var state = State.start
    private var buffer = ""

    mutating func feed(_ chunk: String) -> (text: String, thinking: String) {
        switch state {
        case .passthrough:
            return (chunk, "")
        case .start:
            buffer += chunk
            if buffer.hasPrefix(Self.open) {
                state = .inside
                let rest = String(buffer.dropFirst(Self.open.count))
                buffer = ""
                return feedInside(rest)
            }
            if Self.open.hasPrefix(buffer) { return ("", "") }   // still could become the tag
            state = .passthrough
            defer { buffer = "" }
            return (buffer, "")
        case .inside:
            return feedInside(chunk)
        }
    }

    private mutating func feedInside(_ chunk: String) -> (text: String, thinking: String) {
        buffer += chunk
        if let range = buffer.range(of: Self.close) {
            let thinking = String(buffer[..<range.lowerBound])
            let text = String(buffer[range.upperBound...]).drop(while: \.isNewline)
            buffer = ""
            state = .passthrough
            return (String(text), thinking)
        }
        // Hold back a possible partial closing tag; emit the rest as thinking.
        let keep = min(buffer.count, Self.close.count - 1)
        let emit = String(buffer.dropLast(keep))
        buffer = String(buffer.suffix(keep))
        return ("", emit)
    }

    /// Whatever is still buffered when the stream ends.
    mutating func flush() -> String {
        defer { buffer = ""; state = .passthrough }
        return state == .start ? buffer : ""
    }
}

enum OllamaWire {
    struct ChatRequestBody: Encodable {
        let model: String
        let messages: [Message]
        let tools: [Tool]?
        let stream: Bool
        let think: Bool
        let options: Options
        let keep_alive: String

        init(_ r: ChatRequest) {
            model = r.model
            messages = r.messages.map(Message.init)
            tools = r.tools.isEmpty ? nil : r.tools.map { Tool(function: $0) }
            stream = true
            think = r.think
            options = Options(temperature: r.options.temperature, num_ctx: r.options.numCtx)
            keep_alive = r.options.keepAlive
        }

        struct Message: Encodable {
            let role: String
            let content: String
            let tool_calls: [ToolCallOut]?
            let tool_name: String?

            init(_ m: ChatMessage) {
                role = m.role.rawValue
                content = m.content
                tool_calls = m.toolCalls.isEmpty ? nil : m.toolCalls.map { ToolCallOut(function: .init(name: $0.name, arguments: $0.arguments)) }
                tool_name = m.toolName
            }
        }
        struct ToolCallOut: Encodable {
            let function: Function
            struct Function: Encodable { let name: String; let arguments: JSONValue }
        }
        struct Tool: Encodable {
            let type = "function"
            let function: ToolSpec
        }
        struct Options: Encodable { let temperature: Double; let num_ctx: Int }
    }

    struct Chunk: Decodable {
        let message: Message?
        let done: Bool?
        let prompt_eval_count: Int?
        let eval_count: Int?
        let total_duration: Int64?
        let error: String?

        struct Message: Decodable {
            let role: String?
            let content: String?
            let thinking: String?
            let tool_calls: [ToolCallIn]?
        }
        struct ToolCallIn: Decodable {
            let function: Function
            struct Function: Decodable { let name: String; let arguments: JSONValue? }
        }
    }

    struct Tags: Decodable {
        let models: [Model]
        struct Model: Decodable {
            let name: String
            let size: Int64?
            let details: Details?
            let capabilities: [String]?
            struct Details: Decodable { let parameter_size: String?; let family: String? }
        }
    }

    struct ErrorBody: Decodable { let error: String }
}
