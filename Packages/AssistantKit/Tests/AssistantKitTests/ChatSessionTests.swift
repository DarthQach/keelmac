import Foundation
import Testing
@testable import AssistantKit

@Suite("ChatSession")
struct ChatSessionTests {
    private func makeSession(_ backend: any ChatBackend, tools: [any AssistantTool], maxToolRounds: Int = 4, maxHistory: Int = 24) -> ChatSession {
        ChatSession(backend: backend, model: "m", tools: tools, systemPrompt: "SYS", maxToolRounds: maxToolRounds, maxHistory: maxHistory)
    }

    @Test func toolRoundTrip() async throws {
        let call = ToolCall(name: "get_health", arguments: ["limit": 3])
        let backend = ScriptedBackend([
            [.toolCalls([call]), .done(nil)],
            [.token("Score "), .token("82."), .done(nil)],
        ])
        let tool = RecordingTool(name: "get_health", output: "Score 82/100")
        let session = makeSession(backend, tools: [tool])
        let (events, error) = await collect(await session.send("How healthy?", context: "[Current screen]\nDashboard"))
        #expect(error == nil)
        #expect(events == [
            .toolStarted(call),
            .toolFinished(ToolResult(call: call, output: "Score 82/100", isError: false)),
            .token("Score "), .token("82."),
            .finished(.assistant("Score 82.")),
        ])
        #expect(tool.calls == [["limit": 3]])
        let messages = await session.messages
        #expect(messages.map(\.role) == [.system, .user, .assistant, .tool, .assistant])
        #expect(messages[1].content == "[Current screen]\nDashboard\n\nHow healthy?")
        #expect(messages[2].toolCalls == [call])
        #expect(messages[3].toolName == "get_health")
        #expect(messages[3].toolCallID == call.id)
        #expect(messages[3].content == "Score 82/100")
        #expect(backend.requests.count == 2)
        #expect(backend.requests[0].tools.map(\.name) == ["get_health"])
        #expect(backend.requests[1].messages.count == 4)
    }

    @Test func failingToolKeepsGoing() async throws {
        let call = ToolCall(name: "broken")
        let backend = ScriptedBackend([[.toolCalls([call])], [.token("Sorry.")]])
        let session = makeSession(backend, tools: [RecordingTool(name: "broken", fails: true)])
        let (events, error) = await collect(await session.send("x", context: nil))
        #expect(error == nil)
        guard case .toolFinished(let result) = events[1] else { Issue.record("expected toolFinished"); return }
        #expect(result.isError)
        #expect(result.output.contains("broken failed"))
        #expect(events.last == .finished(.assistant("Sorry.")))
    }

    @Test func unknownToolIsReportedToTheModel() async throws {
        let call = ToolCall(name: "nope")
        let backend = ScriptedBackend([[.toolCalls([call])], [.token("ok")]])
        let session = makeSession(backend, tools: [])
        let (events, _) = await collect(await session.send("x", context: nil))
        guard case .toolFinished(let result) = events[1] else { Issue.record("expected toolFinished"); return }
        #expect(result.isError)
        #expect(backend.requests[1].messages.last?.role == .tool)
    }

    @Test func tooManyRoundsWithoutText() async throws {
        let call = ToolCall(name: "t")
        let backend = ScriptedBackend(Array(repeating: [.toolCalls([call])], count: 10))
        let session = makeSession(backend, tools: [RecordingTool(name: "t")], maxToolRounds: 2)
        let (_, error) = await collect(await session.send("x", context: nil))
        #expect(error == .tooManyToolRounds)
        #expect(backend.requests.count == 3)
        #expect(await session.messages.count == 1)   // rolled back to the system prompt
    }

    @Test func tooManyRoundsWithTextFinishes() async throws {
        let call = ToolCall(name: "t")
        let backend = ScriptedBackend(Array(repeating: [.token("partial"), .toolCalls([call])], count: 10))
        let session = makeSession(backend, tools: [RecordingTool(name: "t")], maxToolRounds: 1)
        let (events, error) = await collect(await session.send("x", context: nil))
        #expect(error == nil)
        #expect(events.last == .finished(.assistant("partial")))
    }

    @Test func cancelKeepsPartialText() async throws {
        let session = makeSession(HangingBackend(), tools: [])
        let stream = await session.send("x", context: nil)
        let consumer = Task { () -> (events: [SessionEvent], error: AssistantError?) in
            var events: [SessionEvent] = []
            do {
                for try await e in stream {
                    events.append(e)
                    if events.count == 1 { await session.cancel() }
                }
            } catch { return (events, error as? AssistantError) }
            return (events, nil)
        }
        let (events, error) = await consumer.value
        #expect(events == [.token("a")])
        #expect(error == .cancelled)
        let messages = await session.messages
        #expect(messages.map(\.role) == [.system, .user, .assistant])
        #expect(messages[2].content == "a")
    }

    @Test func backendFailureRollsBack() async throws {
        struct Failing: ChatBackend {
            func ping() async throws {}
            func listModels() async throws -> [ModelInfo] { [] }
            func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
                AsyncThrowingStream { $0.finish(throwing: AssistantError.unreachable("down")) }
            }
        }
        let session = makeSession(Failing(), tools: [])
        let (_, error) = await collect(await session.send("x", context: nil))
        #expect(error == .unreachable("down"))
        #expect(await session.messages.count == 1)
    }

    @Test func historyTrimKeepsSystemAndWholePairs() async throws {
        let call = ToolCall(name: "t")
        var scripts: [[ChatEvent]] = []
        for _ in 0..<6 { scripts.append([.toolCalls([call])]); scripts.append([.token("r")]) }
        let backend = ScriptedBackend(scripts)
        let session = makeSession(backend, tools: [RecordingTool(name: "t")], maxHistory: 6)
        for i in 0..<6 { _ = await collect(await session.send("q\(i)", context: nil)) }
        let messages = await session.messages
        #expect(messages.first?.role == .system)
        #expect(messages.count <= 1 + 6 + 3)   // system + history + this turn's assistant/tool/assistant
        // The trim is what the server sees: the first request of every turn stays within the limit.
        #expect(backend.requests.filter { $0.messages.last?.role == .user }.allSatisfy { $0.messages.count <= 1 + 6 })
        #expect(messages[1].role != .tool)
        // Every tool result still follows the assistant message that asked for it.
        for (i, m) in messages.enumerated() where m.role == .tool {
            #expect(messages[i - 1].role == .assistant && !messages[i - 1].toolCalls.isEmpty)
        }
    }

    @Test func toolsCanBeSwitchedOff() async throws {
        let backend = ScriptedBackend([[.token("hi")]])
        let session = makeSession(backend, tools: [RecordingTool(name: "t")])
        await session.setUseTools(false)
        _ = await collect(await session.send("x", context: nil))
        #expect(backend.requests[0].tools.isEmpty)
    }

    @Test func resetAndSystemPrompt() async throws {
        let session = makeSession(ScriptedBackend([[.token("hi")]]), tools: [])
        _ = await collect(await session.send("x", context: nil))
        await session.setSystemPrompt("NEW")
        #expect(await session.messages[0] == .system("NEW"))
        await session.reset(systemPrompt: "AGAIN")
        #expect(await session.messages == [.system("AGAIN")])
    }
}
