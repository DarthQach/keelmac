import Foundation
import CoreServices
import Security

/// Allocated size of a file or folder: an fts walk that stays on one device, never follows symlinks and counts
/// hard-linked files once.
public enum FileSizer {
    public static func allocatedSize(of path: String) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        if (info.st_mode & S_IFMT) != S_IFDIR { return Int64(info.st_blocks) * 512 }

        guard let cPath = strdup(path) else { return 0 }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }

        struct Inode: Hashable { let dev: Int32; let ino: UInt64 }
        var seen = Set<Inode>()
        var total: Int64 = 0
        while let entry = fts_read(fts) {
            let kind = Int32(entry.pointee.fts_info)
            switch kind {
            case FTS_DP, FTS_DNR, FTS_ERR, FTS_NS, FTS_NSOK, FTS_DC:
                continue
            default:
                guard let st = entry.pointee.fts_statp?.pointee else { continue }
                if (st.st_mode & S_IFMT) != S_IFDIR && st.st_nlink > 1 {
                    guard seen.insert(Inode(dev: st.st_dev, ino: st.st_ino)).inserted else { continue }
                }
                total += Int64(st.st_blocks) * 512
            }
        }
        return total
    }

    static func modificationDate(of path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Names in a folder, without hidden entries. Empty when unreadable.
    static func list(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }
}

/// Reads bundle metadata straight from Info.plist (no `Bundle` cache, works on bundles in the Trash).
enum BundleReader {
    struct Info: Sendable {
        let bundleID: String?
        let displayName: String?
        let bundleName: String?
        let version: String?
    }

    static func infoPlistPath(forBundle path: String) -> String? {
        let candidates = [
            path + "/Contents/Info.plist",
            path + "/WrappedBundle/Info.plist",   // iPhone and iPad apps on Apple silicon
            path + "/Info.plist",
        ]
        if let hit = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) { return hit }
        let wrapper = path + "/Wrapper"
        if let inner = FileSystemList.first(in: wrapper, suffix: ".app") {
            let plist = wrapper + "/" + inner + "/Info.plist"
            if FileManager.default.fileExists(atPath: plist) { return plist }
        }
        return nil
    }

    static func plist(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func read(bundle path: String) -> Info? {
        guard let plistPath = infoPlistPath(forBundle: path), let dict = plist(at: plistPath) else { return nil }
        func string(_ key: String) -> String? {
            guard let value = dict[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return Info(bundleID: string("CFBundleIdentifier"),
                    displayName: string("CFBundleDisplayName"),
                    bundleName: string("CFBundleName"),
                    version: string("CFBundleShortVersionString") ?? string("CFBundleVersion"))
    }

    static func stem(of path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return (last as NSString).deletingPathExtension
    }
}

enum FileSystemList {
    static func first(in dir: String, suffix: String) -> String? {
        FileSizer.list(dir).first { $0.hasSuffix(suffix) }
    }
}

enum CodeSignature {
    /// The signing team, read from the code directory without validating the signature.
    static func teamID(ofBundle path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        guard let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }
}

enum Spotlight {
    static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
