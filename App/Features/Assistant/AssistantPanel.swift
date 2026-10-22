import AppKit
import AssistantKit
import SwiftUI

// MARK: - Layout

/// Puts the Assistant beside the current screen, below the window toolbar, behind a draggable divider.
/// Not `.inspector`: an inspector column runs up into the toolbar, so each screen's own toolbar controls
/// sat above the Assistant and read as its controls.
struct AssistantSplit<Content: View>: View {
    @Environment(AppModel.self) private var model
    @AppStorage("assistantPanelWidth") private var storedWidth = 360.0
    @ViewBuilder let content: Content

    static var minWidth: Double { 300 }

    var body: some View {
        GeometryReader { geometry in
            let maxWidth = max(Self.minWidth, min(480, geometry.size.width * 0.5))
            let width = min(max(storedWidth, Self.minWidth), maxWidth)
            HStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.assistant.isPresented {
                    PanelDivider(width: $storedWidth, range: Self.minWidth...maxWidth)
                    AssistantPanel()
                        .frame(width: width)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }
}

/// The toolbar button that shows and hides the panel.
struct AssistantToggle: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { model.assistant.togglePanel() }
        } label: {
            Label("Assistant", systemImage: "sparkles")
        }
        .help("Show or hide the Assistant (⌘⇧A)")
        .accessibilityIdentifier("assistant.toggle")
    }
}

/// A 1 pt rule with a wider invisible grip; dragging it resizes the panel.
private struct PanelDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering || startWidth != nil ? Color.kmBorderStrong : Color.kmBorder)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? min(max(width, range.lowerBound), range.upperBound)
                                startWidth = start
                                width = min(max(start - value.translation.width, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Panel

/// S21: the Assistant, available on every route.
struct AssistantPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let a = model.assistant
        VStack(spacing: 0) {
            PanelHeader(assistant: a, openSettings: { openSettings() }, close: close)
            Rectangle().fill(Color.kmBorder).frame(height: 1)
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
                    HStack(spacing: 10) {
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
                if a.turns.isEmpty { welcome(a) } else { transcript(a) }
                footer(a)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.kmSurfaceMuted)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "keelmac" else { return .systemAction }
            model.open(url)
            return .handled
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.panel")
    }

    private func close() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { model.assistant.isPresented = false }
    }

    // MARK: Conversation

    private func welcome(_ a: AssistantModel) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 16)
            AssistantMark(size: 44)
            VStack(spacing: 6) {
                Text("Ask about what you see.").font(.title3.weight(.semibold))
                Text("Answers come from Ollama on this Mac. KeelMac shares the names, sizes and dates of what is on screen, never file contents.")
                    .font(.callout).foregroundStyle(.kmFgMuted).multilineTextAlignment(.center)
            }
            if a.canSend {
                VStack(spacing: 8) {
                    ForEach(a.suggestions, id: \.self) { s in PromptCard(text: s) { a.send(s) } }
                }
                .padding(.top, 4)
                .accessibilityIdentifier("assistant.suggestions")
            }
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transcript(_ a: AssistantModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
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
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .accessibilityIdentifier("assistant.transcript")
    }

    private func footer(_ a: AssistantModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .error(let message) = a.status {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(verbatim: message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.callout)
                    .foregroundStyle(.kmDanger)
                    Button("Try again") { a.retryLast() }.controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.kmSurface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.kmDanger.opacity(0.35)))
                .accessibilityIdentifier("assistant.error")
            }
            if !a.turns.isEmpty, a.canSend, !a.suggestions.isEmpty {
                WrappingRow(spacing: 6) {
                    ForEach(a.suggestions, id: \.self) { s in SuggestionChip(text: s) { a.send(s) } }
                }
                .accessibilityIdentifier("assistant.suggestions")
            }
            composer(a)
            ContextPill(context: a.effectiveContext)
        }
        .padding(12)
        .overlay(alignment: .top) {
            if !a.turns.isEmpty { Rectangle().fill(Color.kmBorder).frame(height: 1) }
        }
    }

    private func composer(_ a: AssistantModel) -> some View {
        let busy = a.status == .streaming || a.status == .loadingModel
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this screen…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.vertical, 5)
                .focused($focused)
                .onSubmit { submit(a) }
                .accessibilityIdentifier("assistant.input")
            if busy {
                RoundIconButton(symbol: "stop.fill", label: "Stop", filled: false) { a.stop() }
                    .accessibilityIdentifier("assistant.stop")
            } else {
                RoundIconButton(symbol: "arrow.up", label: "Send", filled: true) { submit(a) }
                    .disabled(empty || !a.canSend)
                    .accessibilityIdentifier("assistant.send")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color.kmSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? Color.kmAccent : Color.kmBorder, lineWidth: focused ? 1.5 : 1)
        )
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

// MARK: - Header

private struct PanelHeader: View {
    let assistant: AssistantModel
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AssistantMark(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Assistant").font(.headline).accessibilityIdentifier("assistant.title")
                StatusLine(status: assistant.status, model: assistant.modelName)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                HeaderButton(symbol: "square.and.pencil", label: "New conversation") { assistant.clear() }
                    .disabled(assistant.turns.isEmpty)
                HeaderButton(symbol: "gearshape", label: "Assistant Settings…", action: openSettings)
                HeaderButton(symbol: "xmark", label: "Close", action: close)
                    .accessibilityIdentifier("assistant.close")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// The Assistant's mark: sparkles on a soft accent tile.
private struct AssistantMark: View {
    var size: CGFloat

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.kmAccent)
            .frame(width: size, height: size)
            .background(Color.kmAccentSoft, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Color.kmAccent.opacity(0.25)))
            .accessibilityHidden(true)
    }
}

/// A dot and one line: where answers come from, or why they can't.
private struct StatusLine: View {
    let status: AssistantModel.Status
    let model: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(verbatim: text).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.kmFgMuted)
    }

    private var text: String {
        switch status {
        case .disabled: String(localized: "Off")
        case .checking: String(localized: "Checking Ollama…")
        case .unreachable: String(localized: "Ollama isn’t running")
        case .noModel: String(localized: "No models in Ollama")
        case .loadingModel: String(localized: "Loading \(model)…")
        case .streaming: String(localized: "Answering…")
        case .idle, .error: model.isEmpty ? String(localized: "On this Mac") : String(localized: "On this Mac · \(model)")
        }
    }

    private var color: Color {
        switch status {
        case .idle, .loadingModel, .streaming: .kmSuccess
        case .unreachable, .noModel, .error: .kmWarning
        case .disabled, .checking: .kmFgMuted
        }
    }
}

private struct HeaderButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(hovering && isEnabled ? Color.kmBorder : Color.clear, in: RoundedRectangle(cornerRadius: Metrics.radiusControl))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Color.kmFgMuted : Color.kmFgMuted.opacity(0.4))
        .onHover { hovering = $0 }
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Pieces

/// One empty, blocked or error state in the panel's column.
private struct PanelState<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 16)
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.kmFgMuted)
                .frame(width: 48, height: 48)
                .background(Color.kmSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.kmBorder))
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text(message).font(.callout).foregroundStyle(.kmFgMuted).multilineTextAlignment(.center)
            }
            VStack(spacing: 10) { actions }.padding(.top, 2)
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A suggested question on the empty conversation, full width.
private struct PromptCard: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(verbatim: text).font(.callout).foregroundStyle(.kmFg).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.kmFgMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.kmSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hovering ? Color.kmAccent.opacity(0.6) : Color.kmBorder))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A follow-up suggestion above the composer; wraps instead of scrolling off the edge.
private struct SuggestionChip: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: text)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.kmFg)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.kmSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(hovering ? Color.kmAccent.opacity(0.6) : Color.kmBorder))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RoundIconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let filled: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(filled && isEnabled ? Color.kmOnAccent : Color.kmFgMuted)
                .frame(width: 26, height: 26)
                .background(filled && isEnabled ? Color.kmAccent : Color.kmBorder, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}

/// What the Assistant will see with the next question; opens the exact text it gets.
private struct ContextPill: View {
    let context: ScreenContext
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label {
                Text(verbatim: summary).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: "eye")
            }
            .font(.caption)
            .foregroundStyle(.kmFgMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("What the Assistant can see")
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("What the Assistant can see").font(.headline)
                ScrollView {
                    Text(verbatim: context.rendered())
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                Text("Names, sizes and dates only. Never file contents.").font(.caption).foregroundStyle(.kmFgMuted)
            }
            .padding(14)
            .frame(width: 340)
        }
        .accessibilityIdentifier("assistant.context")
    }

    private var summary: String {
        context.hasUserSelection
            ? String(localized: "Looking at \(context.route.name) and your selection")
            : String(localized: "Looking at \(context.route.name)")
    }
}

/// Three dots that breathe while an answer is on its way; still under Reduce Motion.
private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .frame(width: 6, height: 6)
                        .opacity(reduceMotion ? 0.6 : 0.3 + 0.7 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
        }
        .foregroundStyle(.kmFgMuted)
        .accessibilityLabel("Answering…")
    }
}

// MARK: - Transcript rows

private struct TurnView: View {
    let turn: AssistantModel.Turn
    let status: AssistantModel.Status

    var body: some View {
        switch turn.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 48)
                Text(verbatim: text)
                    .foregroundStyle(.kmOnAccent)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.kmAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityIdentifier("assistant.turn.user")
        case .assistant(let text):
            VStack(alignment: .leading, spacing: 8) {
                if text.isEmpty {
                    HStack(spacing: 10) {
                        TypingDots()
                        if status == .loadingModel {
                            Text("Loading the model… the first answer takes a few seconds.")
                                .font(.callout).foregroundStyle(.kmFgMuted)
                        }
                    }
                } else {
                    Text(AssistantMarkdown.attributed(text))
                        .foregroundStyle(.kmFg)
                        .tint(Color.kmAccentText)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if turn.isStreaming { TypingDots() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("assistant.turn.assistant")
        case .tool(let name, let output, let isError):
            ToolRow(name: name, output: output, isError: isError)
        }
    }
}

/// A lookup the model made: a quiet capsule that opens to show exactly what came back.
private struct ToolRow: View {
    let name: String
    let output: String
    let isError: Bool
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard !output.isEmpty else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if output.isEmpty {
                        ProgressView().controlSize(.mini)
                        Text("Looking up \(AssistantMarkdown.toolTitle(name))…")
                    } else {
                        Image(systemName: isError ? "exclamationmark.triangle" : "magnifyingglass").accessibilityHidden(true)
                        Text("Looked up \(AssistantMarkdown.toolTitle(name))")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .font(.caption)
                .foregroundStyle(isError ? Color.kmWarningInk : Color.kmFgMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.kmSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.kmBorder))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            if expanded {
                ScrollView {
                    Text(verbatim: output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .background(Color.kmSurface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.kmBorder))
            }
        }
        .accessibilityIdentifier("assistant.turn.tool")
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
