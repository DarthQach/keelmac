import Foundation

public enum DeleteMode: String, Sendable, Codable, CaseIterable {
    case trash, permanent
}

/// One item the user approved in a preview.
public struct RemovalRequest: Sendable, Equatable {
    public let path: String
    public let bytes: Int64
    /// Modification date seen in the preview. If the item changed after it, the removal is skipped.
    public let expectedModificationDate: Date?

    public init(path: String, bytes: Int64, expectedModificationDate: Date? = nil) {
        self.path = path; self.bytes = bytes; self.expectedModificationDate = expectedModificationDate
    }
}

public struct RemovalOutcome: Sendable, Equatable {
    public let path: String
    public let bytes: Int64
    public let result: OperationResult
    public let reason: String?
    /// Raw refusal reason when the guard refused or skipped.
    public let refusal: RefusalReason?
}

/// Moves approved items to the Trash (or deletes them when the user chose permanent delete),
/// checking `PathGuard` again immediately before each item.
public struct SafeRemover: Sendable {
    public let pathGuard: PathGuard
    public let mode: DeleteMode
    public let context: PathContext
    /// Seconds of tolerance when comparing modification dates (file systems round).
    public var modificationTolerance: TimeInterval = 1
    /// Moves an item to the Trash. Injected in tests so they never touch the real Trash.
    public var trasher: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    public init(pathGuard: PathGuard, mode: DeleteMode = .trash, context: PathContext) {
        self.pathGuard = pathGuard; self.mode = mode; self.context = context
    }

    /// The same remover (guard, context, trasher, tolerance) with another delete mode.
    public func with(mode: DeleteMode) -> SafeRemover {
        var copy = SafeRemover(pathGuard: pathGuard, mode: mode, context: context)
        copy.trasher = trasher
        copy.modificationTolerance = modificationTolerance
        return copy
    }

    public func remove(_ requests: [RemovalRequest]) -> [RemovalOutcome] {
        requests.map(removeOne)
    }

    public func removeOne(_ request: RemovalRequest) -> RemovalOutcome {
        let path = pathGuard.expandTilde(request.path)
        let verdict = pathGuard.verdict(for: path, context: context)
        guard verdict.allowed else {
            let reason = verdict.reason ?? .protectedLocation
            let result: OperationResult = (reason == .whitelisted || reason == .containsWhitelisted) ? .skipped : .refused
            return RemovalOutcome(path: path, bytes: request.bytes, result: result, reason: reason.englishDescription, refusal: reason)
        }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return RemovalOutcome(path: path, bytes: request.bytes, result: .skipped, reason: RefusalReason.notFound.englishDescription, refusal: .notFound)
        }
        if let expected = request.expectedModificationDate {
            let current = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
            if current.timeIntervalSince(expected) > modificationTolerance {
                return RemovalOutcome(path: path, bytes: request.bytes, result: .skipped, reason: RefusalReason.changedSincePreview.englishDescription, refusal: .changedSincePreview)
            }
        }
        let url = URL(fileURLWithPath: path)
        do {
            switch mode {
            case .trash:
                try trasher(url)
                return RemovalOutcome(path: path, bytes: request.bytes, result: .trashed, reason: nil, refusal: nil)
            case .permanent:
                try FileManager.default.removeItem(at: url)
                return RemovalOutcome(path: path, bytes: request.bytes, result: .deleted, reason: nil, refusal: nil)
            }
        } catch {
            return RemovalOutcome(path: path, bytes: request.bytes, result: .failed, reason: SafeRemover.describe(error), refusal: nil)
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteNoPermissionError { return "Permission denied" }
        return ns.localizedDescription
    }

    /// Turns outcomes into operation log entries for one batch.
    public static func entries(_ outcomes: [RemovalOutcome], batchID: UUID, kind: OperationKind, title: String, date: Date = Date()) -> [OperationEntry] {
        outcomes.map {
            OperationEntry(date: date, batchID: batchID, kind: kind, title: title, path: $0.path, bytes: $0.bytes, result: $0.result, reason: $0.reason)
        }
    }
}

/// Detects whether this process has Full Disk Access by opening a file macOS protects with TCC.
public enum FullDiskAccess {
    public static let probePaths = [
        "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Safari/CloudTabs.db",
    ]

    public static func isGranted(probe: [String] = probePaths) -> Bool {
        for path in probe {
            let fd = open(path, O_RDONLY)
            if fd >= 0 { close(fd); return true }
        }
        return false
    }

    /// Deep link to Privacy & Security › Full Disk Access.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
