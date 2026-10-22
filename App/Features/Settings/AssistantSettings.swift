import AssistantKit
import SwiftUI

/// Settings › Assistant: opt in, point at Ollama, pick a model. Nothing is contacted until the toggle is on.
struct AssistantSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.Key.assistantEnabled) private var enabled = false
    @AppStorage(Preferences.Key.assistantHost) private var host = "http://localhost:11434"
    @AppStorage(Preferences.Key.assistantModel) private var modelName = ""
    @State private var hostDraft = ""
    @State private var hostError: String?
    @State private var testing = false
    @State private var result: AssistantModel.Status?

    var body: some View {
        Form {
            Section {
                Toggle("Use a local assistant (Ollama)", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        result = nil
                        model.assistant.settingsChanged()
                        if on { test() }
                    }
            } footer: {
                Text("Off by default. KeelMac contacts nothing until you turn this on, and then only the Ollama at the address below.")
                    .font(.callout).foregroundStyle(.kmFgMuted)
            }
            Section {
                TextField("Ollama address", text: $hostDraft)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { applyHost() }
                    .disabled(!enabled)
                if let hostError {
                    Text(verbatim: hostError).foregroundStyle(.kmDanger).font(.callout)
                }
                Picker("Model", selection: $modelName) {
                    Text("Automatic (first model that supports tools)").tag("")
                    ForEach(model.assistant.models) { m in
                        Text(verbatim: m.supportsTools == false ? "\(m.name) · \(String(localized: "no tools"))" : m.name).tag(m.name)
                    }
                    if !modelName.isEmpty, !model.assistant.models.contains(where: { $0.name == modelName }) {
                        Text(verbatim: modelName).tag(modelName)
                    }
                }
                .onChange(of: modelName) { _, _ in model.assistant.settingsChanged() }
                .disabled(!enabled)
                HStack(spacing: 12) {
                    Button("Test connection") { applyHost(); test() }.disabled(!enabled || testing)
                    if testing {
                        ProgressView().controlSize(.small)
                    } else if let result {
                        badge(result)
                    }
                }
                if enabled, model.assistant.models.isEmpty, !testing {
                    CommandLabel(command: "ollama pull qwen3")
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("KeelMac talks only to the Ollama at this address. It sends your question, a summary of the current screen and the names, sizes and dates of what you select. It never sends file contents, and nothing else leaves your Mac.")
                    .font(.callout).foregroundStyle(.kmFgMuted)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            hostDraft = host
            if enabled, model.assistant.models.isEmpty, !VisualFixtures.enabled { test() }
        }
    }

    @ViewBuilder private func badge(_ status: AssistantModel.Status) -> some View {
        switch status {
        case .idle, .streaming, .loadingModel:
            StatusBadge(text: "Connected, \(model.assistant.models.count) models", tone: .success)
        case .noModel: StatusBadge(text: "Connected, no models", tone: .warning)
        case .unreachable: StatusBadge(text: "Can’t reach Ollama", tone: .warning)
        case .checking: StatusBadge(text: "Checking…", tone: .neutral)
        case .disabled: StatusBadge(text: "Off", tone: .neutral)
        case .error(let message): Text(verbatim: message).font(.callout).foregroundStyle(.kmDanger).lineLimit(2)
        }
    }

    /// Accepts http only for this Mac; anything else must be https so a typo can't send questions in the clear.
    private func applyHost() {
        let trimmed = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let name = url.host, ["http", "https"].contains(scheme) else {
            hostError = String(localized: "Enter an address like http://localhost:11434.")
            return
        }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(name.lowercased())
        guard loopback || scheme == "https" else {
            hostError = String(localized: "Only this Mac can be reached over http. Use https for another machine.")
            return
        }
        hostError = nil
        if trimmed != host {
            host = trimmed
            result = nil
            model.assistant.settingsChanged()
        }
    }

    private func test() {
        guard enabled else { return }
        testing = true
        Task {
            result = await model.assistant.testConnection()
            testing = false
        }
    }
}
