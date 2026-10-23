import Foundation
import Testing
@testable import AssistantKit

@Suite("OllamaClient")
struct OllamaClientTests {
    let base = URL(string: "http://localhost:11434")!

    @Test func listModelsParsesTags() async throws {
        let tags = try fixture("tags", "json")
        let transport = StubTransport { req in
            #expect(req.url?.path == "/api/tags")
            return (200, tags)
        }
        let models = try await OllamaClient(baseURL: base, transport: transport).listModels()
        #expect(models.map(\.name) == ["qwen3.8:27b-mlx", "llama2:latest"])
        #expect(models[0].supportsTools == true)
        #expect(models[1].supportsTools == false)
        #expect(models[0].parameterSize == "27B")
        #expect(models[0].sizeBytes == 18_174_721_847)
        #expect(ModelInfo(name: "x").supportsTools == nil)
    }

    @Test func pingMapsConnectionErrors() async {
        let transport = StubTransport { _ in throw URLError(.cannotConnectToHost) }
        await #expect(throws: AssistantError.self) {
            try await OllamaClient(baseURL: base, transport: transport).ping()
        }
        do {
            try await OllamaClient(baseURL: base, transport: transport).ping()
        } catch let e as AssistantError {
            guard case .unreachable = e else { Issue.record("expected unreachable, got \(e)"); return }
        } catch { Issue.record("wrong error type") }
    }

    @Test func modelNotFound() async {
        let transport = StubTransport { _ in (404, Data(#"{"error":"model 'nope' not found"}"#.utf8)) }
        let client = OllamaClient(baseURL: base, transport: transport)
        let (_, error) = await drain(client.chat(ChatRequest(model: "nope", messages: [.user("hi")])))
        #expect(error == .modelNotFound("nope"))
    }

    @Test func toolsUnsupported() async {
        let transport = StubTransport { _ in (400, Data(#"{"error":"registry.ollama.ai/library/llama2:latest does not support tools"}"#.utf8)) }
        let client = OllamaClient(baseURL: base, transport: transport)
        let (_, error) = await drain(client.chat(ChatRequest(model: "llama2:latest", messages: [.user("hi")])))
        #expect(error == .toolsUnsupported("llama2:latest"))
    }

    @Test func otherStatusIsHTTPError() async throws {
        let transport = StubTransport { _ in (500, Data("oops".utf8)) }
        await #expect(throws: AssistantError.httpStatus(500, "oops")) {
            try await OllamaClient(baseURL: base, transport: transport).listModels()
        }
    }

    @Test func chatRequestBody() async throws {
        let transport = StubTransport { _ in (200, try fixture("chat-tokens", "ndjson")) }
        let client = OllamaClient(baseURL: base, transport: transport)
        let tool = RecordingTool(name: "get_health")
        let call = ToolCall(name: "get_health", arguments: .object([:]))
        let request = ChatRequest(model: "m", messages: [
            .system("sys"), .user("q"), .assistant("", toolCalls: [call]), .tool(name: "get_health", output: "82"),
        ], tools: [tool.spec])
        let (events, error) = await drain(client.chat(request))
        #expect(error == nil)
        let text = events.compactMap { if case .token(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "Hello, world.")
        guard case .done(let usage) = events.last else { Issue.record("expected done"); return }
        #expect(usage?.completionTokens == 72)

        let req = try #require(transport.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/api/chat")
        let body = try json(req.httpBody)
        #expect(body["stream"]?.boolValue == true)
        #expect(body["think"]?.boolValue == false)
        #expect(body["keep_alive"]?.stringValue == "10m")
        #expect(body["options"]?["num_ctx"]?.intValue == 8192)
        #expect(body["tools"]?[0]?["type"]?.stringValue == "function")
        #expect(body["tools"]?[0]?["function"]?["name"]?.stringValue == "get_health")
        #expect(body["tools"]?[0]?["function"]?["parameters"]?["type"]?.stringValue == "object")
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.count == 4)
        #expect(messages[2]["tool_calls"]?[0]?["function"]?["name"]?.stringValue == "get_health")
        #expect(messages[3]["role"]?.stringValue == "tool")
        #expect(messages[3]["tool_name"]?.stringValue == "get_health")
        #expect(messages[0]["tool_calls"] == nil)
    }

    @Test func noToolsOmitsKey() async throws {
        let transport = StubTransport { _ in (200, try fixture("chat-tokens", "ndjson")) }
        _ = await drain(OllamaClient(baseURL: base, transport: transport).chat(ChatRequest(model: "m", messages: [.user("q")])))
        let body = try json(try #require(transport.requests.first?.httpBody))
        #expect(body["tools"] == nil)
    }

    @Test func thinkTagsBecomeThinking() async throws {
        let lines = [
            #"{"message":{"content":"<think>plan"},"done":false}"#,
            #"{"message":{"content":"ning</think>Answer"},"done":false}"#,
            #"{"message":{"content":""},"done":true}"#,
        ].joined(separator: "\n")
        let transport = StubTransport { _ in (200, Data(lines.utf8)) }
        let (events, error) = await drain(OllamaClient(baseURL: base, transport: transport).chat(ChatRequest(model: "m", messages: [.user("q")])))
        #expect(error == nil)
        let text = events.compactMap { if case .token(let t) = $0 { t } else { nil } }.joined()
        let thinking = events.compactMap { if case .thinking(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "Answer")
        #expect(thinking == "planning")
    }
}
