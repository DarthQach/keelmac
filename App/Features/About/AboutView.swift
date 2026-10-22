import SwiftUI

struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About KeelMac") { openWindow(id: "about") }
    }
}

/// S19: version, support, links and credits (C28, C29, C31).
struct AboutView: View {
    @Environment(AppModel.self) private var model

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            Text("KeelMac").font(.largeTitle.weight(.semibold))
            Text("Version \(version)").foregroundStyle(.kmFgMuted).tabular()
            Text("Free and open source under the GPL-3.0 licence. No account, no telemetry.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            Button("Buy me a coffee") { NSWorkspace.shared.open(SupportLinks.coffee) }
                .fontWeight(.semibold)
                .padding(.top, 4)
            HStack(spacing: 16) {
                Link("Release notes", destination: SupportLinks.releaseNotes)
                Link("GitHub", destination: SupportLinks.repository)
                Link("Report an issue", destination: SupportLinks.issues)
            }
            .foregroundStyle(.kmAccentText)
            Button("Check for Updates…") { model.updater.checkForUpdates() }
                .buttonStyle(.link)
                .foregroundStyle(.kmAccentText)
                .disabled(!model.updater.canCheck)
            Text("Metric collection approaches studied from Stats (MIT). Cleanup coverage informed by Mole (GPL-3.0). Updates by Sparkle.")
                .font(.caption)
                .foregroundStyle(.kmFgMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .padding(32)
        .frame(width: 420)
        .background(.kmBg)
        .foregroundStyle(.kmFg)
    }
}
