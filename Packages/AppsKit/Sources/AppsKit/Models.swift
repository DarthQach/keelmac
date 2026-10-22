import Foundation
import SafetyKit

/// An application bundle found in an Applications folder.
public struct InstalledApp: Sendable, Identifiable, Hashable {
    /// The bundle path.
    public let id: String
    public let name: String
    public let path: String
    public let bundleID: String?
    public let version: String?
    /// Team identifier from the code signature; nil for unsigned, ad-hoc and Apple platform apps.
    public let teamID: String?
    /// Allocated size on disk; nil until measured.
    public let bytes: Int64?
    /// Spotlight's kMDItemLastUsedDate.
    public let lastUsed: Date?
    public let isApple: Bool

    public init(name: String, path: String, bundleID: String?, version: String?, teamID: String?,
                bytes: Int64?, lastUsed: Date?, isApple: Bool) {
        self.id = path; self.name = name; self.path = path; self.bundleID = bundleID; self.version = version
        self.teamID = teamID; self.bytes = bytes; self.lastUsed = lastUsed; self.isApple = isApple
    }

    public func with(bytes: Int64?, teamID: String?, lastUsed: Date?) -> InstalledApp {
        InstalledApp(name: name, path: path, bundleID: bundleID, version: version, teamID: teamID,
                     bytes: bytes, lastUsed: lastUsed, isApple: isApple)
    }
}

/// A file or folder that belongs to an app outside its bundle.
public struct RelatedFile: Sendable, Identifiable, Hashable {
    /// The path.
    public let id: String
    public let path: String
    /// Allocated size on disk.
    public let bytes: Int64
    public let location: RelatedLocation
    /// Also used by another installed app (same vendor folder, shared team group container, a second copy
    /// of the same app). The app shows these unchecked by default.
    public let isShared: Bool
    /// Outside the user's home (/Library): only the privileged helper may remove it.
    public let needsHelper: Bool
    /// Modification date at match time, for `RemovalRequest.expectedModificationDate`.
    public let modified: Date?
    /// Why it matched.
    public let reason: MatchReason

    public init(path: String, bytes: Int64, location: RelatedLocation, isShared: Bool,
                needsHelper: Bool = false, modified: Date? = nil, reason: MatchReason = .bundleID) {
        self.id = path; self.path = path; self.bytes = bytes; self.location = location; self.isShared = isShared
        self.needsHelper = needsHelper; self.modified = modified; self.reason = reason
    }
}

public enum RelatedLocation: String, Sendable, CaseIterable {
    case applicationSupport, caches, preferences, containers, groupContainers, savedState, logs, launchAgents,
         cookies, httpStorages, webKit, other
    // Added after the contract:
    case applicationScripts, launchDaemons, privilegedHelperTools
}

/// How a related file was tied to its app. Raw values are stable.
public enum MatchReason: String, Sendable, Hashable, CaseIterable {
    /// Named after the bundle id (exactly, or `<bundleid>.…`), or a group id that contains it.
    case bundleID
    /// A folder whose name equals the app's name.
    case name
    /// A Group Container or Application Scripts entry named `<teamID>.…`.
    case teamID
    /// The vendor folder in Application Support (`Google`, `Adobe`), or a folder inside it named after the app.
    case vendorFolder
    /// A launchd plist whose program lives inside the app bundle.
    case program
    /// A Group Container listed in the app's `com.apple.security.application-groups` entitlement.
    case appGroup

    var isStrong: Bool { self == .bundleID || self == .program || self == .appGroup }
}

/// Files left behind by an app that is no longer installed.
public struct LeftoverGroup: Sendable, Identifiable {
    /// The bundle id the files are named after.
    public let id: String
    public let displayName: String
    public let files: [RelatedFile]
    public let bytes: Int64
    /// Newest modification date among the files.
    public let lastModified: Date?

    public init(id: String, displayName: String, files: [RelatedFile], lastModified: Date? = nil) {
        self.id = id; self.displayName = displayName; self.files = files
        self.bytes = files.reduce(0) { $0 + $1.bytes }; self.lastModified = lastModified
    }
}

public enum LaunchDomain: String, Sendable {
    /// ~/Library/LaunchAgents
    case userAgent
    /// /Library/LaunchAgents
    case globalAgent
    /// /Library/LaunchDaemons
    case globalDaemon
}

public struct LaunchItem: Sendable, Identifiable, Hashable {
    /// The plist path.
    public let id: String
    public let label: String
    public let plistPath: String
    /// Program, or the first of ProgramArguments.
    public let program: String?
    public let domain: LaunchDomain
    public let schedule: LaunchSchedule
    public let ownerName: String?
    /// False for orphans: the program is gone, or it points into an app (or a vendor helper folder) whose app
    /// is no longer installed.
    public let ownerInstalled: Bool
    public let isDisabled: Bool
    /// Added after the contract: the owning app's bundle id when one is installed.
    public let ownerBundleID: String?
    /// Added after the contract: whether the program exists on disk.
    public let programExists: Bool

    public init(label: String, plistPath: String, program: String?, domain: LaunchDomain, schedule: LaunchSchedule,
                ownerName: String?, ownerInstalled: Bool, isDisabled: Bool, ownerBundleID: String? = nil,
                programExists: Bool = true) {
        self.id = plistPath; self.label = label; self.plistPath = plistPath; self.program = program
        self.domain = domain; self.schedule = schedule; self.ownerName = ownerName
        self.ownerInstalled = ownerInstalled; self.isDisabled = isDisabled
        self.ownerBundleID = ownerBundleID; self.programExists = programExists
    }

    /// Only user agents can be changed without the helper.
    public var needsHelper: Bool { domain != .userAgent }

    /// False for on-demand jobs: they run only when another program asks for them, never at login.
    public var startsOnItsOwn: Bool { schedule != .onDemand }

    /// What the Health Score's startup items factor counts: enabled and starting on its own.
    public var countsTowardStartup: Bool { !isDisabled && startsOnItsOwn }
}

public enum LaunchSchedule: Sendable, Hashable {
    case atLoad, keepAlive, interval(Int), calendar, onDemand
}

/// What happened when the app asked to enable or disable a launch item.
public enum LaunchToggleOutcome: Sendable, Equatable {
    /// launchctl accepted the change; the result of the enable/disable call.
    case changed(CommandResult)
    /// launchctl refused.
    case failed(CommandResult)
    /// A /Library item: the app must send `HelperOperation.launchd(label:plistPath:action:)` to the helper.
    case needsHelper(label: String, plistPath: String)
}
