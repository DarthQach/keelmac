import Foundation

public struct ModelInfo: Sendable, Codable, Hashable, Identifiable {
    public let name: String
    public let sizeBytes: Int64?
    public let parameterSize: String?
    public let family: String?
    /// As reported by the server ("completion", "tools", "vision", "thinking"); empty when the server doesn't say.
    public let capabilities: [String]
    public var id: String { name }
    /// nil when the server didn't report capabilities.
    public var supportsTools: Bool? { capabilities.isEmpty ? nil : capabilities.contains("tools") }

    public init(name: String, sizeBytes: Int64? = nil, parameterSize: String? = nil, family: String? = nil, capabilities: [String] = []) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.parameterSize = parameterSize
        self.family = family
        self.capabilities = capabilities
    }
}

public struct ChatOptions: Sendable, Hashable {
    public var temperature: Double
    public var numCtx: Int
    /// How long the server keeps the model loaded after a reply (Ollama duration string).
    public var keepAlive: String

    public init(temperature: Double = 0.2, numCtx: Int = 8192, keepAlive: String = "10m") {
        self.temperature = temperature
        self.numCtx = numCtx
        self.keepAlive = keepAlive
    }
}

public struct ChatRequest: Sendable, Hashable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    public var think: Bool
    public var options: ChatOptions

    public init(model: String, messages: [ChatMessage], tools: [ToolSpec] = [], think: Bool = false, options: ChatOptions = .init()) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.think = think
        self.options = options
    }
}

public struct ChatUsage: Sendable, Hashable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalDuration: TimeInterval?

    public init(promptTokens: Int?, completionTokens: Int?, totalDuration: TimeInterval?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalDuration = totalDuration
    }
}

public enum ChatEvent: Sendable, Hashable {
    case token(String)
    case thinking(String)
    case toolCalls([ToolCall])
    case done(ChatUsage?)
}

/// Anything that can answer a chat request: Ollama, or a fixture in tests and screenshots.
public protocol ChatBackend: Sendable {
    /// Throws `AssistantError.unreachable` when the server doesn't answer.
    func ping() async throws
    func listModels() async throws -> [ModelInfo]
    func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

public enum AssistantError: Error, Sendable, Hashable {
    case unreachable(String)
    case httpStatus(Int, String)
    case modelNotFound(String)
    case toolsUnsupported(String)
    case decoding(String)
    case cancelled
    case toolFailed(name: String, String)
    case tooManyToolRounds
}
