import CryptoKit
import Darwin
import Foundation
import SafetyKit

/// Finds byte-identical files under a set of folders.
///
/// Stages: list regular files (skipping hidden files, symlinks, zero-byte files, anything `PathGuard`
/// refuses for `.userFile`, and the inside of packages such as `.app` or `.photoslibrary`), bucket them
/// by size, compare SHA-256 of the first and last 64 KB, then compare a full SHA-256 streamed in 1 MB
/// chunks. Hard links to the same inode count as one file (the smallest path is kept), so a group never
/// offers to remove a link whose data is shared with the copy you keep.
///
/// File contents are only ever read through `FileHandle`, a chunk at a time. Cancelling the calling task
/// stops the search at the next file or chunk with `CancellationError`.
public actor DuplicateFinder {
    /// Bytes hashed at each end of a file in the quick comparison.
    public static let edgeBytes = 64 * 1024
    /// Chunk size for the full hash.
    public static let chunkBytes = 1024 * 1024
    /// Folder extensions treated as opaque even when Launch Services doesn't flag them as packages.
    public static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "prefpane", "saver", "qlgenerator",
        "mdimporter", "component", "vst", "vst3", "aaxplugin", "photoslibrary", "photolibrary", "aplibrary",
        "musiclibrary", "tvlibrary", "imovielibrary", "theater", "fcpbundle", "logicx", "band", "sparsebundle",
        "xcodeproj", "xcworkspace", "playground", "xcarchive", "dsym", "docarchive", "pages", "numbers", "key",
        "rtfd", "scptd", "wdgt", "lpdf", "nib", "storyboardc", "momd", "car",
    ]

    private let pathGuard: PathGuard

    public init(pathGuard: PathGuard) {
        self.pathGuard = pathGuard
    }

    /// Duplicate groups under `roots`, files of at least `minBytes` (and never empty files).
    public func find(
        roots: [String],
        minBytes: Int64,
        progress: @escaping @Sendable (DuplicateProgress) -> Void
    ) async throws -> [DuplicateGroup] {
        try await search(roots: roots, minBytes: minBytes, progress: progress).groups
    }

    /// Like `find`, plus the unreadable paths and skip counts the Duplicates screen lists.
    public func search(
        roots: [String],
        minBytes: Int64,
        progress: @escaping @Sendable (DuplicateProgress) -> Void
    ) async throws -> DuplicateSearchResult {
        var report = Report()

        // 1. Listing
        let listed = try list(roots: roots, minBytes: max(minBytes, 1), report: &report, progress: progress)

        // 2. Size buckets, hard links collapsed
        progress(DuplicateProgress(stage: .groupingBySize, done: 0, total: listed.count))
        var bySize: [Int64: [Candidate]] = [:]
        for (index, file) in listed.enumerated() {
            if index % 1024 == 0 { try Task.checkCancellation() }
            bySize[file.bytes, default: []].append(file)
        }
        var sizeBuckets: [[Candidate]] = []
        var groupedDone = 0
        for size in bySize.keys.sorted(by: >) {
            try Task.checkCancellation()
            let bucket = bySize[size] ?? []
            groupedDone += bucket.count
            guard bucket.count > 1 else { continue }
            let unique = collapseHardLinks(bucket, report: &report)
            if unique.count > 1 { sizeBuckets.append(unique) }
        }
        progress(DuplicateProgress(stage: .groupingBySize, done: groupedDone, total: listed.count))

        // 3. Head and tail hashes
        let headTotal = sizeBuckets.reduce(0) { $0 + $1.count }
        var headDone = 0
        progress(DuplicateProgress(stage: .hashingHeads, done: 0, total: headTotal))
        var headBuckets: [[Candidate]] = []
        for bucket in sizeBuckets {
            var byEdges: [Data: [Candidate]] = [:]
            for file in bucket {
                try Task.checkCancellation()
                if let digest = edgeDigest(of: file) {
                    byEdges[digest, default: []].append(file)
                } else {
                    report.unreadable.insert(file.path)
                }
                headDone += 1
                progress(DuplicateProgress(stage: .hashingHeads, done: headDone, total: headTotal))
            }
            headBuckets += byEdges.values.filter { $0.count > 1 }
        }

        // 4. Full hashes
        let fullTotal = headBuckets.reduce(0) { $0 + $1.count }
        var fullDone = 0
        progress(DuplicateProgress(stage: .hashingFull, done: 0, total: fullTotal))
        var groups: [DuplicateGroup] = []
        for bucket in headBuckets {
            var byHash: [String: [Candidate]] = [:]
            for file in bucket {
                try Task.checkCancellation()
                if let digest = try fullDigest(of: file) {
                    byHash[digest, default: []].append(file)
                } else {
                    report.unreadable.insert(file.path)
                }
                fullDone += 1
                progress(DuplicateProgress(stage: .hashingFull, done: fullDone, total: fullTotal))
            }
            for (hash, files) in byHash where files.count > 1 {
                groups.append(DuplicateGroup(id: hash, bytesEach: files[0].bytes, files: files.map(\.file)))
            }
        }

        groups.sort { $0.wastedBytes != $1.wastedBytes ? $0.wastedBytes > $1.wastedBytes : $0.id < $1.id }
        return DuplicateSearchResult(
            groups: groups,
            unreadablePaths: report.unreadable.sorted(),
            protectedSkipped: report.protectedSkipped,
            filesConsidered: listed.count
        )
    }

    // MARK: - Listing

    private struct Candidate: Sendable {
        let path: String
        let bytes: Int64
        let modified: Date
        let created: Date?

        var file: DuplicateFile { DuplicateFile(path: path, bytes: bytes, modified: modified, created: created) }
    }

    private struct Report {
        var unreadable: Set<String> = []
        var protectedSkipped = 0
    }

    private final class ErrorSink {
        var paths: [String] = []
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey,
    ]
    private static let resourceKeySet = Set(resourceKeys)

    /// Synchronous on purpose: `FileManager.DirectoryEnumerator` can't be iterated from async code.
    private func list(
        roots: [String],
        minBytes: Int64,
        report: inout Report,
        progress: @Sendable (DuplicateProgress) -> Void
    ) throws -> [Candidate] {
        let fm = FileManager.default
        var seenPaths: Set<String> = []
        var out: [Candidate] = []
        var seen = 0
        progress(DuplicateProgress(stage: .listing, done: 0, total: 0))

        func consider(_ url: URL, _ values: URLResourceValues) {
            let path = url.path
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
            let bytes = Int64(values.fileSize ?? 0)
            guard bytes >= minBytes, !seenPaths.contains(path) else { return }
            guard pathGuard.verdict(for: path, context: .userFile).allowed else {
                report.protectedSkipped += 1
                return
            }
            seenPaths.insert(path)
            out.append(Candidate(
                path: path, bytes: bytes,
                modified: values.contentModificationDate ?? .distantPast,
                created: values.creationDate
            ))
        }

        for rawRoot in roots {
            try Task.checkCancellation()
            let expanded = pathGuard.expandTilde(rawRoot)
            guard expanded.hasPrefix("/") else { continue }
            // The chosen folder itself may be reached through a symlink (/tmp); nothing below it is followed.
            let rootURL = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
            guard let rootValues = try? rootURL.resourceValues(forKeys: Self.resourceKeySet) else {
                report.unreadable.insert(rootURL.path)
                continue
            }
            if rootValues.isRegularFile == true {
                consider(rootURL, rootValues)
                continue
            }
            guard rootValues.isDirectory == true, !isPackage(rootURL, rootValues) else { continue }
            if shouldSkipDirectory(rootURL.path) {
                report.protectedSkipped += 1
                continue
            }

            let sink = ErrorSink()
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Self.resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, _ in sink.paths.append(url.path); return true }
            ) else {
                report.unreadable.insert(rootURL.path)
                continue
            }

            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: Self.resourceKeySet) else {
                    report.unreadable.insert(url.path)
                    continue
                }
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    if isPackage(url, values) {
                        enumerator.skipDescendants()
                    } else if shouldSkipDirectory(url.path) {
                        report.protectedSkipped += 1
                        enumerator.skipDescendants()
                    }
                    continue
                }
                seen += 1
                if seen % 256 == 0 { progress(DuplicateProgress(stage: .listing, done: seen, total: 0)) }
                consider(url, values)
            }
            report.unreadable.formUnion(sink.paths)
        }
        progress(DuplicateProgress(stage: .listing, done: seen, total: 0))
        return out
    }

    private func isPackage(_ url: URL, _ values: URLResourceValues) -> Bool {
        values.isPackage == true || Self.packageExtensions.contains(url.pathExtension.lowercased())
    }

    /// A folder is left out entirely when PathGuard refuses it for a reason that also covers its contents.
    /// Container folders (~/Documents) and folders holding a whitelisted item are still walked; their files
    /// are checked one by one.
    private func shouldSkipDirectory(_ path: String) -> Bool {
        let verdict = pathGuard.verdict(for: path, context: .userFile)
        guard !verdict.allowed, let reason = verdict.reason else { return false }
        switch reason {
        case .containerFolder, .containsWhitelisted: return false
        default: return true
        }
    }

    /// Keeps one path per (device, inode), the smallest path.
    private func collapseHardLinks(_ files: [Candidate], report: inout Report) -> [Candidate] {
        var byInode: [FileIdentity: Candidate] = [:]
        for file in files {
            var info = stat()
            guard lstat(file.path, &info) == 0 else {
                report.unreadable.insert(file.path)
                continue
            }
            let key = FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
            if let existing = byInode[key], existing.path <= file.path { continue }
            byInode[key] = file
        }
        return byInode.values.sorted { $0.path < $1.path }
    }

    private struct FileIdentity: Hashable {
        let device: Int64
        let inode: UInt64
    }

    // MARK: - Hashing

    /// SHA-256 of the first 64 KB followed by the last 64 KB (the whole file, twice, when it is small).
    private func edgeDigest(of file: Candidate) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? handle.close() }
        do {
            var hasher = SHA256()
            let head = try handle.read(upToCount: Self.edgeBytes) ?? Data()
            hasher.update(data: head)
            let tailStart = UInt64(max(file.bytes - Int64(Self.edgeBytes), 0))
            try handle.seek(toOffset: tailStart)
            let tail = try handle.read(upToCount: Self.edgeBytes) ?? Data()
            hasher.update(data: tail)
            return Data(hasher.finalize())
        } catch {
            return nil
        }
    }

    /// Full SHA-256 in hex, or nil when the file can't be read or no longer has the listed size.
    private func fullDigest(of file: Candidate) throws -> String? {
        guard let handle = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk: Data
            do {
                chunk = try autoreleasepool { try handle.read(upToCount: Self.chunkBytes) ?? Data() }
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        guard total == file.bytes else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
