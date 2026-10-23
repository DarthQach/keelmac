import Sparkle
import SwiftUI

/// Sparkle 2 updates (C29). The appcast is the only network request KeelMac makes on its own; the opt-in Assistant talks to the user's local Ollama or LM Studio.
@MainActor
@Observable
final class Updater {
    private let controller: SPUStandardUpdaterController
    private(set) var canCheck = false
    private var observation: NSKeyValueObservation?

    init(start: Bool) {
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
        // Sparkle changes canCheckForUpdates on the main thread.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
