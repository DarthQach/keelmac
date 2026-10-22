import AppKit
import AssistantKit
import SwiftUI

/// S21: the trailing Assistant panel, available on every route.
struct AssistantPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let a = model.assistant
        VStack(spacing: 0) {
            header(a)
            Divider()
            switch a.status {
            case .disabled:
                PanelState(symbol: "sparkles", title: "The Assistant is off.",
                           message: "Turn it on in Settings to ask about what you see. It only talks to Ollama on this Mac.") {
                    Button("Open Settings…") { openSettings() }.buttonStyle(.kmPrimary)
                }
            case .checking:
                ProgressView("Checking Ollama…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unreachable(let host):
                PanelState(symbol: "bolt.horizontal.circle", title: "Ollama isn’t running.",
                           message: "Open Ollama, then try again. KeelMac looks for it at this address:") {
                    Text(verbatim: host).font(.system(.callout, design: .monospaced)).foregroundStyle(.kmFgMuted).textSelection(.enabled)
                    HStack {
                        Button("Open Ollama") { openOllama() }.buttonStyle(.kmPrimary)
                        Button("Try again") { Task { await a.refreshStatus() } }
                    }
                }
            case .noModel:
                PanelState(symbol: "shippingbox", title: "No models in Ollama.",
                           message: "Download one in Terminal, then try again. A model that supports tools can look things up for you.") {
                    CommandLabel(command: "ollama pull qwen3")
                    Button("Try again") { Task { await a.refreshStatus() } }.buttonStyle(.kmPrimary)
                }
            case .idle, .loadingModel, .streaming, .error:
                conversation(a)
            }
        }
        .background(Color.kmBg)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "keelmac" else { return .systemAction }
            model.open(url)
            return .handled
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.panel")
    }

    private func header(_ a: AssistantModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.kmAccent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Assistant").font(.headline).accessibilityIdentifier("assistant.title")
                if !a.modelName.isEmpty, a.status != .disabled {
                    Text(verbatim: a.modelName).font(.system(.caption, design: .monospaced)).foregroundStyle(.kmFgMuted).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            badge(a.status)
            Menu {
                Button("Clear conversation") { a.clear() }.disabled(a.turns.isEmpty)
                Button("Assistant Settings…") { openSettings() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Assistant options")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private func badge(_ status: AssistantModel.Status) -> some View {
        switch status {
        case .checking: StatusBadge(text: "Checking…", tone: .neutral)
        case .loadingModel: StatusBadge(text: "Loading model…", tone: .neutral)
        case .unreachable: StatusBadge(text: "Not reachable", tone: .warning)
        case .noModel: StatusBadge(text: "No models", tone: .warning)
        case .disabled: StatusBadge(text: "Off", tone: .neutral)
        case .idle, .streaming, .error: EmptyView()
        }
    }

    // MARK: Conversation

    private func conversation(_ a: AssistantModel) -> some View {
        VStack(spacing: 0) {
            if a.turns.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "sparkles").font(.largeTitle.weight(.light)).foregroundStyle(.kmFgMuted).accessibilityHidden(true)
                    Text("Ask about what you see.").font(.title3.weight(.semibold))
                    Text("Answers come from Ollama on this Mac. KeelMac shares the names, sizes and dates of what is on screen, never file contents.")
                        .font(.callout).foregroundStyle(.kmFgMuted).multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript(a)
            }
            if a.canSend, !a.suggestions.isEmpty {
                suggestions(a)
            }
            if case .error(let message) = a.status {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(verbatim: message).font(.callout).foregroundStyle(.kmDanger)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.kmDanger)
                    }
                    Button("Try again") { a.retryLast() }.controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier("assistant.error")
            }
            Divider()
            composer(a)
        }
    }

    private func transcript(_ a: AssistantModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(a.turns) { turn in
                        TurnView(turn: turn, status: a.status).id(turn.id)
                    }
                    if a.toolsUnavailable {
                        Text("This model can’t look things up; answers use only what is on screen.")
                            .font(.caption).foregroundStyle(.kmFgMuted)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: a.turns.last) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .accessibilityIdentifier("assistant.transcript")
    }

    private func suggestions(_ a: AssistantModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(a.suggestions, id: \.self) { s in
                    Button {
                        a.send(s)
                    } label: {
                        Text(verbatim: s).font(.callout).lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.kmSurface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.kmBorder))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("assistant.suggestions")
    }

    private func composer(_ a: AssistantModel) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this screen…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.kmSurface, in: RoundedRectangle(cornerRadius: Metrics.radiusControl))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusControl).strokeBorder(focused ? Color.kmAccent : Color.kmBorder))
                .focused($focused)
                .onSubmit { submit(a) }
                .accessibilityIdentifier("assistant.input")
            if a.status == .streaming || a.status == .loadingModel {
                Button { a.stop() } label: { Image(systemName: "stop.fill").frame(width: 14, height: 14) }
                    .help("Stop")
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("assistant.stop")
            } else {
                Button { submit(a) } label: { Image(systemName: "arrow.up").frame(width: 14, height: 14) }
                    .buttonStyle(.kmPrimary)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !a.canSend)
                    .help("Send")
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("assistant.send")
            }
        }
        .padding(12)
    }

    private func submit(_ a: AssistantModel) {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, a.canSend else { return }
        draft = ""
        a.send(text)
    }

    private func openOllama() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: OwnerResolver.ollamaBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
        }
    }
}

/// One empty, blocked or error state, in the panel's narrow column.
private struct PanelState<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.largeTitle.weight(.light))
                .padding(16)
                .background(.kmSurfaceMuted, in: RoundedRectangle(cornerRadius: Metrics.radius))
                .foregroundStyle(.kmFgMuted)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(message).font(.callout).foregroundStyle(.kmFgMuted).multilineTextAlignment(.center)
            actions
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TurnView: View {
    let turn: AssistantModel.Turn
    let status: AssistantModel.Status

    var body: some View {
        switch turn.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 32)
                Text(verbatim: text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.kmAccentSoft, in: RoundedRectangle(cornerRadius: Metrics.radius))
            }
            .accessibilityIdentifier("assistant.turn.user")
        case .assistant(let text):
            VStack(alignment: .leading, spacing: 8) {
                if text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(status == .loadingModel ? "Loading the model… the first answer takes a few seconds." : "Answering…")
                            .font(.callout).foregroundStyle(.kmFgMuted)
                    }
                } else {
                    Text(AssistantMarkdown.attributed(text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if turn.isStreaming { ProgressView().controlSize(.mini) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .kmGroup(padding: 12)
            .accessibilityIdentifier("assistant.turn.assistant")
        case .tool(let name, let output, let isError):
            DisclosureGroup {
                Text(verbatim: output.isEmpty ? "…" : output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    if output.isEmpty {
                        ProgressView().controlSize(.mini)
                        Text("Looking up \(AssistantMarkdown.toolTitle(name))…")
                    } else {
                        Image(systemName: isError ? "exclamationmark.triangle" : "magnifyingglass").accessibilityHidden(true)
                        Text("Looked up \(AssistantMarkdown.toolTitle(name))")
                    }
                }
                .font(.callout)
                .foregroundStyle(isError ? Color.kmWarningInk : Color.kmFgMuted)
            }
            .accessibilityIdentifier("assistant.turn.tool")
        }
    }
}

/// Turns the model's plain text into attributed text with clickable KeelMac links.
enum AssistantMarkdown {
    static func attributed(_ text: String) -> AttributedString {
        var source = text
        for route in Route.allCases {
            let bare = "keelmac://open/\(route.rawValue)"
            let label = String(localized: "Open \(route.name)")
            // A markdown link the model wrote itself is kept; a bare URL becomes "(Open Cleanup)".
            source = source.replacingOccurrences(of: "](\(bare))", with: "]\u{0}(\(bare))")
            source = source.replacingOccurrences(of: "(\(bare))", with: "([\(label)](\(bare)))")
            source = source.replacingOccurrences(of: "]\u{0}(\(bare))", with: "](\(bare))")
            source = source.replacingOccurrences(of: " \(bare)", with: " [\(label)](\(bare))")
            source = source.replacingOccurrences(of: "\n\(bare)", with: "\n[\(label)](\(bare))")
        }
        if let a = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return a }
        return AttributedString(text)
    }

    static func toolTitle(_ name: String) -> String {
        switch name {
        case "get_health": String(localized: "the Health Score")
        case "get_metrics": String(localized: "live metrics")
        case "list_top_processes": String(localized: "top processes")
        case "list_large_files": String(localized: "large files")
        case "inspect_path": String(localized: "a path")
        case "get_cleanup_summary": String(localized: "the cleanup plan")
        case "list_leftovers": String(localized: "leftovers")
        case "list_login_items": String(localized: "login items")
        default: name
        }
    }
}
