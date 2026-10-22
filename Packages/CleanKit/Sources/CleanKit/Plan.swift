import Foundation
import SafetyKit

/// How a command item measures what it frees, before (at plan time) and after it runs.
public enum CommandMeasurement: Sendable, Hashable {
    case none
    /// Allocated size of these absolute folders.
    case paths([String])
    /// Size of the folders of `xcrun simctl list devices unavailable -j`.
    case simctlUnavailableDevices(xcrun: String, devicesFolder: String)
    /// Reclaimable containers and build cache from `docker system df`.
    case dockerSystemDF(docker: String)
}

/// Exactly what a command item runs.
public struct CommandInvocation: Sendable, Hashable {
    public let executable: String
    public let arguments: [String]
    public let timeout: TimeInterval
    public let measurement: CommandMeasurement

    public init(executable: String, arguments: [String], timeout: TimeInterval, measurement: CommandMeasurement) {
        self.executable = executable; self.arguments = arguments; self.timeout = timeout; self.measurement = measurement
    }

    /// The command as a person would type it (arguments with spaces or quotes are single-quoted).
    public var commandLine: String { CommandInvocation.commandLine(executable, arguments) }

    static func commandLine(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).map { arg in
            arg.contains(where: { " '\"{}$*?\\".contains($0) }) ? "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'" : arg
        }.joined(separator: " ")
    }
}

public struct IOSBackupInfo: Sendable, Hashable {
    public let deviceName: String?
    public let productType: String?
    public let productVersion: String?
    public let lastBackupDate: Date?
    public let isEncrypted: Bool?

    public init(deviceName: String?, productType: String?, productVersion: String?, lastBackupDate: Date?, isEncrypted: Bool?) {
        self.deviceName = deviceName; self.productType = productType; self.productVersion = productVersion
        self.lastBackupDate = lastBackupDate; self.isEncrypted = isEncrypted
    }
}

public struct SimulatorDevice: Sendable, Hashable {
    public let udid: String
    public let name: String
    public let runtime: String
    public let path: String
    public let bytes: Int64
}

public struct DockerUsage: Sendable, Hashable {
    public let containersBytes: Int64
    public let buildCacheBytes: Int64
    /// Unused images. `docker system prune -f` only removes dangling ones, so this is not counted in the item size.
    public let imagesReclaimableBytes: Int64
}

/// What the preview can show about an item beyond its path and size.
public enum ItemDetail: Sendable, Hashable {
    case iosBackup(IOSBackupInfo)
    case appLanguage(appName: String, appPath: String, language: String)
    case simulators([SimulatorDevice])
    case docker(DockerUsage)
}

public struct CleanupItem: Sendable, Identifiable, Hashable {
    /// `<rule id>:<path>` for path items, `<rule id>:command` for command items.
    public let id: String
    public let ruleID: String
    /// Absolute path, or the command line for command items.
    public let path: String
    /// Allocated bytes (for commands: the measured expected saving).
    public let bytes: Int64
    /// The item's own modification date (lstat), passed to `SafeRemover` as the "changed since preview" check.
    public let modified: Date?
    public let isCommand: Bool
    /// Newest modification of the item and everything inside it (used for minimum age).
    public let newestModified: Date?
    public let isDirectory: Bool
    public let fileCount: Int
    public let detail: ItemDetail?
    /// Set for command items.
    public let command: CommandInvocation?

    public init(id: String, ruleID: String, path: String, bytes: Int64, modified: Date?, isCommand: Bool,
                newestModified: Date? = nil, isDirectory: Bool = false, fileCount: Int = 0,
                detail: ItemDetail? = nil, command: CommandInvocation? = nil) {
        self.id = id; self.ruleID = ruleID; self.path = path; self.bytes = bytes; self.modified = modified
        self.isCommand = isCommand; self.newestModified = newestModified; self.isDirectory = isDirectory
        self.fileCount = fileCount; self.detail = detail; self.command = command
    }

    static func pathID(rule: String, path: String) -> String { "\(rule):\(path)" }
    static func commandID(rule: String) -> String { "\(rule):command" }
}

public enum SkipReason: Sendable, Hashable {
    /// The app with this bundle id is running.
    case appRunning(String)
}

/// Something the rule found but doesn't offer, with the reason the preview shows.
public struct SkippedItem: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let bytes: Int64
    public let reason: SkipReason
}

public enum GroupStatus: Sendable, Equatable {
    case ready
    case needsFullDiskAccess
    /// The rule's tool (`requiresTool`) isn't installed.
    case toolMissing
    /// An app in `skipIfRunning` is running (its bundle id).
    case appRunning(String)
    case failed(String)
    /// The tool is installed but doesn't respond (`toolCheck` failed), e.g. the Docker daemon isn't running.
    case toolNotResponding(String)
    /// The rule needs administrator rights; CleanKit never runs these itself.
    case needsHelper
}

public struct CleanupGroup: Sendable, Identifiable {
    /// The rule id.
    public let id: String
    public let rule: CleanupRule
    public let items: [CleanupItem]
    public let bytes: Int64
    public let status: GroupStatus
    public let selectedByDefault: Bool
    /// Found but not offered (e.g. a running app's cache folder).
    public let skipped: [SkippedItem]
    /// Folders that couldn't be read (permissions), so sizes may be low.
    public let unreadableCount: Int
    /// Matches `PathGuard` refused (protected, whitelisted, containers). They are never offered.
    public let refusedCount: Int
    /// The resolved tool for command rules.
    public let toolPath: String?

    public init(id: String, rule: CleanupRule, items: [CleanupItem], bytes: Int64, status: GroupStatus, selectedByDefault: Bool,
                skipped: [SkippedItem] = [], unreadableCount: Int = 0, refusedCount: Int = 0, toolPath: String? = nil) {
        self.id = id; self.rule = rule; self.items = items; self.bytes = bytes; self.status = status
        self.selectedByDefault = selectedByDefault; self.skipped = skipped; self.unreadableCount = unreadableCount
        self.refusedCount = refusedCount; self.toolPath = toolPath
    }

    public var category: CleanupCategory { rule.category }
    /// True for the Trash: these items are deleted permanently, so the UI must say so.
    public var deletesPermanently: Bool { rule.deletesPermanently }
    public var isCommand: Bool { rule.kind == .command }
}

public struct CleanupPlan: Sendable {
    public let createdAt: Date
    public let groups: [CleanupGroup]

    public init(createdAt: Date, groups: [CleanupGroup]) { self.createdAt = createdAt; self.groups = groups }

    public var allItems: [CleanupItem] { groups.flatMap(\.items) }

    public func item(id: String) -> CleanupItem? {
        for g in groups { if let i = g.items.first(where: { $0.id == id }) { return i } }
        return nil
    }

    public func group(id: String) -> CleanupGroup? { groups.first { $0.id == id } }

    public func groups(in category: CleanupCategory) -> [CleanupGroup] { groups.filter { $0.category == category } }

    /// Total bytes of the selected items that exist in this plan.
    public func bytes(selected: Set<String>) -> Int64 {
        allItems.reduce(0) { selected.contains($1.id) ? $0 + $1.bytes : $0 }
    }

    /// Bytes per category for the given selection.
    public func bytes(selected: Set<String>, in category: CleanupCategory) -> Int64 {
        groups(in: category).flatMap(\.items).reduce(0) { selected.contains($1.id) ? $0 + $1.bytes : $0 }
    }

    /// Every item of every group that is selected by default (ready and not opt-in).
    public func defaultSelection() -> Set<String> {
        Set(groups.filter(\.selectedByDefault).flatMap { $0.items.map(\.id) })
    }
}

/// Facts about the Mac the planner needs. The app fills it; tests point it at a fixture home.
public struct CleanupEnvironment: Sendable {
    public var home: String
    public var hasFullDiskAccess: Bool
    public var runningBundleIDs: Set<String>
    public var now: Date
    public var uid: UInt32
    /// Where volumes are mounted. `/Volumes` in the app; a fixture folder in tests.
    public var volumesRoot: String
    /// The user's preferred languages (`Locale.preferredLanguages`), kept by the language-files rule.
    public var preferredLanguages: [String]
    /// Whether a tool exists. Injected in tests so they never depend on what's installed.
    public var isExecutable: @Sendable (String) -> Bool

    public init(
        home: String = NSHomeDirectory(),
        hasFullDiskAccess: Bool,
        runningBundleIDs: Set<String> = [],
        now: Date = Date(),
        uid: UInt32 = getuid(),
        volumesRoot: String = "/Volumes",
        preferredLanguages: [String] = Locale.preferredLanguages,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.home = home; self.hasFullDiskAccess = hasFullDiskAccess; self.runningBundleIDs = runningBundleIDs
        self.now = now; self.uid = uid; self.volumesRoot = volumesRoot; self.preferredLanguages = preferredLanguages
        self.isExecutable = isExecutable
    }
}
