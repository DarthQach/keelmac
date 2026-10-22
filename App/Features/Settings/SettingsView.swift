import SwiftUI

/// S18: Settings window. Each tab applies changes immediately.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettings()
                .tabItem { Label("Menu bar", systemImage: "menubar.rectangle") }
            AlertSettings()
                .tabItem { Label("Alerts", systemImage: "bell") }
            CleanupSettings()
                .tabItem { Label("Cleanup and safety", systemImage: "checkmark.shield") }
            HelperSettings()
                .tabItem { Label("Helper", systemImage: "lock.rotation") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 600)
    }
}

struct GeneralSettings: View {
    var body: some View { Form { Text("General") }.formStyle(.grouped) }
}

struct MenuBarSettings: View {
    var body: some View { Form { Text("Menu bar") }.formStyle(.grouped) }
}

struct AlertSettings: View {
    var body: some View { Form { Text("Alerts") }.formStyle(.grouped) }
}

struct CleanupSettings: View {
    var body: some View { Form { Text("Cleanup and safety") }.formStyle(.grouped) }
}

struct HelperSettings: View {
    var body: some View { Form { Text("Helper") }.formStyle(.grouped) }
}

struct UpdateSettings: View {
    var body: some View { Form { Text("Updates") }.formStyle(.grouped) }
}
