import AppKit
import AssistantKit

/// What the app knows about each local server: its name, where its address is stored, how to get it.
extension AssistantProvider {
    /// Proper nouns, the same in every language.
    var name: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        }
    }

    var bundleID: String {
        switch self {
        case .ollama: OwnerResolver.ollamaBundleID
        case .lmStudio: OwnerResolver.lmStudioBundleID
        }
    }

    var downloadURL: URL {
        switch self {
        case .ollama: URL(string: "https://ollama.com/download")!
        case .lmStudio: URL(string: "https://lmstudio.ai/download")!
        }
    }

    /// The preference holding this server's address; each server keeps its own.
    var hostKey: String {
        switch self {
        case .ollama: Preferences.Key.assistantHost
        case .lmStudio: Preferences.Key.assistantLMStudioHost
        }
    }

    /// A Terminal command that downloads a model that can use tools.
    var pullCommand: String {
        switch self {
        case .ollama: "ollama pull qwen3"
        case .lmStudio: "lms get qwen/qwen3-8b"
        }
    }

    var other: AssistantProvider { self == .ollama ? .lmStudio : .ollama }

    /// A LaunchServices lookup; no network.
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    /// Opens the app, or its download page when it isn't installed.
    func open() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(downloadURL)
        }
    }

    static var stored: AssistantProvider {
        AssistantProvider(rawValue: UserDefaults.standard.string(forKey: Preferences.Key.assistantProvider) ?? "") ?? .ollama
    }

    /// The first-enable guess: Ollama, unless only LM Studio is installed.
    static func detectInitial(isInstalled: (AssistantProvider) -> Bool = { $0.isInstalled }) -> AssistantProvider {
        !isInstalled(.ollama) && isInstalled(.lmStudio) ? .lmStudio : .ollama
    }
}
