import Foundation

/// Server-sent events, one complete JSON object per `data:` line (LM Studio never splits one).
/// `URLSession`'s line sequence drops blank lines, so event boundaries can't be relied on; each `data:` line stands alone.
enum SSEParser {
    /// `data: {…}` → `{…}`, `data: [DONE]` → `[DONE]`; blank lines, `:` comments and `event:`/`id:`/`retry:` → nil.
    static func payload(fromLine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return payload.isEmpty ? nil : payload
    }
}

/// What a streamed `/v1/chat/completions` reply has delivered so far.
struct OpenAIStreamState {
    var calls = OpenAIToolCallAccumulator()
    var usage: ChatUsage?
}

/// One SSE payload of `/v1/chat/completions` → events.
enum OpenAIStreamParser {
    static func events(fromPayload payload: String, state: inout OpenAIStreamState) throws -> [ChatEvent] {
        if payload == "[DONE]" {
            var events: [ChatEvent] = []
            if !state.calls.isEmpty { events.append(.toolCalls(try state.calls.finish())) }
            events.append(.done(state.usage))
            return events
        }
        let chunk: OpenAIWire.Chunk
        do { chunk = try JSONDecoder().decode(OpenAIWire.Chunk.self, from: Data(payload.utf8)) } catch { throw AssistantError.decoding(String(payload.prefix(200))) }
        if let error = chunk.error { throw AssistantError.httpStatus(200, error.message) }
        if let u = chunk.usage { state.usage = ChatUsage(promptTokens: u.prompt_tokens, completionTokens: u.completion_tokens, totalDuration: nil) }
        var events: [ChatEvent] = []
        for choice in chunk.choices ?? [] {
            if let r = choice.delta?.reasoning_content ?? choice.delta?.reasoning, !r.isEmpty { events.append(.thinking(r)) }
            if let c = choice.delta?.content, !c.isEmpty { events.append(.token(c)) }
            if let deltas = choice.delta?.tool_calls { state.calls.add(deltas) }
            if choice.finish_reason != nil, !state.calls.isEmpty { events.append(.toolCalls(try state.calls.finish())) }
        }
        return events
    }
}

/// Streamed tool calls arrive in pieces keyed by `index`: the id and name first, then fragments of the arguments string.
struct OpenAIToolCallAccumulator {
    private struct Part { var id: String?; var name = ""; var arguments = "" }
    private var parts: [Int: Part] = [:]

    var isEmpty: Bool { parts.isEmpty }

    mutating func add(_ deltas: [OpenAIWire.ToolCallDelta]) {
        for d in deltas {
            let index = d.index ?? 0
            var part = parts[index] ?? Part()
            if let id = d.id, !id.isEmpty { part.id = id }
            if let name = d.function?.name, !name.isEmpty { part.name = name }
            if let args = d.function?.arguments { part.arguments += args }
            parts[index] = part
        }
    }

    mutating func finish() throws -> [ToolCall] {
        defer { parts = [:] }
        return try parts.keys.sorted().compactMap { index in
            guard let part = parts[index], !part.name.isEmpty else { return nil }
            let text = part.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            let arguments: JSONValue
            if text.isEmpty {
                arguments = .object([:])
            } else {
                do { arguments = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) } catch { throw AssistantError.decoding("tool arguments: \(text.prefix(200))") }
            }
            return part.id.map { ToolCall(id: $0, name: part.name, arguments: arguments) } ?? ToolCall(name: part.name, arguments: arguments)
        }
    }
}

/// The OpenAI-compatible chat wire format, as LM Studio speaks it.
enum OpenAIWire {
    struct ChatRequestBody: Encodable {
        let model: String
        let messages: [Message]
        let tools: [Tool]?
        let stream: Bool
        let temperature: Double
        /// LM Studio's idle-unload time in seconds (its extension of the format).
        let ttl: Int?

        init(_ r: ChatRequest, ttl: Int?) throws {
            model = r.model
            messages = try r.messages.map(Message.init)
            tools = r.tools.isEmpty ? nil : r.tools.map { Tool(function: $0) }
            stream = true
            temperature = r.options.temperature
            self.ttl = ttl
        }
    }

    struct Message: Encodable {
        let role: String
        let content: String
        let tool_calls: [ToolCallOut]?
        let tool_call_id: String?

        init(_ m: ChatMessage) throws {
            role = m.role.rawValue
            content = m.content
            tool_calls = m.toolCalls.isEmpty ? nil : try m.toolCalls.map(ToolCallOut.init)
            tool_call_id = m.role == .tool ? m.toolCallID : nil
        }
    }

    struct ToolCallOut: Encodable {
        let id: String
        let type = "function"
        let function: Function
        /// OpenAI sends arguments as a JSON string, not an object.
        struct Function: Encodable { let name: String; let arguments: String }

        init(_ call: ToolCall) throws {
            id = call.id
            function = Function(name: call.name, arguments: String(decoding: try JSONEncoder().encode(call.arguments), as: UTF8.self))
        }
    }

    struct Tool: Encodable {
        let type = "function"
        let function: ToolSpec
    }

    struct Chunk: Decodable {
        let choices: [Choice]?
        let usage: Usage?
        let error: ErrorValue?

        struct Choice: Decodable {
            let delta: Delta?
            let finish_reason: String?
        }
        struct Delta: Decodable {
            let content: String?
            let reasoning_content: String?
            let reasoning: String?
            let tool_calls: [ToolCallDelta]?
        }
        struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
    }

    struct ToolCallDelta: Decodable {
        let index: Int?
        let id: String?
        let function: Function?
        struct Function: Decodable { let name: String?; let arguments: String? }
    }

    /// `"error": "text"` or `"error": {"message": "text", …}`.
    struct ErrorValue: Decodable {
        let message: String

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                message = text
            } else {
                message = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .message)
            }
        }
        private enum Keys: String, CodingKey { case message }
    }

    struct ErrorBody: Decodable { let error: ErrorValue }

    /// `GET /v1/models`: enough to tell an OpenAI-style server from anything else on the port.
    struct ModelList: Decodable {
        let data: [Model]
        struct Model: Decodable { let id: String }
    }
}
