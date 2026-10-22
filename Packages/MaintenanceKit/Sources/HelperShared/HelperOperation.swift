import Foundation
import SafetyKit

/// What the launchd operation does to a system launch item.
public enum LaunchdAction: String, Codable, Sendable, CaseIterable {
    /// `launchctl enable`, then `bootstrap` (best effort: it fails harmlessly when the job is already loaded).
    case enable
    /// `launchctl disable`, then `bootout` (best effort: it fails harmlessly when the job isn't running).
    case disable
    /// `launchctl bootout` (best effort), then the plist moves to the user's Trash.
    case remove
}

/// Every privileged thing the helper can do. Nothing else crosses the XPC boundary:
/// no executable paths, no argument strings, no shell.
public enum HelperOperation: Codable, Sendable, Equatable, Hashable {
    case flushDNS
    case rebuildSpotlight
    case runPeriodic
    case thinLocalSnapshots(bytes: Int64)
    /// Moves items in system folders (validated with `PathGuard` context `.helper`) to the requesting user's Trash.
    case removeSystemItems(paths: [String])
    /// Enables, disables or removes a launch item in `/Library/LaunchDaemons` or `/Library/LaunchAgents`.
    case launchd(label: String, plistPath: String, action: LaunchdAction)
    /// `sfltool dumpbtm`: the Background Task Management database (Login Items › Allow in the Background).
    /// On macOS 27 the user can run it too (see `BackgroundItemsDump.userInvocation`); older systems need root.
    case dumpBackgroundItems

    /// How long the helper lets the operation's commands run before it stops them.
    public var timeout: TimeInterval {
        switch self {
        case .flushDNS: 30
        case .rebuildSpotlight: 120
        case .runPeriodic: 3600
        case .thinLocalSnapshots: 900
        case .removeSystemItems: 600
        case .launchd: 60
        case .dumpBackgroundItems: 60
        }
    }
}

/// The JSON the app sends in `KeelMacHelperProtocol.perform(_:reply:)`.
public struct HelperRequest: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let operation: HelperOperation

    public init(operation: HelperOperation, protocolVersion: Int = helperProtocolVersion) {
        self.protocolVersion = protocolVersion
        self.operation = operation
    }
}

/// Why the helper refused a request before running anything. Raw values are stable (logged).
public enum HelperRejection: String, Codable, Sendable, Equatable, CaseIterable {
    case badRequest
    case unsupportedVersion
    case invalidLabel
    case appleLabel
    case plistOutsideLaunchFolders
    case plistLabelMismatch
    case invalidPath
    case noPaths
    case tooManyPaths
    case invalidByteCount

    /// English text for the operation log; the app localizes from the raw value.
    public var englishDescription: String {
        switch self {
        case .badRequest: "The request could not be read"
        case .unsupportedVersion: "The app and the helper are different versions"
        case .invalidLabel: "Not a valid launchd label"
        case .appleLabel: "macOS's own launch items are never changed"
        case .plistOutsideLaunchFolders: "The plist is not in /Library/LaunchAgents or /Library/LaunchDaemons"
        case .plistLabelMismatch: "The plist does not belong to that label"
        case .invalidPath: "Not a clean absolute path"
        case .noPaths: "No items to remove"
        case .tooManyPaths: "Too many items in one request"
        case .invalidByteCount: "Not a valid amount of space"
        }
    }
}

/// What happened to one item of `removeSystemItems` (or the plist of `launchd(…, .remove)`).
public struct HelperItemOutcome: Codable, Sendable, Equatable {
    public let path: String
    public let bytes: Int64
    public let result: OperationResult
    public let reason: String?
    public let refusal: RefusalReason?

    public init(path: String, bytes: Int64, result: OperationResult, reason: String?, refusal: RefusalReason?) {
        self.path = path; self.bytes = bytes; self.result = result; self.reason = reason; self.refusal = refusal
    }

    public init(_ outcome: RemovalOutcome) {
        self.init(path: outcome.path, bytes: outcome.bytes, result: outcome.result, reason: outcome.reason, refusal: outcome.refusal)
    }
}

/// The JSON the helper replies with.
public struct HelperResponse: Codable, Sendable, Equatable {
    /// 0 on success; the failing command's exit code; 1 when an item could not be removed; 64 when rejected.
    public let exitCode: Int32
    /// Combined stdout and stderr of the commands that ran, in order.
    public let output: String
    public let outcomes: [HelperItemOutcome]
    /// Set when the helper refused the request without running anything.
    public let rejection: HelperRejection?
    public let timedOut: Bool

    public init(exitCode: Int32, output: String, outcomes: [HelperItemOutcome] = [], rejection: HelperRejection? = nil, timedOut: Bool = false) {
        self.exitCode = exitCode; self.output = output; self.outcomes = outcomes; self.rejection = rejection; self.timedOut = timedOut
    }

    /// Exit code used for refused requests (`EX_USAGE`).
    public static let rejectedExitCode: Int32 = 64

    public static func rejected(_ rejection: HelperRejection) -> HelperResponse {
        HelperResponse(exitCode: rejectedExitCode, output: "", rejection: rejection)
    }

    public var succeeded: Bool { exitCode == 0 && rejection == nil && !timedOut }
}

/// JSON coding used on both sides of the XPC connection.
public enum HelperCoding {
    /// Requests and responses larger than this are refused (a dump of background items is ~100 KB).
    public static let maxMessageBytes = 4 * 1024 * 1024

    public static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        guard data.count <= maxMessageBytes else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
