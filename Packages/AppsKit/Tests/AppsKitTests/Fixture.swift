import Foundation

/// A throwaway folder tree in the temp directory. Never the real home, Library or Trash.
final class Fixture: @unchecked Sendable {
    let root: String

    init() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("appskit-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // /var/folders → /private/var/folders, the form PathGuard compares.
        root = URL(fileURLWithPath: base.path).resolvingSymlinksInPath().path.replacingOccurrences(
            of: "^/var/", with: "/private/var/", options: .regularExpression)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    var home: String { root + "/home" }
    var library: String { home + "/Library" }

    func path(_ relative: String) -> String { root + "/" + relative }

    @discardableResult
    func dir(_ relative: String) -> String {
        let p = path(relative)
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 4096, modified: Date? = nil) -> String {
        let p = path(relative)
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data(repeating: 7, count: bytes))
        if let modified { setModified(p, modified) }
        return p
    }

    @discardableResult
    func plist(_ relative: String, _ dict: [String: Any], modified: Date? = nil) -> String {
        let p = path(relative)
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        FileManager.default.createFile(atPath: p, contents: data)
        if let modified { setModified(p, modified) }
        return p
    }

    /// A fake bundle: Contents/Info.plist plus an executable-sized file.
    @discardableResult
    func app(_ relative: String, bundleID: String?, name: String? = nil, displayName: String? = nil,
             version: String? = "1.0", payload: Int = 64 * 1024) -> String {
        var info: [String: Any] = [:]
        if let bundleID { info["CFBundleIdentifier"] = bundleID }
        if let name { info["CFBundleName"] = name }
        if let displayName { info["CFBundleDisplayName"] = displayName }
        if let version { info["CFBundleShortVersionString"] = version }
        plist(relative + "/Contents/Info.plist", info)
        file(relative + "/Contents/MacOS/bin", bytes: payload)
        return path(relative)
    }

    func setModified(_ path: String, _ date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }
}
