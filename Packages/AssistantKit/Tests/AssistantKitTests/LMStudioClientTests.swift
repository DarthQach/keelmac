import Foundation
import Testing
@testable import AssistantKit

@Suite("LMStudioClient")
struct LMStudioClientTests {
    let base = URL(string: "http://localhost:1234")!

    @Test func listModelsV1FiltersAndMapsCapabilities() async throws {
        let models = try fixture("lmstudio-models-v1", "json")
        let transport = StubTransport { req in
            #expect(req.url?.path == "/api/v1/models")
            return (200, models)
        }
        let list = try await LMStudioClient(baseURL: base, transport: transport).listModels()
        // Embedding dropped; the loaded model comes first.
        #expect(list.map(\.name) == ["google/gemma-4-26b-a4b", "deepseek-r1"])
        #expect(list[0].supportsTools == true)
        #expect(list[0].capabilities.contains("vision"))
        #expect(list[0].parameterSize == "26B")
        #expect(list[0].family == "gemma4")
        #expect(list[0].sizeBytes == 17_000_000_000)
        #expect(list[1].supportsTools == false)
        #expect(transport.requests.count == 1)
    }

    @Test func listModelsFallsBackToV0OnUnexpectedEndpointBody() async throws {
        let unexpected = try fixture("lmstudio-unexpected-endpoint", "json")
        let v0 = try fixture("lmstudio-models-v0", "json")
        let transport = StubTransport { req in
            req.url?.path == "/api/v1/models" ? (200, unexpected) : (200, v0)
        }
        let list = try await LMStudioClient(baseURL: base, transport: transport).listModels()
        #expect(transport.requests.map { $0.url?.path } == ["/api/v1/models", "/api/v0/models"])
        #expect(list.map(\.name) == ["meta-llama-3.1-8b-instruct", "qwen2-vl-7b-instruct"])
        #expect(list[0].supportsTools == true)
        #expect(list[1].supportsTools == false)
        #expect(list[1].capabilities.contains("vision"))
    }

    @Test func listModelsFailsWhenNeitherVersionDecodes() async throws {
        let unexpected = try fixture("lmstudio-unexpected-endpoint", "json")
        let transport = StubTransport { _ in (200, unexpected) }
        do {
            _ = try await LMStudioClient(baseURL: base, transport: transport).listModels()
            Issue.record("expected an error")
        } catch let e as AssistantError {
            guard case .decoding = e else { Issue.record("expected decoding, got \(e)"); return }
        }
    }

    @Test func pingDecodesModelList() async throws {
        let transport = StubTransport { req in
            #expect(req.url?.path == "/v1/models")
            return (200, Data(#"{"object":"list","data":[{"id":"google/gemma-4-26b-a4b","object":"model"}]}"#.utf8))
        }
        try await LMStudioClient(baseURL: base, transport: transport).ping()
    }

    @Test func pingRejectsUnexpectedEndpointBody() async throws {
        let unexpected = try fixture("lmstudio-unexpected-endpoint", "json")
        let transport = StubTransport { _ in (200, unexpected) }
        do {
            try await LMStudioClient(baseURL: base, transport: transport).ping()
            Issue.record("expected an error")
        } catch let e as AssistantError {
            guard case .unreachable(let message) = e else { Issue.record("expected unreachable, got \(e)"); return }
            #expect(message.hasPrefix("Unexpected endpoint"))
        }
    }

    @Test func pingMapsConnectionErrors() async {
        let transport = StubTransport { _ in throw URLError(.cannotConnectToHost) }
        do {
            try await LMStudioClient(baseURL: base, transport: transport).ping()
            Issue.record("expected an error")
        } catch let e as AssistantError {
            guard case .unreachable = e else { Issue.record("expected unreachable, got \(e)"); return }
        } catch { Issue.record("wrong error type") }
    }

    @Test func chatRequestBody() async throws {
        let transport = StubTransport { _ in (200, try fixture("openai-chat-tokens", "sse")) }
        let client = LMStudioClient(baseURL: base, transport: transport)
        let tool = RecordingTool(name: "get_health")
        let call = ToolCall(id: "call_1", name: "get_health", arguments: ["limit": 3])
        let request = ChatRequest(model: "google/gemma-4-26b-a4b", messages: [
            .system("sys"), .user("q"), .assistant("", toolCalls: [call]), .tool(call: call, output: "82"),
        ], tools: [tool.spec])
        let (_, error) = await drain(client.chat(request))
        #expect(error == nil)

        let req = try #require(transport.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/v1/chat/completions")
        let body = try json(req.httpBody)
        #expect(body["model"]?.stringValue == "google/gemma-4-26b-a4b")
        #expect(body["stream"]?.boolValue == true)
        #expect(body["temperature"]?.doubleValue == 0.2)
        #expect(body["ttl"]?.intValue == 600)
        #expect(body["num_ctx"] == nil)
        #expect(body["options"] == nil)
        #expect(body["keep_alive"] == nil)
        #expect(body["think"] == nil)
        #expect(body["tools"]?[0]?["type"]?.stringValue == "function")
        #expect(body["tools"]?[0]?["function"]?["name"]?.stringValue == "get_health")
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.count == 4)
        let out = try #require(messages[2]["tool_calls"]?[0])
        #expect(out["id"]?.stringValue == "call_1")
        #expect(out["type"]?.stringValue == "function")
        #expect(out["function"]?["name"]?.stringValue == "get_health")
        // OpenAI wants the arguments as a JSON string.
        let arguments = try #require(out["function"]?["arguments"]?.stringValue)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)) == ["limit": 3])
        #expect(messages[3]["role"]?.stringValue == "tool")
        #expect(messages[3]["tool_call_id"]?.stringValue == "call_1")
        #expect(messages[3]["content"]?.stringValue == "82")
        #expect(messages[1]["tool_call_id"] == nil)
        #expect(messages[0]["tool_calls"] == nil)
    }

    @Test func noToolsOmitsKey() async throws {
        let transport = StubTransport { _ in (200, try fixture("openai-chat-tokens", "sse")) }
        _ = await drain(LMStudioClient(baseURL: base, transport: transport).chat(ChatRequest(model: "m", messages: [.user("q")])))
        let body = try json(try #require(transport.requests.first?.httpBody))
        #expect(body["tools"] == nil)
    }

    @Test func tokensWithBlankLinesAndComments() async throws {
        let transport = StubTransport { _ in (200, try fixture("openai-chat-tokens", "sse")) }
        let (events, error) = await drain(LMStudioClient(baseURL: base, transport: transport).chat(ChatRequest(model: "m", messages: [.user("q")])))
        #expect(error == nil)
        let text = events.compactMap { if case .token(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "Hello, world.")
        guard case .done(let usage) = events.last else { Issue.record("expected done"); return }
        #expect(usage?.promptTokens == 40)
        #expect(usage?.completionTokens == 5)
        #expect(events.filter { if case .done = $0 { true } else { false } }.count == 1)
    }

    @Test func toolCallAccumulatedAcrossChunks() async throws {
        let transport = StubTransport { _ in (200, try fixture("openai-chat-toolcall", "sse")) }
        let (events, error) = await drain(LMStudioClient(baseURL: base, transport: transport).chat(ChatRequest(model: "m", messages: [.user("q")])))
        #expect(error == nil)
        #expect(events.count == 2)
        guard case .toolCalls(let calls) = events.first else { Issue.record("expected tool calls"); return }
        #expect(calls.count == 1)
        #expect(calls[0].id == "call_8f2a")
        #expect(calls[0].name == "inspect_path")
        #expect(calls[0].arguments["path"]?.stringValue == "~/Library/Caches")
        #expect(calls[0].arguments["limit"]?.intValue == 5)
        #expect(calls[0].arguments["options"]?["deep"]?.boolValue == true)
        guard case .done = events.last else { Issue.record("expected done"); return }
    }

    @Test func reasoningContentBecomesThinking() async throws {
        let transport = StubTransport { _ in (200, try fixture("openai-chat-reasoning", "sse")) }
        let (events, error) = await drain(LMStudioClient(baseURL: base, transport: transport).chat(ChatRequest(model: "m", messages: [.user("q")])))
        #expect(error == nil)
        #expect(events.prefix(2) == [.thinking("The user wants a greeting."), .token("Hi.")])
    }

    @Test func thinkTagsBecomeThinking() async throws {
        let lines = [
            #"data: {"choices":[{"delta":{"content":"<think>plan"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"ning</think>Answer"}}]}"#,
            "data: [DONE]",
        ].joined(separator: "\n")
        let transport = StubTransport { _ in (200, Data(lines.utf8)) }
        let (events, error) = await drain(LMStudioClient(baseURL: base, transport: transport).chat(ChatRequest(model: "m", messages: [.user("q")])))
        #expect(error == nil)
        let text = events.compactMap { if case .token(let t) = $0 { t } else { nil } }.joined()
        let thinking = events.compactMap { if case .thinking(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "Answer")
        #expect(thinking == "planning")
    }

    @Test func streamWithoutDoneStillFinishes() async throws {
        let line = #"data: {"choices":[{"delta":{"content":"Hi."}}]}"#
        let transport = StubTransport { _ in (200, Data(line.utf8)) }
        let (events, error) = await drain(LMStudioClient(baseURL: base, transport: transport).chat(ChatRequest(model: "m", messages: [.user("q")])))
        #expect(error == nil)
        #expect(events == [.token("Hi."), .done(nil)])
    }

    @Test func errorChunkMidStream() async throws {
        let lines = [
            #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#,
            #"data: {"error":{"message":"Model crashed","type":"server_error"}}"#,
        ].joined(separator: "\n")
        let transport = StubTransport { _ in (200, Data(lines.utf8)) }
        let (events, error) = await drain(LMStudioClient(baseURL: base, transport: transport).chat(ChatRequest(model: "m", messages: [.user("q")])))
        #expect(events == [.token("Hel")])
        #expect(error == .httpStatus(200, "Model crashed"))
    }

    @Test func plainErrorBodyInsteadOfStream() async throws {
        let transport = StubTransport { _ in (200, try fixture("lmstudio-unexpected-endpoint", "json")) }
        let (_, error) = await drain(LMStudioClient(baseURL: base, transport: transport).chat(ChatRequest(model: "m", messages: [.user("q")])))
        #expect(error == .httpStatus(200, "Unexpected endpoint or method. (GET /api/v1/models). Returning 200 anyway"))
    }

    @Test func modelNotFound() async {
        let body = #"{"error":{"message":"Model \"nope\" not found. Please load it first.","type":"invalid_request_error"}}"#
        let transport = StubTransport { _ in (404, Data(body.utf8)) }
        let (_, error) = await drain(LMStudioClient(baseURL: base, transport: transport).chat(ChatRequest(model: "nope", messages: [.user("hi")])))
        #expect(error == .modelNotFound("nope"))
    }

    @Test func otherStatusIsHTTPError() async throws {
        let transport = StubTransport { _ in (500, Data(#"{"error":"oops"}"#.utf8)) }
        await #expect(throws: AssistantError.httpStatus(500, "oops")) {
            try await LMStudioClient(baseURL: base, transport: transport).listModels()
        }
    }

    @Test func keepAliveBecomesTTL() {
        #expect(LMStudioClient.ttlSeconds("10m") == 600)
        #expect(LMStudioClient.ttlSeconds("90s") == 90)
        #expect(LMStudioClient.ttlSeconds("1h") == 3600)
        #expect(LMStudioClient.ttlSeconds("300") == 300)
        #expect(LMStudioClient.ttlSeconds("-1") == nil)
        #expect(LMStudioClient.ttlSeconds("0m") == nil)
        #expect(LMStudioClient.ttlSeconds("soon") == nil)
    }

    @Test func providerMakesTheRightClient() {
        #expect(AssistantProvider.ollama.makeClient(baseURL: base) is OllamaClient)
        #expect(AssistantProvider.lmStudio.makeClient(baseURL: base) is LMStudioClient)
        #expect(AssistantProvider.lmStudio.defaultBaseURL == base)
        #expect(AssistantProvider.ollama.defaultBaseURL.port == 11434)
    }
}

@Suite("SSE parsing")
struct SSEParserTests {
    @Test func dataLines() {
        #expect(SSEParser.payload(fromLine: #"data: {"a":1}"#) == #"{"a":1}"#)
        #expect(SSEParser.payload(fromLine: #"data:{"a":1}"#) == #"{"a":1}"#)
        #expect(SSEParser.payload(fromLine: "data: [DONE]") == "[DONE]")
    }

    @Test func everythingElseIsSkipped() {
        #expect(SSEParser.payload(fromLine: "") == nil)
        #expect(SSEParser.payload(fromLine: ": keep-alive") == nil)
        #expect(SSEParser.payload(fromLine: "event: message") == nil)
        #expect(SSEParser.payload(fromLine: "id: 4") == nil)
        #expect(SSEParser.payload(fromLine: "retry: 1000") == nil)
        #expect(SSEParser.payload(fromLine: "data:") == nil)
    }

    @Test func toolCallWithoutIDGetsOne() throws {
        var state = OpenAIStreamState()
        let first = try OpenAIStreamParser.events(fromPayload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"get_health","arguments":""}}]}}]}"#, state: &state)
        #expect(first.isEmpty)
        let done = try OpenAIStreamParser.events(fromPayload: "[DONE]", state: &state)
        guard case .toolCalls(let calls) = done.first else { Issue.record("expected tool calls"); return }
        #expect(calls[0].name == "get_health")
        #expect(!calls[0].id.isEmpty)
        #expect(calls[0].arguments == .object([:]))
    }

    @Test func badToolArgumentsAreADecodingError() throws {
        var state = OpenAIStreamState()
        _ = try OpenAIStreamParser.events(fromPayload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"x","arguments":"{nope"}}]}}]}"#, state: &state)
        #expect(throws: AssistantError.self) {
            try OpenAIStreamParser.events(fromPayload: #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#, state: &state)
        }
    }
}
