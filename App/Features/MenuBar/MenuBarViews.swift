import SwiftUI

/// The text in the menu bar. Filled with live readouts in M1.
struct MenuBarLabel: View {
    var body: some View {
        Image(systemName: "gauge.with.dots.needle.33percent")
            .accessibilityLabel("KeelMac")
    }
}

/// S4: menu bar popover.
struct MenuBarPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measuring…").foregroundStyle(.kmFgMuted)
            Divider()
            HStack {
                Button("Open KeelMac") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
                Spacer()
                SettingsLink { Text("Settings…") }.buttonStyle(.borderless)
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
