import Foundation

/// Moves items into a folder in a user's Trash (`~/.Trash/KeelMac`) instead of deleting them.
/// The helper runs as root, so `FileManager.trashItem` would use root's Trash; this puts the item where the
/// user who asked for the removal can see it and put it back.
public struct UserTrashMover: Sendable {
    public let folder: URL
    /// When set and the process runs as root, the folder is created owned by this user so Finder shows it normally.
    public let ownerUID: UInt32?

    public init(folder: URL, ownerUID: UInt32? = nil) {
        self.folder = folder
        self.ownerUID = ownerUID
    }

    /// `<home>/.Trash/KeelMac` for a user, or nil when the uid has no account.
    public static func forUser(uid: UInt32) -> UserTrashMover? {
        guard let account = UserAccount(uid: uid) else { return nil }
        return UserTrashMover(folder: URL(fileURLWithPath: account.home).appendingPathComponent(".Trash/KeelMac"), ownerUID: uid)
    }

    /// Moves `url` into the folder, never replacing anything there (`name 2.ext`, `name 3.ext`, … on collisions).
    @discardableResult
    public func move(_ url: URL) throws -> URL {
        try ensureFolder()
        let destination = freeDestination(for: url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    func ensureFolder() throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: folder.path]) }
            return
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let ownerUID, getuid() == 0 {
            _ = chown(folder.path, ownerUID, gid_t(UserAccount(uid: ownerUID)?.gid ?? 20))
        }
    }

    func freeDestination(for name: String) -> URL {
        let first = folder.appendingPathComponent(name)
        guard exists(first) else { return first }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}

/// A user account looked up by uid (`getpwuid_r`).
public struct UserAccount: Sendable, Equatable {
    public let uid: UInt32
    public let gid: UInt32
    public let name: String
    public let home: String

    public init?(uid: UInt32) {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        guard getpwuid_r(uid, &pwd, &buffer, buffer.count, &result) == 0, result != nil,
              let namePtr = pwd.pw_name, let dirPtr = pwd.pw_dir else { return nil }
        self.uid = uid
        self.gid = pwd.pw_gid
        self.name = String(cString: namePtr)
        self.home = String(cString: dirPtr)
    }
}
