import AppKit
import Darwin
import Foundation

/// Apps running now, through NSWorkspace.
public enum RunningApps {
    public static func bundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    public static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Running instances whose bundle is at `path` (the uninstall guard checks the exact copy).
    public static func isRunning(appAt path: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == path }
    }

    /// Whether LaunchServices knows an app with this bundle id that still exists outside the Trash.
    public static func isRegisteredApp(bundleID: String) -> Bool {
        !registeredAppPaths(bundleID: bundleID).isEmpty
    }

    /// LaunchServices, then Spotlight: any bundle with this id that still exists outside the Trash.
    public static func existsAnywhere(bundleID: String) -> Bool {
        if isRegisteredApp(bundleID: bundleID) { return true }
        return Spotlight.bundles(withID: bundleID).contains { path in
            !path.contains("/.Trash/") && !path.contains("/.Trashes/") && FileManager.default.fileExists(atPath: path)
        }
    }

    /// Paths of apps LaunchServices knows with this bundle id that still exist outside the Trash.
    public static func registeredAppPaths(bundleID: String) -> [String] {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).map(\.path).filter { path in
            !path.contains("/.Trash/") && !path.contains("/.Trashes/") && FileManager.default.fileExists(atPath: path)
        }
    }
}

/// The current user's processes, read with libproc (no root needed for our own processes).
enum ProcessPaths {
    static func pids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = buffer.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return Array(buffer.prefix(Int(filled))).filter { $0 > 0 }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Open vnode paths and executables of the user's processes that lie under any of `roots`.
    static func inUse(under roots: [String]) -> Set<String> {
        var out = Set<String>()
        func keep(_ path: String) {
            if roots.contains(where: { PathGuard_isWithin(path, $0) }) { out.insert(path) }
        }
        let fdInfoSize = MemoryLayout<proc_fdinfo>.stride
        for pid in pids() {
            if let exe = executablePath(pid) { keep(exe) }
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdInfoSize + 16)
            let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            guard used > 0 else { continue }
            for fd in fds.prefix(Int(used) / fdInfoSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
                let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw -> String in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
                    return String(decoding: bytes[..<end], as: UTF8.self)
                }
                if !path.isEmpty { keep(path) }
            }
        }
        return out
    }

    /// Bundle ids of every running executable that lives inside a bundle (agents and daemons NSWorkspace misses).
    static func runningBundleIDs() -> Set<String> {
        var ids = Set<String>()
        var seenBundles = Set<String>()
        for pid in pids() {
            guard let exe = executablePath(pid), let range = exe.range(of: ".app/", options: .backwards) else { continue }
            let bundle = String(exe[..<range.lowerBound]) + ".app"
            guard seenBundles.insert(bundle).inserted else { continue }
            if let bid = BundleReader.read(bundle: bundle)?.bundleID { ids.insert(bid) }
        }
        return ids
    }

    private static func PathGuard_isWithin(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}
