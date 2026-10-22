import SwiftUI

/// Empty state: a small symbol, one sentence of what will appear, and the action that creates it.
struct EmptyStateView: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.kmFgMuted)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.kmWarningInk)
                .accessibilityHidden(true)
            (Text(title).fontWeight(.semibold) + Text(verbatim: " ") + Text(message).foregroundStyle(.kmWarningInk))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, action: action)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 10)
        .background(.kmWarningSoft)
        .overlay(alignment: .bottom) { Divider() }
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
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.kmFgMuted)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}

/// The page content area: sailcloth background, readable max width.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.kmBg)
    }
}
