import Foundation

/// One fts walk per project: allocated size of everything, the newest file change outside generated folders, and
/// the git repositories inside it. Stays on one device, never follows symlinks, counts hard-linked files once.
public enum FolderWalker {
    public static func measure(_ path: String, skipping: Set<String> = ProjectSkipList.directories,
                               ignoringFiles: Set<String> = ProjectSkipList.files,
                               repositoriesOutside: Set<String> = ProjectSkipList.ignoredByBackup) -> FolderMeasure {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return FolderMeasure(bytes: 0, fileCount: 0, newestModified: nil, ownModified: nil, unreadable: 1)
        }
        let own = date(info.st_mtimespec)
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            return FolderMeasure(bytes: Int64(info.st_blocks) * 512, fileCount: 1, newestModified: own, ownModified: own, unreadable: 0)
        }
        guard let cPath = strdup(path) else { return FolderMeasure(bytes: 0, fileCount: 0, newestModified: nil, ownModified: own, unreadable: 1) }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return FolderMeasure(bytes: 0, fileCount: 0, newestModified: nil, ownModified: own, unreadable: 1)
        }
        defer { fts_close(fts) }

        struct Inode: Hashable { let dev: Int32; let ino: UInt64 }
        var seen = Set<Inode>()
        var bytes: Int64 = 0
        var files = 0
        var unreadable = 0
        var newest: Date?
        // fts is depth-first: everything between a skipped folder's FTS_D and its FTS_DP is inside it.
        var skipLevel: Int?
        let ignoredLengths = Set(ignoringFiles.map { $0.utf8.count })
        // Folders below the top that hold a `.git` folder or file, looked for everywhere but inside the folders a
        // backup ignores (and `.git` folders), which is wider than `skipping`: a repository in `vendor/` still counts.
        var repositories: [String] = []
        var noRepositoriesLevel: Int?
        func noteRepository(_ entry: UnsafeMutablePointer<FTSENT>) {
            let gitPath = String(cString: entry.pointee.fts_path)
            let folder = (gitPath as NSString).deletingLastPathComponent
            guard folder.count > path.count + 1, folder.hasPrefix(path) else { return }
            repositories.append(String(folder.dropFirst(path.hasSuffix("/") ? path.count : path.count + 1)))
        }

        while let entry = fts_read(fts) {
            let level = Int(entry.pointee.fts_level)
            switch Int32(entry.pointee.fts_info) {
            case FTS_DP:
                if skipLevel == level { skipLevel = nil }
                if noRepositoriesLevel == level { noRepositoriesLevel = nil }
            case FTS_DNR, FTS_ERR, FTS_NS:
                unreadable += 1
            case FTS_DC, FTS_NSOK:
                continue
            case FTS_D:
                if let st = entry.pointee.fts_statp?.pointee { bytes += Int64(st.st_blocks) * 512 }
                if level > 0, skipLevel == nil || noRepositoriesLevel == nil {
                    let n = name(entry)
                    if noRepositoriesLevel == nil {
                        if level > 1, n == ".git" { noteRepository(entry) }
                        if repositoriesOutside.contains(n) { noRepositoriesLevel = level }
                    }
                    if skipLevel == nil, skipping.contains(n) { skipLevel = level }
                }
            default:
                guard let st = entry.pointee.fts_statp?.pointee else { continue }
                // A `.git` file: a submodule checkout or a linked worktree.
                if noRepositoriesLevel == nil, level > 1, entry.pointee.fts_namelen == 4, name(entry) == ".git" { noteRepository(entry) }
                if st.st_nlink > 1 {
                    guard seen.insert(Inode(dev: st.st_dev, ino: st.st_ino)).inserted else { continue }
                }
                bytes += Int64(st.st_blocks) * 512
                files += 1
                guard skipLevel == nil else { continue }
                if ignoredLengths.contains(Int(entry.pointee.fts_namelen)), ignoringFiles.contains(name(entry)) { continue }
                let modified = date(st.st_mtimespec)
                if newest.map({ modified > $0 }) ?? true { newest = modified }
            }
        }
        // Outermost only: a repository inside a nested repository belongs to that one.
        let outermost = repositories.sorted().reduce(into: [String]()) { kept, repo in
            if !kept.contains(where: { repo.hasPrefix($0 + "/") }) { kept.append(repo) }
        }
        return FolderMeasure(bytes: bytes, fileCount: files, newestModified: newest, ownModified: own, unreadable: unreadable,
                             nestedRepositories: outermost)
    }

    static func date(_ spec: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1e9)
    }

    private static let nameOffset = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name)

    private static func name(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
        if let offset = nameOffset {
            return String(cString: UnsafeRawPointer(entry).advanced(by: offset).assumingMemoryBound(to: CChar.self))
        }
        return (String(cString: entry.pointee.fts_path) as NSString).lastPathComponent
    }
}
