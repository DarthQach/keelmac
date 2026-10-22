import AssistantKit
import Foundation

/// The backend under `-uitest`: no server, one model, a canned tool call and answer.
struct FixtureChatBackend: ChatBackend {
    func ping() async throws {
        if VisualFixtures.argument("-fixture-assistant") == "unreachable" { throw AssistantError.unreachable("fixture") }
    }

    func listModels() async throws -> [ModelInfo] {
        VisualFixtures.argument("-fixture-assistant") == "noModel" ? [] : [ModelInfo(name: "qwen3:8b", capabilities: ["completion", "tools"])]
    }

    func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { c in
            if VisualFixtures.argument("-fixture-assistant") == "error" {
                c.finish(throwing: AssistantError.httpStatus(500, "model runner has stopped"))
                return
            }
            if request.messages.last?.role == .user, request.tools.contains(where: { $0.name == "get_health" }) {
                c.yield(.toolCalls([ToolCall(name: "get_health")]))
            } else {
                for word in "Your Mac is in good shape: 284 GB free and a Health Score of 82. The 42 GB Cleanup found is the quickest win: Cleanup › Clean (keelmac://open/cleanup).".split(separator: " ") {
                    c.yield(.token(word + " "))
                }
            }
            c.yield(.done(nil))
            c.finish()
        }
    }
}
