import Foundation
import HelperShared
import SafetyKit

/// Reads the Background Task Management database as the user (`sfltool dumpbtm`, allowed for normal users on
/// macOS 27). When it fails (older macOS needs root), the app can ask the helper for
/// `HelperOperation.dumpBackgroundItems` and parse `response.output` with `BackgroundItemsDump.parse`.
public enum BackgroundItemsReader {
    public static func read(runner: any CommandRunning) async -> [BackgroundItemRecord]? {
        let inv = BackgroundItemsDump.userInvocation
        let result = await runner.run(inv.executable, inv.arguments, timeout: 60)
        guard result.succeeded else { return nil }
        return BackgroundItemsDump.parse(result.stdout)
    }

    public static func read(helper: any HelperPerforming) async throws -> [BackgroundItemRecord] {
        let response = try await helper.perform(.dumpBackgroundItems)
        return BackgroundItemsDump.parse(response.output)
    }
}
