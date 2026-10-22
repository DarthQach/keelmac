import SwiftUI
import SafetyKit

/// Root state shared by the main window, Settings and the menu bar.
@MainActor
@Observable
final class AppModel {
    var route: Route = .dashboard
    var hasFullDiskAccess: Bool = FullDiskAccess.isGranted()
    var showWelcome: Bool = false

    /// True when the app runs under UI tests with fixture data and an in-memory store.
    let isUITesting = CommandLine.arguments.contains("-uitest")

    init() {
        let defaults = UserDefaults.standard
        if !isUITesting && !defaults.bool(forKey: Preferences.Key.welcomeShown) && !hasFullDiskAccess {
            showWelcome = true
        }
    }

    func refreshFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted()
    }

    func open(_ url: URL) {
        if let route = Route(url: url) { self.route = route }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }
}
