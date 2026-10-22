import Foundation
import HelperShared
import MaintenanceKit

/// The privileged helper's state for the UI (C22). Status is re-read when the app becomes active,
/// because the user approves the helper in System Settings.
@MainActor
@Observable
final class HelperService {
    let client = HelperClient()
    private(set) var status: HelperStatus = .notRegistered
    private(set) var lastError: String?

    init() { refresh() }

    func refresh() { if !VisualFixtures.enabled { status = client.status } }

    var isEnabled: Bool { if case .enabled = status { true } else { false } }

    func install() {
        guard !VisualFixtures.enabled else { return }
        do {
            try client.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        if case .requiresApproval = status { client.openApprovalSettings() }
    }

    func remove() async {
        guard !VisualFixtures.enabled else { return }
        do {
            try await client.unregister()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openApprovalSettings() { client.openApprovalSettings() }
}
