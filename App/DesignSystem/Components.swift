import SwiftUI

/// Empty state: a small symbol, one sentence of what will appear, and the action that creates it.
struct EmptyStateView: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.largeTitle.weight(.light))
                .padding(20)
                .background(.kmSurfaceMuted, in: RoundedRectangle(cornerRadius: Metrics.radius))
                .foregroundStyle(.kmFgMuted)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .foregroundStyle(.kmFgMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.kmPrimary)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// A calm in-place banner for missing permissions (Full Disk Access, helper).
struct PermissionBanner: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.kmWarningInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold)
                Text(message).foregroundStyle(.kmWarningInk).fixedSize(horizontal: false, vertical: true)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, action: action)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 12)
        .background(.kmWarningSoft, in: RoundedRectangle(cornerRadius: Metrics.radius))
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.bottom, 12)
    }
}

/// Status: symbol + word + colour, never colour alone.
struct StatusBadge: View {
    enum Tone { case success, warning, danger, neutral }
    let text: LocalizedStringKey
    let tone: Tone

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.kmSurfaceMuted, in: Capsule())
    }

    private var symbol: String {
        switch tone {
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .danger: "xmark.octagon"
        case .neutral: "info.circle"
        }
    }

    private var color: Color {
        switch tone {
        case .success: .kmSuccess
        case .warning: .kmWarning
        case .danger: .kmDanger
        case .neutral: .kmFgMuted
        }
    }
}

/// A command or path in monospace with a Copy button (maintenance tasks, operation log).
struct CommandLabel: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
            }
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.kmAccentText)
        }
        .padding(.vertical, 6)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .background(.kmSurfaceMuted, in: RoundedRectangle(cornerRadius: Metrics.radiusControl))
    }
}

/// A path shown in monospace, truncated in the middle.
struct PathText: View {
    let path: String
    var body: some View {
        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.kmFgMuted)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}

/// The page content area: token background (near-white light, charcoal dark).
/// Lists and tables inside drop the system grey so the page colour shows through.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .background(.kmBg)
            .foregroundStyle(.kmFg)
            .environment(\.defaultMinListRowHeight, Metrics.rowHeight)
    }
}

/// A 1px vertical rule for rows of stats (Divider is horizontal inside grids).
struct VRule: View {
    var body: some View {
        Rectangle().fill(.kmBorder).frame(width: 1).frame(maxHeight: .infinity)
    }
}

/// Reports whether the hosting window is actually visible on screen (not just created).
/// Used to run expensive sampling only while someone can see the result.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let v = VisibilityView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: VisibilityView, context: Context) { nsView.onChange = onChange }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            guard let window else { report(false); return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(window.occlusionState.contains(.visible)) }
            }
            report(window.occlusionState.contains(.visible))
        }

        private func report(_ visible: Bool) {
            guard visible != last else { return }
            last = visible
            onChange?(visible)
        }

        // The observer is removed in viewDidMoveToWindow when the view leaves its window.
    }
}

extension View {
    /// Asks the metrics monitor for processes and temperature only while this view's window is visible.
    func detailedMetrics(_ metrics: MetricsMonitor) -> some View {
        background(WindowVisibilityReader { visible in
            if visible { metrics.beginDetailed() } else { metrics.endDetailed() }
        })
    }
}
