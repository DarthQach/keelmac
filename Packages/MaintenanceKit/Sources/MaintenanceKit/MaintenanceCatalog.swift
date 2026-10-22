import Foundation
import HelperShared

public enum MaintenanceTaskID: String, Sendable, CaseIterable, Codable {
    case flushDNS, rebuildLaunchServices, rebuildSpotlight, verifyStartupDisk, clearFontCaches, thinLocalSnapshots, runPeriodic
}

/// Why a task can't run on this Mac. The app localizes it.
public enum MaintenanceUnavailableReason: Sendable, Equatable, Hashable {
    /// The executable isn't on this macOS (for example `/usr/sbin/periodic`, removed in macOS 27).
    case toolMissing(String)
}

public enum MaintenanceAvailability: Sendable, Equatable {
    case available
    case unavailable(MaintenanceUnavailableReason)
}

/// One row of the Maintenance screen. Titles and descriptions are localized by the app from `id`.
public struct MaintenanceTask: Sendable, Identifiable {
    public let id: MaintenanceTaskID
    /// Exactly what runs, shown in the UI: `CommandLineFormatter.join(invocations)`.
    public let commandLine: String
    public let needsAdmin: Bool
    /// Commands run as the user (empty for admin tasks).
    public let userInvocations: [(String, [String])]
    /// The helper operation (nil for user tasks).
    public let helperOperation: HelperOperation?
    /// How long a user task may run before it is stopped.
    public let timeout: TimeInterval

    init(id: MaintenanceTaskID, userInvocations: [(String, [String])], timeout: TimeInterval) {
        self.id = id
        self.needsAdmin = false
        self.userInvocations = userInvocations
        self.helperOperation = nil
        self.timeout = timeout
        self.commandLine = CommandLineFormatter.join(userInvocations.map { (executable: $0.0, arguments: $0.1) })
    }

    init(id: MaintenanceTaskID, helperOperation: HelperOperation) {
        self.id = id
        self.needsAdmin = true
        self.userInvocations = []
        self.helperOperation = helperOperation
        self.timeout = helperOperation.timeout
        self.commandLine = CommandLineFormatter.join(HelperCommandMap.invocations(for: helperOperation))
    }

    /// The commands this task runs, wherever they run.
    public var invocations: [(executable: String, arguments: [String])] {
        if let helperOperation { return HelperCommandMap.invocations(for: helperOperation) }
        return userInvocations.map { (executable: $0.0, arguments: $0.1) }
    }

    /// Every executable must exist for the task to be offered.
    public func availability(executableExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> MaintenanceAvailability {
        for inv in invocations where !executableExists(inv.executable) {
            return .unavailable(.toolMissing(inv.executable))
        }
        return .available
    }

    public var isAvailable: Bool { availability() == .available }

    public var unavailableReason: MaintenanceUnavailableReason? {
        if case .unavailable(let reason) = availability() { return reason }
        return nil
    }
}

public enum MaintenanceCatalog {
    /// LaunchServices' registration tool on macOS 14–27.
    public static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    public static let diskutil = "/usr/sbin/diskutil"
    public static let atsutil = "/usr/bin/atsutil"

    /// 20 GB: what "Thin local snapshots" asks Time Machine to reclaim at urgency 4 (the highest).
    public static let defaultThinBytes: Int64 = 20_000_000_000

    /// The seven tasks, in `MaintenanceTaskID.allCases` order.
    public static let all: [MaintenanceTask] = [
        MaintenanceTask(id: .flushDNS, helperOperation: .flushDNS),
        // `-kill` and `-domain` are gone from lsregister (macOS 14+); `-gc` drops stale records and
        // `-f -all local,system,user` re-registers every app in those domains even if unchanged.
        MaintenanceTask(id: .rebuildLaunchServices,
                        userInvocations: [(lsregister, ["-gc", "-f", "-all", "local,system,user"])], timeout: 900),
        MaintenanceTask(id: .rebuildSpotlight, helperOperation: .rebuildSpotlight),
        MaintenanceTask(id: .verifyStartupDisk, userInvocations: [(diskutil, ["verifyVolume", "/"])], timeout: 3600),
        MaintenanceTask(id: .clearFontCaches, userInvocations: [(atsutil, ["databases", "-removeUser"])], timeout: 120),
        MaintenanceTask(id: .thinLocalSnapshots, helperOperation: .thinLocalSnapshots(bytes: defaultThinBytes)),
        // /usr/sbin/periodic no longer ships in macOS 27; the task reports `.toolMissing` there.
        MaintenanceTask(id: .runPeriodic, helperOperation: .runPeriodic),
    ]

    public static func task(_ id: MaintenanceTaskID) -> MaintenanceTask {
        all.first { $0.id == id }!
    }

    /// "Thin local snapshots" with a different amount.
    public static func thinLocalSnapshots(bytes: Int64) -> MaintenanceTask {
        MaintenanceTask(id: .thinLocalSnapshots, helperOperation: .thinLocalSnapshots(bytes: bytes))
    }
}
