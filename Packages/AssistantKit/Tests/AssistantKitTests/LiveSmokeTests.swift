import Foundation
import Testing
@testable import AssistantKit

/// Opt-in: `KEELMAC_LIVE_OLLAMA=1 swift test` talks to the Ollama on this Mac.
@Suite("Live Ollama", .enabled(if: ProcessInfo.processInfo.environment["KEELMAC_LIVE_OLLAMA"] == "1"))
struct LiveSmokeTests {
    @Test func listsModelsAndAnswers() async throws {
        let client = OllamaClient()
        try await client.ping()
        let models = try await client.listModels()
        let model = try #require(models.first(where: { $0.supportsTools != false })?.name)
        let session = ChatSession(backend: client, model: model, tools: [], systemPrompt: "Reply with the single word OK.")
        let (events, error) = await collect(await session.send("Say OK.", context: nil))
        #expect(error == nil)
        #expect(events.contains { if case .finished = $0 { true } else { false } })
    }
}
