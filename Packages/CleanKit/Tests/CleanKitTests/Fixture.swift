import Foundation
import SafetyKit
@testable import CleanKit

/// A throwaway home folder in the temp directory with every kind of thing the bundled rules look at,
/// plus things they must never select. Nothing here touches the real home, the real Trash or real tools.
final class Fixture: @unchecked Sendable {
    let root: String
    let home: String
    let trashBin: String
    let now = Date()
    let uid: UInt32 = 501
    static let unavailableUDID = "11111111-2222-3333-4444-555555555555"
    static let availableUDID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    let state = RunnerState()

    init(populate: Bool = true) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        root = PathGuard.canonical(tmp + "/cleankit-\(UUID().uuidString)")
        home = root + "/home"
        trashBin = root + "/fake-trash"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: trashBin, withIntermediateDirectories: true)
        if populate { try build() }
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    // MARK: - Building

    func path(_ rel: String) -> String { home + "/" + rel }

    @discardableResult
    func file(_ rel: String, bytes: Int = 4096) throws -> String {
        let p = path(rel)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: URL(fileURLWithPath: p))
        return p
    }

    func dir(_ rel: String) throws {
        try FileManager.default.createDirectory(atPath: path(rel), withIntermediateDirectories: true)
    }

    func symlink(_ rel: String, to destination: String) throws {
        try FileManager.default.createDirectory(atPath: (path(rel) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path(rel), withDestinationPath: destination)
    }

    /// Sets the modification date of an item and everything inside it (without following symlinks).
    func age(_ rel: String, days: Double) {
        setDate(rel.isEmpty ? home : path(rel), now.addingTimeInterval(-days * 86_400))
    }

    func setDate(_ p: String, _ date: Date) {
        var isDir: ObjCBool = false
        var st = stat()
        guard lstat(p, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) == S_IFLNK {
            var times = [timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0),
                         timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)]
            _ = utimensat(AT_FDCWD, p, &times, AT_SYMLINK_NOFOLLOW)
            return
        }
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue,
           let children = try? FileManager.default.contentsOfDirectory(atPath: p) {
            for c in children { setDate(p + "/" + c, date) }
        }
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: p)
    }

    func exists(_ rel: String) -> Bool {
        var st = stat()
        return lstat(path(rel), &st) == 0
    }

    private func build() throws {
        // Developer
        try file("Library/Developer/Xcode/DerivedData/ProjA-abc/Build/Products/a.o", bytes: 64 * 1024)
        try file("Library/Developer/Xcode/DerivedData/ProjB-def/Index.noindex/b.idx", bytes: 32 * 1024)
        try file("Library/Developer/Xcode/Archives/2020-01-01/Old.xcarchive/Info.plist")
        try file("Library/Developer/Xcode/Archives/2026-10-01/New.xcarchive/Info.plist")
        try file("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)/Symbols/dyld")
        try file("Library/Developer/Xcode/iOS DeviceSupport/18.0 (22A3354)/Symbols/dyld")
        try file("Library/Developer/Xcode/iOS DeviceSupport/iPhone18,2 26.5.1 (23F81)/Symbols/dyld")
        try file("Library/Developer/Xcode/watchOS DeviceSupport/10.0 (21R355)/Symbols/dyld")
        try file("Library/Developer/CoreSimulator/Devices/\(Fixture.unavailableUDID)/data/disk.img", bytes: 128 * 1024)
        try file("Library/Developer/CoreSimulator/Devices/\(Fixture.availableUDID)/data/disk.img", bytes: 16 * 1024)
        try file("Library/Caches/org.swift.swiftpm/repositories/swift-argument-parser/HEAD")
        try file("Library/Caches/org.swift.swiftpm/manifests/m.json")
        try file(".npm/_cacache/index-v5/aa/bb")
        try file(".npm/_logs/debug.log")
        try file("Library/Caches/Yarn/v6/npm-left-pad/index.js")
        try file("Library/Caches/Homebrew/downloads/wget.tar.gz", bytes: 40 * 1024)
        try file("Library/Caches/CocoaPods/Pods/Release/Alamofire/a.swift")
        try file(".gradle/caches/modules-2/files-2.1/g.jar")
        try file(".gradle/wrapper/dists/gradle-8/gradle.zip")
        try file("Library/pnpm/store/v10/files/00/abc", bytes: 24 * 1024)

        // App caches
        try file("Library/Caches/com.example.editor/Cache.db", bytes: 20 * 1024)
        try file("Library/Caches/com.running.app/Cache.db")
        try file("Library/Caches/com.running.app.helper/Cache.db")
        try file("Library/Caches/com.running.app.ShipIt/update.zip")
        try file("Library/Caches/CloudKit/state.db")
        try file("Library/Caches/com.apple.bird/session.db")
        try file("Library/Caches/com.apple.iCloudNotificationAgent/x.db")
        try file("Library/Caches/com.apple.nsservicescache.plist")
        try file("Library/Caches/ms-playwright/chromium-1100/chrome")
        try file("Library/Caches/loose.cache")
        try FileManager.default.createDirectory(atPath: root + "/outside", withIntermediateDirectories: true)
        try Data(repeating: 1, count: 512 * 1024).write(to: URL(fileURLWithPath: root + "/outside/big.bin"))
        try symlink("Library/Caches/linked", to: root + "/outside")

        // Browsers
        try file("Library/Caches/Google/Chrome/Default/Cache/Cache_Data/f_000001")
        try file("Library/Caches/Google/Chrome-headless/x")
        try file("Library/Caches/Arc/Cache_Data/index")
        try file("Library/Caches/company.thebrowser.Browser/Cache.db")
        try file("Library/Caches/Firefox/Profiles/abc.default-release/cache2/entries/E1")
        try file("Library/Caches/Firefox/Profiles/abc.default-release/settings/main.json")
        try file("Library/Caches/Microsoft Edge/Default/Cache/x")
        try file("Library/Caches/com.apple.Safari/Cache.db")
        try file("Library/Caches/com.apple.Safari.SafeBrowsing/db")
        try file("Library/Safari/History.db")
        try file("Library/Application Support/Google/Chrome/Default/History")

        // Logs
        try file("Library/Logs/OldApp/old.log")
        try file("Library/Logs/NewApp/new.log")
        try file("Library/Logs/MixedApp/old.log")
        try file("Library/Logs/MixedApp/new.log")
        try file("Library/Logs/old-file.log")
        try file("Library/Logs/DiagnosticReports/Old-2026-09-01.ips")
        try file("Library/Logs/DiagnosticReports/New-2026-10-21.ips")

        // Installers
        for name in ["a.dmg", "b.pkg", "c.xip", "d.mpkg", "notes.txt", "Sub/e.dmg", "photo.dmg.download"] {
            try file("Downloads/" + name)
        }

        // iOS backups
        let backup = "Library/Application Support/MobileSync/Backup/00008110-001A2B3C4D5E"
        try file(backup + "/Manifest.db", bytes: 16 * 1024)
        let info: [String: Any] = ["Device Name": "Carlos’s iPhone", "Product Type": "iPhone16,1", "Product Version": "18.0",
                                   "Last Backup Date": Date(timeIntervalSince1970: 1_750_000_000)]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: URL(fileURLWithPath: path(backup + "/Info.plist")))
        try PropertyListSerialization.data(fromPropertyList: ["IsEncrypted": true], format: .xml, options: 0).write(to: URL(fileURLWithPath: path(backup + "/Manifest.plist")))

        // Language files
        for lang in ["en", "es", "fr", "de", "Base", "ja", "en_GB", "Spanish"] {
            try file("Applications/Unsigned.app/Contents/Resources/\(lang).lproj/Localizable.strings")
        }
        try file("Applications/Unsigned.app/Contents/MacOS/Unsigned")
        try file("Applications/Signed.app/Contents/_CodeSignature/CodeResources")
        try file("Applications/Signed.app/Contents/Resources/fr.lproj/Localizable.strings")
        try file("Applications/Embedded.app/Contents/Resources/fr.lproj/Localizable.strings")

        // Trash
        try file(".Trash/old.txt")
        try file(".Trash/Folder/inner.txt")
        try file("Volumes/Ext/.Trashes/501/v.txt")
        try file("Volumes/Ext/.Trashes/502/other-user.txt")
        try FileManager.default.createDirectory(atPath: root + "/linkedvol/.Trashes/501", withIntermediateDirectories: true)
        try Data(repeating: 2, count: 100).write(to: URL(fileURLWithPath: root + "/linkedvol/.Trashes/501/secret.txt"))
        try symlink("Volumes/Macintosh HD", to: root + "/linkedvol")

        // Protected
        try file("Library/Mail/V10/INBOX.mbox/1.emlx")
        try file("Library/Mobile Documents/com~apple~CloudDocs/doc.txt")
        try file("Library/Keychains/login.keychain-db")

        // Dates: everything three days old, then the specific ages the rules care about.
        age("", days: 3)
        age("Library/Developer/Xcode/Archives/2020-01-01", days: 400)
        age("Library/Developer/Xcode/Archives/2026-10-01", days: 20)
        age("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)", days: 300)
        age("Library/Developer/Xcode/iOS DeviceSupport/18.0 (22A3354)", days: 100)
        age("Library/Developer/Xcode/iOS DeviceSupport/iPhone18,2 26.5.1 (23F81)", days: 10)
        age("Library/Logs/OldApp", days: 30)
        age("Library/Logs/MixedApp/old.log", days: 30)
        age("Library/Logs/old-file.log", days: 30)
        age("Library/Logs/NewApp", days: 1)
        age("Library/Logs/MixedApp/new.log", days: 1)
        age("Library/Logs/DiagnosticReports/Old-2026-09-01.ips", days: 40)
        age("Library/Logs/DiagnosticReports/New-2026-10-21.ips", days: 1)
    }

    // MARK: - Environment

    static let defaultTools: Set<String> = ["/usr/bin/xcrun", "/opt/homebrew/bin/brew", "/opt/homebrew/bin/pnpm", "/usr/local/bin/docker"]

    func pathGuard(whitelist: Whitelist = Whitelist()) -> PathGuard {
        PathGuard(home: home, userName: "tester", uid: uid, whitelist: whitelist)
    }

    func environment(fda: Bool = true, running: Set<String> = [], tools: Set<String> = Fixture.defaultTools,
                     preferred: [String] = ["de-DE"]) -> CleanupEnvironment {
        CleanupEnvironment(home: home, hasFullDiskAccess: fda, runningBundleIDs: running, now: now, uid: uid,
                           volumesRoot: home + "/Volumes", preferredLanguages: preferred,
                           isExecutable: { tools.contains($0) })
    }

    func runner() -> RecordingCommandRunner {
        let state = self.state
        let storePath = path("Library/pnpm/store/v10")
        return RecordingCommandRunner { exe, args in state.respond(exe, args, storePath: storePath) }
    }

    func planner(rules: RuleSet? = nil, env: CleanupEnvironment? = nil, runner: RecordingCommandRunner? = nil,
                 whitelist: Whitelist = Whitelist()) throws -> (CleanupPlanner, RecordingCommandRunner) {
        let r = runner ?? self.runner()
        return (CleanupPlanner(rules: try rules ?? RuleSet.bundled(), pathGuard: pathGuard(whitelist: whitelist),
                               environment: env ?? environment(), runner: r), r)
    }

    func plan(rules: RuleSet? = nil, env: CleanupEnvironment? = nil, runner: RecordingCommandRunner? = nil) async throws -> CleanupPlan {
        try await planner(rules: rules, env: env, runner: runner).0.plan()
    }

    /// A remover whose "Trash" is a folder in the fixture root.
    func remover(whitelist: Whitelist = Whitelist(), trasherCalls: CallLog? = nil) -> SafeRemover {
        var r = SafeRemover(pathGuard: pathGuard(whitelist: whitelist), mode: .trash, context: .cleanup)
        let bin = trashBin
        r.trasher = { url in
            trasherCalls?.append(url.path)
            try FileManager.default.moveItem(atPath: url.path, toPath: bin + "/" + UUID().uuidString + "-" + url.lastPathComponent)
        }
        return r
    }
}

/// Canned tool responses for the fixture. Mutable so a command can change what a later measurement sees.
final class RunnerState: @unchecked Sendable {
    private let lock = NSLock()
    private var _simulatorsDeleted = false
    var dockerInfoExit: Int32 = 0
    var dockerDF = """
    {"Active":"1","Reclaimable":"2.5GB (60%)","Size":"4.1GB","TotalCount":"5","Type":"Images"}
    {"Active":"0","Reclaimable":"120MB (100%)","Size":"120MB","TotalCount":"3","Type":"Containers"}
    {"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Local Volumes"}
    {"Active":"0","Reclaimable":"1.5GB","Size":"1.5GB","TotalCount":"40","Type":"Build Cache"}
    """
    var failCommands: Set<String> = []

    var simulatorsDeleted: Bool { lock.withLock { _simulatorsDeleted } }

    func respond(_ exe: String, _ args: [String], storePath: String) -> CommandResult {
        let ok = { (out: String) in CommandResult(exitCode: 0, stdout: out, stderr: "") }
        if failCommands.contains(([exe] + args).joined(separator: " ")) {
            return CommandResult(exitCode: 1, stdout: "", stderr: "Error: something went wrong")
        }
        switch (exe, args) {
        case ("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"]):
            let deleted = lock.withLock { _simulatorsDeleted }
            let devices = deleted ? "" : """
            {"dataPath":"/x/\(Fixture.unavailableUDID)/data","isAvailable":false,"name":"iPhone 12","udid":"\(Fixture.unavailableUDID)","availabilityError":"runtime profile not found"}
            """
            return ok("{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-16-0\":[\(devices)],\"com.apple.CoreSimulator.SimRuntime.iOS-27-0\":[]}}")
        case ("/usr/bin/xcrun", ["simctl", "delete", "unavailable"]):
            lock.withLock { _simulatorsDeleted = true }
            return ok("")
        case ("/usr/local/bin/docker", let a) where a.first == "info":
            return CommandResult(exitCode: dockerInfoExit, stdout: dockerInfoExit == 0 ? "27.3.1" : "", stderr: dockerInfoExit == 0 ? "" : "Cannot connect to the Docker daemon")
        case ("/usr/local/bin/docker", ["system", "df", "--format", "{{json .}}"]):
            return ok(dockerDF)
        case ("/opt/homebrew/bin/pnpm", ["store", "path"]):
            return ok(storePath + "\n")
        case ("/usr/bin/codesign", let a) where a.first == "-dv":
            if a.last?.hasSuffix("Unsigned.app") == true {
                return CommandResult(exitCode: 1, stdout: "", stderr: "\(a.last!): code object is not signed at all")
            }
            return CommandResult(exitCode: 0, stdout: "", stderr: "Executable=...\nSignature=adhoc")
        default:
            return ok("")
        }
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String] = []
    func append(_ s: String) { lock.withLock { _items.append(s) } }
    var items: [String] { lock.withLock { _items } }
}

extension CleanupPlan {
    func paths(_ ruleID: String) -> Set<String> { Set(group(id: ruleID)?.items.map(\.path) ?? []) }
}

func rule(_ id: String, _ paths: [String], category: CleanupCategory = .userCaches, exclude: [String] = [],
          optIn: Bool = false) -> CleanupRule {
    CleanupRule(id: id, category: category, title: LocalizedText(en: id, es: id), detail: LocalizedText(en: id, es: id),
                paths: paths, exclude: exclude, optIn: optIn)
}
