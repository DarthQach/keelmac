import Foundation

public enum ChatRole: String, Sendable, Codable { case system, user, assistant, tool }

/// A request from the model to run one tool. Ollama sends no id, so one is minted on parse; LM Studio sends its own.
public struct ToolCall: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: JSONValue

    public init(id: String = UUID().uuidString, name: String, arguments: JSONValue = .object([:])) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult: Sendable, Hashable {
    public let call: ToolCall
    public let output: String
    public let isError: Bool

    public init(call: ToolCall, output: String, isError: Bool) {
        self.call = call
        self.output = output
        self.isError = isError
    }
}

public struct ChatMessage: Sendable, Codable, Hashable {
    public var role: ChatRole
    public var content: String
    /// Assistant messages only.
    public var toolCalls: [ToolCall]
    /// Tool messages only: which tool produced `content`.
    public var toolName: String?
    /// Tool messages only: the call this answers. OpenAI-style servers (LM Studio) require it; Ollama ignores it.
    public var toolCallID: String?

    public init(role: ChatRole, content: String, toolCalls: [ToolCall] = [], toolName: String? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
        self.toolCallID = toolCallID
    }

    public static func system(_ content: String) -> ChatMessage { .init(role: .system, content: content) }
    public static func user(_ content: String) -> ChatMessage { .init(role: .user, content: content) }
    public static func assistant(_ content: String, toolCalls: [ToolCall] = []) -> ChatMessage { .init(role: .assistant, content: content, toolCalls: toolCalls) }
    public static func tool(name: String, output: String) -> ChatMessage { .init(role: .tool, content: output, toolName: name) }
    public static func tool(call: ToolCall, output: String) -> ChatMessage { .init(role: .tool, content: output, toolName: call.name, toolCallID: call.id) }
}

/// What the model is told about a tool.
public struct ToolSpec: Sendable, Codable, Hashable {
    public let name: String
    public let description: String
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A read-only lookup the model may ask for. Implementations return compact text the model can quote.
public protocol AssistantTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
    func call(_ arguments: JSONValue) async throws -> String
}

extension AssistantTool {
    public var spec: ToolSpec { ToolSpec(name: name, description: description, parameters: parameters) }
}
