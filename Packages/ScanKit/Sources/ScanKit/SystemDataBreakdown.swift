import Darwin
import Foundation

public enum SystemDataKind: String, Sendable, CaseIterable, Codable {
    case simulators, localSnapshots, swap, appCaches, temporaryFiles, systemCaches, logs, iosBackups, xcode, mailDownloads, other
}

public struct SystemDataItem: Sendable, Identifiable, Hashable {
    /// Same as `kind.rawValue`.
    public let id: String
    public let kind: SystemDataKind
    /// Folders measured; for `localSnapshots`, the snapshot names.
    public let paths: [String]
    /// Allocated bytes; nil when unknown (unreadable, or snapshot sizes not reported).
    public let bytes: Int64?
    /// True when privacy protection (EPERM) blocked part or all of the measurement.
    public let needsFullDiskAccess: Bool
    /// Matching `CleanKit.CleanupCategory` raw value, when a cleanup rule covers it.
    public let cleanupCategory: String?

    public init(kind: SystemDataKind, paths: [String], bytes: Int64?, needsFullDiskAccess: Bool, cleanupCategory: String?) {
        self.id = kind.rawValue
        self.kind = kind
        self.paths = paths
        self.bytes = bytes
        self.needsFullDiskAccess = needsFullDiskAccess
        self.cleanupCategory = cleanupCategory
    }
}

/// Runs an external command (absolute executable, argument array, never a shell string).
/// ScanKit has no SafetyKit dependency; the app can wrap `SafetyKit.CommandRunning` with `init(_:)`.
public struct ScanCommandRunner: Sendable {
    public struct Output: Sendable {
        public var exitCode: Int32
        public var stdout: String
        public init(exitCode: Int32, stdout: String) { self.exitCode = exitCode; self.stdout = stdout }
    }
    public let run: @Sendable (_ executable: String, _ arguments: [String]) async -> Output

    public init(_ run: @escaping @Sendable (_ executable: String, _ arguments: [String]) async -> Output) { self.run = run }

    /// Foundation `Process`, 30 s timeout.
    public static let process = ScanCommandRunner { executable, arguments in
        await withCheckedContinuation { (c: CheckedContinuation<Output, Never>) in
            DispatchQueue.global(qos: .utility).async {
                guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
                    c.resume(returning: Output(exitCode: 127, stdout: "")); return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { c.resume(returning: Output(exitCode: 126, stdout: "")); return }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                c.resume(returning: Output(exitCode: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

public enum SystemDataBreakdown {
    struct Location: Sendable {
        var kind: SystemDataKind
        var paths: [String]
        var cleanupCategory: String?
    }

    /// The folders behind each "System Data" kind for `home`.
    static func locations(home: String, userTempRoot: String?) -> [Location] {
        func h(_ rel: String) -> String { (home as NSString).appendingPathComponent(rel) }
        var swap = ["/private/var/vm"]
        if FileManager.default.fileExists(atPath: "/System/Volumes/VM") { swap.append("/System/Volumes/VM") }
        return [
            Location(kind: .simulators, paths: [h("Library/Developer/CoreSimulator")], cleanupCategory: "developer"),
            Location(kind: .swap, paths: swap, cleanupCategory: nil),
            Location(kind: .appCaches, paths: [h("Library/Caches")], cleanupCategory: "userCaches"),
            Location(kind: .temporaryFiles, paths: userTempRoot.map { [$0] } ?? [], cleanupCategory: nil),
            Location(kind: .systemCaches, paths: ["/Library/Caches"], cleanupCategory: nil),
            Location(kind: .logs, paths: [h("Library/Logs"), "/private/var/log"], cleanupCategory: "logs"),
            Location(kind: .iosBackups, paths: [h("Library/Application Support/MobileSync/Backup")], cleanupCategory: "iosBackups"),
            Location(kind: .xcode, paths: [h("Library/Developer/Xcode")], cleanupCategory: "developer"),
            Location(kind: .mailDownloads, paths: [h("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")], cleanupCategory: nil),
        ]
    }

    /// The current user's part of `/private/var/folders` (parent of `DARWIN_USER_TEMP_DIR`).
    static func userTempRoot() -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        var temp: String
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 {
            temp = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        } else {
            temp = NSTemporaryDirectory()
        }
        let resolved = realpath(temp, nil).map { p -> String in defer { free(p) }; return String(cString: p) } ?? temp
        let parent = (ScanTree.normalize(resolved) as NSString).deletingLastPathComponent
        return parent.hasPrefix("/private/var/folders/") ? parent : nil
    }

    /// Sizes for the known "System Data" locations. Order follows `SystemDataKind` (without `other`).
    public static func measure(home: String, runner: ScanCommandRunner = .process) async -> [SystemDataItem] {
        await measure(locations: locations(home: home, userTempRoot: userTempRoot()), runner: runner)
    }

    static func measure(locations locs: [Location], runner: ScanCommandRunner) async -> [SystemDataItem] {
        var items: [SystemDataItem] = []
        for loc in locs {
            if Task.isCancelled { break }
            var total: Int64 = 0
            var known = false
            var fda = false
            for p in loc.paths {
                let m = await measurePath(p)
                if let b = m.bytes { total += b; known = true }
                fda = fda || m.privacyBlocked
            }
            items.append(SystemDataItem(kind: loc.kind, paths: loc.paths, bytes: known || loc.paths.isEmpty ? total : nil,
                                        needsFullDiskAccess: fda, cleanupCategory: loc.cleanupCategory))
        }
        items.insert(await localSnapshots(runner: runner), at: min(1, items.count))
        let order = SystemDataKind.allCases
        return items.sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }

    struct PathMeasure: Sendable {
        var bytes: Int64?
        var privacyBlocked: Bool
    }

    /// Allocated size of a folder with the bulk walker. Missing folders measure 0.
    static func measurePath(_ path: String) async -> PathMeasure {
        var st = stat()
        if lstat(path, &st) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return PathMeasure(bytes: 0, privacyBlocked: false) }
            return PathMeasure(bytes: nil, privacyBlocked: errno == EPERM)
        }
        if (st.st_mode & S_IFMT) != S_IFDIR { return PathMeasure(bytes: Int64(st.st_blocks) * 512, privacyBlocked: false) }
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        if fd < 0 { return PathMeasure(bytes: nil, privacyBlocked: errno == EPERM) }
        close(fd)
        do {
            let config = ScanConfiguration(largeFileThreshold: .max)
            let (tree, _) = try await ScanEngine.fullScan(root: path, exclusions: [], config: config, captureEvents: false) { _ in }
            // A folder blocked by privacy protection reports EPERM; plain POSIX denials (EACCES) are not fixed by FDA.
            let blocked = !tree.unreadable.isEmpty && tree.unreadable.contains { probeEPERM($0) }
            return PathMeasure(bytes: tree.totalBytesOnDisk, privacyBlocked: blocked)
        } catch ScanError.rootUnreadable(_, let code) {
            return PathMeasure(bytes: nil, privacyBlocked: code == EPERM)
        } catch {
            return PathMeasure(bytes: nil, privacyBlocked: false)
        }
    }

    static func probeEPERM(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 { close(fd); return false }
        return errno == EPERM
    }

    // MARK: Local snapshots

    static func localSnapshots(runner: ScanCommandRunner) async -> SystemDataItem {
        let list = await runner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        let names = parseSnapshotList(list.stdout)
        var bytes: Int64? = names.isEmpty && list.exitCode == 0 ? 0 : nil
        if !names.isEmpty {
            let apfs = await runner.run("/usr/sbin/diskutil", ["apfs", "listSnapshots", "/"])
            if apfs.exitCode == 0, let sizes = parseSnapshotSizes(apfs.stdout, names: names) { bytes = sizes }
        }
        return SystemDataItem(kind: .localSnapshots, paths: names, bytes: bytes, needsFullDiskAccess: false, cleanupCategory: nil)
    }

    /// `tmutil listlocalsnapshots /` prints a header line then one snapshot name per line.
    static func parseSnapshotList(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.") || ($0.contains(".local") && !$0.contains(" ")) }
    }

    /// Sums per-snapshot sizes if `diskutil apfs listSnapshots` reports any ("Size: … (N Bytes)"); nil otherwise.
    static func parseSnapshotSizes(_ text: String, names: [String]) -> Int64? {
        var total: Int64 = 0
        var found = false
        var currentMatches = false
        let wanted = Set(names)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " |+-"))
            if line.hasPrefix("Name:") {
                let name = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                currentMatches = wanted.contains(name)
            } else if currentMatches, line.range(of: "size", options: .caseInsensitive) != nil,
                      let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close {
                let inner = line[line.index(after: open)..<close]
                let digits = inner.split(separator: " ").first.map(String.init) ?? ""
                if let n = Int64(digits) { total += n; found = true }
            }
        }
        return found ? total : nil
    }
}
