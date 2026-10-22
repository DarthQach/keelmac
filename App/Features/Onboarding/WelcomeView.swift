import SwiftUI

/// S1: first launch and Full Disk Access guidance. Polls the permission while open.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LoadLineMark()
                .frame(width: 56, height: 30)
                .accessibilityHidden(true)
            Text("Welcome to KeelMac")
                .font(.title2.weight(.semibold))
            Text("KeelMac needs Full Disk Access to see caches, logs and other folders macOS protects. It never reads file contents, except to compare files when you look for duplicates.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click **Open Privacy & Security**.")
                Text("2. Turn on **KeelMac** under Full Disk Access. If it isn’t listed, click the plus button and choose KeelMac in Applications.")
                Text("3. Come back here. KeelMac notices the change on its own.")
            }
            .fixedSize(horizontal: false, vertical: true)

            if model.hasFullDiskAccess {
                StatusBadge(text: "Full Disk Access is on.", tone: .success)
            } else {
                Label("Full Disk Access is off. Checking again every few seconds.", systemImage: "info.circle")
                    .foregroundStyle(.kmFgMuted)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.kmSurfaceMuted, in: RoundedRectangle(cornerRadius: 8))
            }
            Text("You can skip this. KeelMac still works, and lists every folder it couldn’t read.")
                .font(.callout)
                .foregroundStyle(.kmFgMuted)

            HStack {
                Spacer()
                if model.hasFullDiskAccess {
                    Button("Go to dashboard") { finish() }
                        .buttonStyle(.kmPrimary)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue without access") { finish() }
                    Button("Open Privacy & Security") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.kmPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(32)
        .frame(width: 560)
        .task {
            while !Task.isCancelled && !model.hasFullDiskAccess {
                try? await Task.sleep(for: .seconds(2))
                model.refreshFullDiskAccess()
            }
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Preferences.Key.welcomeShown)
        dismiss()
    }
}

/// The Plimsoll mark: a ring crossed by a line. KeelMac's brand mark.
struct LoadLineMark: View {
    var color: Color = .kmHullInk
    var lineWidth: CGFloat = 2.5

    var body: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) * 0.4
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color), lineWidth: lineWidth)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: c.y))
            line.addLine(to: CGPoint(x: size.width, y: c.y))
            context.stroke(line, with: .color(color), lineWidth: lineWidth)
        }
    }
}
