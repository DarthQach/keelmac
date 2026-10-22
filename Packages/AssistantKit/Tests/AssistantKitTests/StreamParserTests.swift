import Foundation
import Testing
@testable import AssistantKit

@Suite("Ollama stream parsing")
struct StreamParserTests {
    @Test func tokenLine() throws {
        let events = try OllamaStreamParser.events(fromLine: #"{"message":{"role":"assistant","content":"Hello"},"done":false}"#)
        #expect(events == [.token("Hello")])
    }

    @Test func thinkingLine() throws {
        let events = try OllamaStreamParser.events(fromLine: #"{"message":{"role":"assistant","content":"","thinking":"hmm"},"done":false}"#)
        #expect(events == [.thinking("hmm")])
    }

    @Test func toolCallWithNestedArguments() throws {
        let lines = String(decoding: try fixture("chat-toolcall", "ndjson"), as: UTF8.self).split(separator: "\n").map(String.init)
        let events = try lines.flatMap(OllamaStreamParser.events(fromLine:))
        #expect(events.count == 2)
        guard case .toolCalls(let calls) = events[0] else { Issue.record("expected tool calls"); return }
        #expect(calls.count == 1)
        #expect(calls[0].name == "inspect_path")
        #expect(calls[0].arguments["path"]?.stringValue == "~/Library/Caches")
        #expect(calls[0].arguments["limit"]?.intValue == 5)
        #expect(calls[0].arguments["options"]?["deep"]?.boolValue == true)
        #expect(!calls[0].id.isEmpty)
        guard case .done(let usage) = events[1] else { Issue.record("expected done"); return }
        #expect(usage?.promptTokens == 300)
        #expect(usage?.completionTokens == 30)
        #expect(abs((usage?.totalDuration ?? 0) - 1.2) < 0.001)
    }

    @Test func tokensFixture() throws {
        let lines = String(decoding: try fixture("chat-tokens", "ndjson"), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let events = try lines.flatMap(OllamaStreamParser.events(fromLine:))
        let text = events.compactMap { if case .token(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "Hello, world.")
        guard case .done(let usage) = events.last else { Issue.record("expected done last"); return }
        #expect(abs((usage?.totalDuration ?? 0) - 2.86) < 0.01)
    }

    @Test func blankAndMalformedLines() throws {
        #expect(try OllamaStreamParser.events(fromLine: "   ") == [])
        #expect(throws: AssistantError.decoding("{not json")) { try OllamaStreamParser.events(fromLine: "{not json") }
    }

    @Test func midStreamError() {
        #expect(throws: AssistantError.httpStatus(200, "boom")) { try OllamaStreamParser.events(fromLine: #"{"error":"boom"}"#) }
    }
}

@Suite("Think tag filter")
struct ThinkTagFilterTests {
    @Test func splitAcrossChunks() {
        var f = ThinkTagFilter()
        let a = f.feed("<thi")
        #expect(a == ("", ""))
        let b = f.feed("nk>abc")
        #expect(b.text == "")
        let c = f.feed("def</think>\nHi")
        #expect(b.thinking + c.thinking == "abcdef")
        #expect(c.text == "Hi")
        #expect(f.feed(" there") == (" there", ""))
    }

    @Test func plainTextPassesThrough() {
        var f = ThinkTagFilter()
        #expect(f.feed("Hel") == ("Hel", ""))
        #expect(f.feed("lo") == ("lo", ""))
        #expect(f.flush() == "")
    }

    @Test func partialPrefixFlushes() {
        var f = ThinkTagFilter()
        #expect(f.feed("<") == ("", ""))
        #expect(f.flush() == "<")
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test func roundTrip() throws {
        let v: JSONValue = ["a": 1, "b": [true, nil, "x"], "c": ["d": 2.5]]
        let data = try JSONEncoder().encode(v)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == v)
        #expect(v["a"]?.intValue == 1)
        #expect(v["c"]?["d"]?.doubleValue == 2.5)
        #expect(JSONValue.string("7").intValue == 7)
        #expect(JSONValue.number(4).stringValue == "4")
    }

    @Test func schemaShape() {
        let s = JSONValue.schema(properties: ["limit": .property("integer", "How many", enum: nil), "sortBy": .property("string", "Sort", enum: ["cpu", "memory"])], required: ["limit"])
        #expect(s["type"]?.stringValue == "object")
        #expect(s["required"]?.arrayValue == [.string("limit")])
        #expect(s["properties"]?["sortBy"]?["enum"]?.arrayValue?.count == 2)
    }
}
