import Foundation

/// LM Studio's local server: `/api/v1/models` (0.4+) or `/api/v0/models` (0.3.x) for the list, streaming
/// `/v1/chat/completions` for chat (its native `/api/v1/chat` can't take custom tools).
/// LM Studio answers unknown routes with 200 and an `error` body, so success is judged by what decodes, not the status.
public struct LMStudioClient: ChatBackend {
    public static let defaultBaseURL = URL(string: "http://localhost:1234")!
    public let baseURL: URL
    private let transport: any HTTPTransport

    public init(baseURL: URL = LMStudioClient.defaultBaseURL, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func ping() async throws {
        let data = try await get("v1/models", timeout: 5)
        guard (try? JSONDecoder().decode(OpenAIWire.ModelList.self, from: data)) != nil else {
            throw AssistantError.unreachable(Self.message(in: data))
        }
    }

    public func listModels() async throws -> [ModelInfo] {
        let v1 = try await get("api/v1/models", timeout: 5)
        if let list = try? JSONDecoder().decode(LMStudioWire.ModelsV1.self, from: v1) {
            return Self.loadedFirst(list.models.filter { ($0.type ?? "llm") == "llm" }.map { model in
                var capabilities = ["completion"]
                if model.capabilities?.trained_for_tool_use == true { capabilities.append("tools") }
                if model.capabilities?.vision == true { capabilities.append("vision") }
                let info = ModelInfo(name: model.key, sizeBytes: model.size_bytes, parameterSize: model.params_string, family: model.architecture, capabilities: capabilities)
                return (info, !(model.loaded_instances ?? []).isEmpty)
            })
        }
        let v0 = try await get("api/v0/models", timeout: 5)
        let list: LMStudioWire.ModelsV0
        do { list = try JSONDecoder().decode(LMStudioWire.ModelsV0.self, from: v0) } catch { throw AssistantError.decoding("models: \(Self.message(in: v0))") }
        return Self.loadedFirst(list.data.filter { ["llm", "vlm"].contains($0.type ?? "llm") }.map { model in
            var capabilities = ["completion"]
            if model.capabilities?.contains("tool_use") == true { capabilities.append("tools") }
            if model.type == "vlm" { capabilities.append("vision") }
            return (ModelInfo(name: model.id, family: model.arch, capabilities: capabilities), model.state == "loaded")
        })
    }

    public func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appending(path: "v1/chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONEncoder().encode(OpenAIWire.ChatRequestBody(request, ttl: Self.ttlSeconds(request.options.keepAlive)))
                    req.timeoutInterval = 300   // between chunks; the first load of a big model is slow
                    let (status, lines) = try await transport.lines(for: req)
                    if status != 200 {
                        var text = ""
                        for try await line in lines { text += line }
                        throw Self.error(status: status, body: text, model: request.model)
                    }
                    var filter = ThinkTagFilter()
                    var state = OpenAIStreamState()
                    var finished = false
                    func emit(_ events: [ChatEvent]) {
                        for event in events {
                            if case .token(let t) = event {
                                let (text, thinking) = filter.feed(t)
                                if !thinking.isEmpty { continuation.yield(.thinking(thinking)) }
                                if !text.isEmpty { continuation.yield(.token(text)) }
                            } else {
                                if case .done = event {
                                    let rest = filter.flush()
                                    if !rest.isEmpty { continuation.yield(.token(rest)) }
                                    finished = true
                                }
                                continuation.yield(event)
                            }
                        }
                    }
                    for try await line in lines {
                        try Task.checkCancellation()
                        guard let payload = SSEParser.payload(fromLine: line) else {
                            // A plain JSON body instead of a stream: LM Studio's 200-with-error reply.
                            if line.hasPrefix("{"), let body = try? JSONDecoder().decode(OpenAIWire.ErrorBody.self, from: Data(line.utf8)) {
                                throw AssistantError.httpStatus(200, body.error.message)
                            }
                            continue
                        }
                        emit(try OpenAIStreamParser.events(fromPayload: payload, state: &state))
                        if finished { break }
                    }
                    if !finished { emit(try OpenAIStreamParser.events(fromPayload: "[DONE]", state: &state)) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AssistantError.cancelled)
                } catch {
                    continuation.finish(throwing: AssistantError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func get(_ path: String, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.timeoutInterval = timeout
        let (status, body): (Int, Data)
        do { (status, body) = try await transport.data(for: req) } catch { throw AssistantError.wrapping(error) }
        guard status == 200 else { throw Self.error(status: status, body: String(decoding: body, as: UTF8.self), model: "") }
        return body
    }

    /// Loaded models first, keeping the server's order otherwise, so "Automatic" picks one that answers at once.
    private static func loadedFirst(_ models: [(ModelInfo, loaded: Bool)]) -> [ModelInfo] {
        models.filter(\.loaded).map(\.0) + models.filter { !$0.loaded }.map(\.0)
    }

    static func message(in body: Data) -> String {
        (try? JSONDecoder().decode(OpenAIWire.ErrorBody.self, from: body))?.error.message
            ?? String(decoding: body.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func error(status: Int, body: String, model: String) -> AssistantError {
        let message = message(in: Data(body.utf8))
        if [400, 404].contains(status), !model.isEmpty, message.localizedCaseInsensitiveContains("not found") { return .modelNotFound(model) }
        return .httpStatus(status, message)
    }

    /// Ollama-style keep-alive ("10m", "600s", "1h", "300") → seconds; nil when it doesn't parse or isn't positive.
    static func ttlSeconds(_ keepAlive: String) -> Int? {
        let text = keepAlive.trimmingCharacters(in: .whitespaces).lowercased()
        if let seconds = Int(text) { return seconds > 0 ? seconds : nil }
        let unit: Int
        switch text.last {
        case "s": unit = 1
        case "m": unit = 60
        case "h": unit = 3600
        default: return nil
        }
        guard let n = Int(text.dropLast()), n > 0 else { return nil }
        return n * unit
    }
}

enum LMStudioWire {
    struct ModelsV1: Decodable {
        let models: [Model]
        struct Model: Decodable {
            let type: String?
            let key: String
            let architecture: String?
            let size_bytes: Int64?
            let params_string: String?
            let loaded_instances: [JSONValue]?
            let capabilities: Capabilities?
        }
        struct Capabilities: Decodable { let vision: Bool?; let trained_for_tool_use: Bool? }
    }

    struct ModelsV0: Decodable {
        let data: [Model]
        struct Model: Decodable {
            let id: String
            let type: String?
            let arch: String?
            let state: String?
            let capabilities: [String]?
        }
    }
}
