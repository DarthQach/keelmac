import Foundation
import Testing
@testable import AssistantKit

func fixture(_ name: String, _ ext: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func json(_ data: Data?) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: try #require(data))
}

struct TestError: Error {}

/// Plays one scripted event list per chat call and records every request.
final class ScriptedBackend: ChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[ChatEvent]]
    private var _requests: [ChatRequest] = []

    init(_ scripts: [[ChatEvent]]) { self.scripts = scripts }

    var requests: [ChatRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func ping() async throws {}
    func listModels() async throws -> [ModelInfo] { [ModelInfo(name: "scripted")] }

    func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let events: [ChatEvent] = lock.withLock {
            _requests.append(request)
            return scripts.isEmpty ? [.done(nil)] : scripts.removeFirst()
        }
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish()
        }
    }
}

/// Yields one token, then never finishes until cancelled.
struct HangingBackend: ChatBackend {
    func ping() async throws {}
    func listModels() async throws -> [ModelInfo] { [] }
    func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { c in
            c.yield(.token("a"))
            let t = Task { try? await Task.sleep(for: .seconds(60)); c.finish() }
            c.onTermination = { _ in t.cancel() }
        }
    }
}

final class RecordingTool: AssistantTool, @unchecked Sendable {
    let name: String
    let description = "A test tool."
    let parameters: JSONValue = .schema(properties: ["limit": .property("integer", "How many")])
    private let lock = NSLock()
    private var _calls: [JSONValue] = []
    private let output: String
    private let fails: Bool

    init(name: String, output: String = "ok", fails: Bool = false) {
        self.name = name
        self.output = output
        self.fails = fails
    }

    var calls: [JSONValue] { lock.lock(); defer { lock.unlock() }; return _calls }

    func call(_ arguments: JSONValue) async throws -> String {
        lock.withLock { _calls.append(arguments) }
        if fails { throw TestError() }
        return output
    }
}

func drain(_ stream: AsyncThrowingStream<ChatEvent, Error>) async -> ([ChatEvent], AssistantError?) {
    var events: [ChatEvent] = []
    do { for try await e in stream { events.append(e) } } catch { return (events, error as? AssistantError) }
    return (events, nil)
}

func collect(_ stream: AsyncThrowingStream<SessionEvent, Error>) async -> (events: [SessionEvent], error: AssistantError?) {
    var events: [SessionEvent] = []
    do {
        for try await e in stream { events.append(e) }
    } catch {
        return (events, error as? AssistantError)
    }
    return (events, nil)
}
