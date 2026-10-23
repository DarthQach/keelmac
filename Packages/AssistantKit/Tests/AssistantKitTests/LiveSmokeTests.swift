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

/// Opt-in: `KEELMAC_LIVE_LMSTUDIO=1 swift test` talks to the LM Studio server on this Mac (start it first).
@Suite("Live LM Studio", .enabled(if: ProcessInfo.processInfo.environment["KEELMAC_LIVE_LMSTUDIO"] == "1"))
struct LiveLMStudioSmokeTests {
    @Test func listsModelsAndAnswers() async throws {
        let client = LMStudioClient()
        try await client.ping()
        let models = try await client.listModels()
        // Embedding-only installs list nothing; ping and the model list are then the whole check.
        guard let model = models.first(where: { $0.supportsTools != false })?.name ?? models.first?.name else { return }
        let session = ChatSession(backend: client, model: model, tools: [], systemPrompt: "Reply with the single word OK.")
        let (events, error) = await collect(await session.send("Say OK.", context: nil))
        #expect(error == nil)
        #expect(events.contains { if case .finished = $0 { true } else { false } })
    }
}
