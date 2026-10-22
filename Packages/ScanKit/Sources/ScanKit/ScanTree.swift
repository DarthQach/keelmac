import Foundation

/// A firmlink from the System volume into the Data volume (`/usr/share/firmlinks`).
public struct Firmlink: Sendable, Codable, Hashable {
    /// Path the user sees, e.g. `/Users`.
    public var source: String
    /// Path relative to the Data volume root, e.g. `Users`.
    public var target: String
    public init(source: String, target: String) { self.source = source; self.target = target }
}

/// Compact, index-based result of a scan.
///
/// Nodes are directories plus files at least `largeFileThreshold` bytes. Storage is a set of parallel
/// arrays and a single UTF-8 name table, so ~1M nodes stay well under 100 MB. Every child has a larger
/// index than its parent, which keeps aggregation a single reverse pass.
public struct ScanTree: Sendable {
    public var root: NodeID
    public var scannedAt: Date
    /// Logical root ("/" for the startup disk).
    public var rootPath: String
    /// FSEvents id captured when the scan started (replayed by `DiskScanner.rescan`).
    public var lastEventID: UInt64
    /// Logical paths of folders that could not be read.
    public var unreadable: [String]

    // Additions to the contract.
    /// Real path that was walked (`/System/Volumes/Data` for "/").
    public var scanPath: String
    /// Display name of the root ("Macintosh HD" for the startup disk).
    public var rootName: String
    public var deviceID: Int32
    /// FSEvents database UUID of the device when the scan started.
    public var eventsUUID: String?
    public var largeFileThreshold: Int64
    /// Firmlinks used to present Data-volume paths as `/…` paths (empty unless the root is "/").
    public var firmlinks: [Firmlink]

    // Stored per node.
    var parents: [Int32] = []
    var nameStart: [UInt32] = []
    var nameLength: [UInt16] = []
    var nameBytes: [UInt8] = []
    var flags: [UInt8] = []
    var ownBytes: [Int64] = []
    var ownFiles: [UInt32] = []
    var ownModified: [UInt32] = []

    // Derived by `finalize()`.
    var totalBytes: [Int64] = []
    var totalFiles: [Int64] = []
    var totalModified: [UInt32] = []
    var childOffsets: [Int32] = []
    var childIndex: [Int32] = []

    static let flagDirectory: UInt8 = 1
    static let flagUnreadable: UInt8 = 2

    init(rootPath: String, scanPath: String, rootName: String, deviceID: Int32, lastEventID: UInt64,
         eventsUUID: String?, largeFileThreshold: Int64, firmlinks: [Firmlink], scannedAt: Date = Date()) {
        self.root = NodeID(raw: 0)
        self.scannedAt = scannedAt
        self.rootPath = rootPath
        self.lastEventID = lastEventID
        self.unreadable = []
        self.scanPath = scanPath
        self.rootName = rootName
        self.deviceID = deviceID
        self.eventsUUID = eventsUUID
        self.largeFileThreshold = largeFileThreshold
        self.firmlinks = firmlinks
    }

    /// Empty copy carrying the same metadata (used to rebuild during a rescan).
    func emptyCopy() -> ScanTree {
        ScanTree(rootPath: rootPath, scanPath: scanPath, rootName: rootName, deviceID: deviceID,
                 lastEventID: lastEventID, eventsUUID: eventsUUID, largeFileThreshold: largeFileThreshold,
                 firmlinks: firmlinks, scannedAt: scannedAt)
    }

    // MARK: Building

    @discardableResult
    mutating func appendNode(parent: Int32, name: UnsafeRawBufferPointer, isDirectory: Bool,
                             ownBytes bytes: Int64, ownFiles files: UInt32, ownModified mod: UInt32,
                             flags extra: UInt8 = 0) -> Int32 {
        let index = Int32(parents.count)
        parents.append(parent)
        nameStart.append(UInt32(nameBytes.count))
        let len = min(name.count, Int(UInt16.max))
        nameLength.append(UInt16(len))
        nameBytes.append(contentsOf: UnsafeRawBufferPointer(rebasing: name[0..<len]))
        flags.append((isDirectory ? Self.flagDirectory : 0) | extra)
        ownBytes.append(bytes)
        ownFiles.append(files)
        ownModified.append(mod)
        return index
    }

    @discardableResult
    mutating func appendNode(parent: Int32, name: String, isDirectory: Bool, ownBytes bytes: Int64,
                             ownFiles files: UInt32, ownModified mod: UInt32, flags extra: UInt8 = 0) -> Int32 {
        var name = name
        return name.withUTF8 { buf in
            appendNode(parent: parent, name: UnsafeRawBufferPointer(buf), isDirectory: isDirectory,
                       ownBytes: bytes, ownFiles: files, ownModified: mod, flags: extra)
        }
    }

    /// Copies node `index` of `other` (same name, own stats and flags) under `parent`.
    @discardableResult
    mutating func appendCopy(of index: Int, from other: ScanTree, parent: Int32, keepStats: Bool) -> Int32 {
        let start = Int(other.nameStart[index]), len = Int(other.nameLength[index])
        return other.nameBytes.withUnsafeBytes { raw in
            appendNode(parent: parent, name: UnsafeRawBufferPointer(rebasing: raw[start..<start + len]),
                       isDirectory: other.flags[index] & Self.flagDirectory != 0,
                       ownBytes: keepStats ? other.ownBytes[index] : 0,
                       ownFiles: keepStats ? other.ownFiles[index] : 0,
                       ownModified: keepStats ? other.ownModified[index] : 0,
                       flags: keepStats ? (other.flags[index] & ~Self.flagDirectory) : 0)
        }
    }

    /// Aggregates sizes bottom-up, builds the size-sorted child index and the unreadable list.
    mutating func finalize() {
        let n = parents.count
        totalBytes = ownBytes
        totalFiles = ownFiles.map { Int64($0) }
        totalModified = ownModified
        if n > 1 {
            for i in stride(from: n - 1, through: 1, by: -1) where flags[i] & Self.flagDirectory != 0 {
                let p = Int(parents[i])
                totalBytes[p] &+= totalBytes[i]
                totalFiles[p] &+= totalFiles[i]
                if totalModified[i] > totalModified[p] { totalModified[p] = totalModified[i] }
            }
        }
        // Children (CSR), sorted by size descending.
        var counts = [Int32](repeating: 0, count: n + 1)
        for i in 1..<max(n, 1) { counts[Int(parents[i]) + 1] += 1 }
        for i in 0..<n { counts[i + 1] += counts[i] }
        childOffsets = counts
        var fill = counts
        childIndex = [Int32](repeating: 0, count: max(0, n - 1))
        for i in 1..<max(n, 1) {
            let p = Int(parents[i])
            childIndex[Int(fill[p])] = Int32(i)
            fill[p] += 1
        }
        let bytes = totalBytes
        childIndex.withUnsafeMutableBufferPointer { buf in
            for p in 0..<n {
                let lo = Int(childOffsets[p]), hi = Int(childOffsets[p + 1])
                if hi - lo > 1 {
                    var slice = UnsafeMutableBufferPointer(rebasing: buf[lo..<hi])
                    slice.sort { a, b in
                        let ba = bytes[Int(a)], bb = bytes[Int(b)]
                        return ba != bb ? ba > bb : a < b
                    }
                }
            }
        }
        unreadable = (0..<n).filter { flags[$0] & Self.flagUnreadable != 0 }.map { path(ofIndex: $0) }
    }

    // MARK: Queries

    public var nodeCount: Int { parents.count }
    public var totalBytesOnDisk: Int64 { totalBytes.first ?? 0 }
    public var totalFileCount: Int { Int(totalFiles.first ?? 0) }

    public func info(_ id: NodeID) -> ScanNodeInfo {
        let i = id.index
        let dir = flags[i] & Self.flagDirectory != 0
        return ScanNodeInfo(id: id, name: name(ofIndex: i), path: path(ofIndex: i), isDirectory: dir,
                            bytes: totalBytes[i], fileCount: dir ? Int(totalFiles[i]) : 1,
                            modified: Date(timeIntervalSince1970: TimeInterval(totalModified[i])),
                            isUnreadable: flags[i] & Self.flagUnreadable != 0)
    }

    /// Directories and large files under `id`, largest first.
    public func children(of id: NodeID) -> [NodeID] {
        let lo = Int(childOffsets[id.index]), hi = Int(childOffsets[id.index + 1])
        return childIndex[lo..<hi].map { NodeID(raw: $0) }
    }

    public func childCount(of id: NodeID) -> Int {
        Int(childOffsets[id.index + 1] - childOffsets[id.index])
    }

    public func parent(of id: NodeID) -> NodeID? {
        let p = parents[id.index]
        return p < 0 ? nil : NodeID(raw: p)
    }

    /// Root first, excluding `id` itself.
    public func ancestors(of id: NodeID) -> [NodeID] {
        var out: [NodeID] = []
        var p = parents[id.index]
        while p >= 0 { out.append(NodeID(raw: p)); p = parents[Int(p)] }
        return out.reversed()
    }

    public func name(of id: NodeID) -> String { name(ofIndex: id.index) }
    public func bytes(of id: NodeID) -> Int64 { totalBytes[id.index] }
    public func fileCount(of id: NodeID) -> Int { flags[id.index] & Self.flagDirectory != 0 ? Int(totalFiles[id.index]) : 1 }
    public func isDirectory(_ id: NodeID) -> Bool { flags[id.index] & Self.flagDirectory != 0 }
    public func path(of id: NodeID) -> String { path(ofIndex: id.index) }

    /// Bytes of a folder's files that are not large-file nodes (the "other files" tile of a treemap).
    public func smallFilesBytes(of id: NodeID) -> Int64 {
        guard isDirectory(id) else { return 0 }
        return totalBytes[id.index] - children(of: id).reduce(0) { $0 + totalBytes[$1.index] }
    }

    /// Every large-file node (files at least `largeFileThreshold` bytes).
    public var largeFileNodes: [NodeID] {
        (0..<parents.count).lazy.filter { flags[$0] & Self.flagDirectory == 0 }.map { NodeID(raw: Int32($0)) }
    }

    /// Finds a node by logical path (`/Users/me/x`) or real path (`/System/Volumes/Data/Users/me/x`).
    public func lookup(path: String) -> NodeID? {
        guard let rel = relativePath(for: path) else { return nil }
        return lookup(relative: rel)
    }

    /// Nearest node that exists for `path`: the node itself, or its closest ancestor in the tree.
    func nearestNode(for path: String) -> NodeID? {
        guard var rel = relativePath(for: path) else { return nil }
        while true {
            if let id = lookup(relative: rel) { return id }
            if rel.isEmpty { return nil }
            if let slash = rel.lastIndex(of: "/") { rel = String(rel[..<slash]) } else { rel = "" }
        }
    }

    func lookup(relative rel: String) -> NodeID? {
        if rel.isEmpty { return parents.isEmpty ? nil : root }
        var cur = 0
        for comp in rel.split(separator: "/", omittingEmptySubsequences: true) {
            guard let next = child(ofIndex: cur, named: String(comp)) else { return nil }
            cur = next
        }
        return NodeID(raw: Int32(cur))
    }

    // MARK: Internals

    func name(ofIndex i: Int) -> String {
        if i == 0 { return rootName }
        let start = Int(nameStart[i]), len = Int(nameLength[i])
        return nameBytes.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[start..<start + len]), as: UTF8.self) }
    }

    func rawNameEquals(_ i: Int, _ bytes: UnsafeRawBufferPointer) -> Bool {
        let len = Int(nameLength[i])
        guard len == bytes.count else { return false }
        let start = Int(nameStart[i])
        return nameBytes.withUnsafeBytes { raw in
            memcmp(raw.baseAddress! + start, bytes.baseAddress!, len) == 0
        }
    }

    func rawName(_ i: Int) -> [UInt8] {
        let start = Int(nameStart[i]), len = Int(nameLength[i])
        return Array(nameBytes[start..<start + len])
    }

    func child(ofIndex p: Int, named name: String) -> Int? {
        let lo = Int(childOffsets[p]), hi = Int(childOffsets[p + 1])
        var utf8 = name
        let exact: Int? = utf8.withUTF8 { buf -> Int? in
            for k in lo..<hi where rawNameEquals(Int(childIndex[k]), UnsafeRawBufferPointer(buf)) { return Int(childIndex[k]) }
            return nil
        }
        if let exact { return exact }
        // APFS is normalization-insensitive and usually case-insensitive.
        for k in lo..<hi {
            let c = Int(childIndex[k])
            let other = self.name(ofIndex: c)
            if other == name || other.compare(name, options: [.caseInsensitive]) == .orderedSame { return c }
        }
        return nil
    }

    /// Path components below the root.
    func relativeComponents(ofIndex i: Int) -> [String] {
        var comps: [String] = []
        var cur = i
        while cur > 0 { comps.append(name(ofIndex: cur)); cur = Int(parents[cur]) }
        return comps.reversed()
    }

    func relativePathString(ofIndex i: Int) -> String { relativeComponents(ofIndex: i).joined(separator: "/") }

    /// Logical path of node `i`.
    func path(ofIndex i: Int) -> String {
        let rel = relativePathString(ofIndex: i)
        return logicalPath(forRelative: rel)
    }

    /// Real (walkable) path of node `i`.
    func realPath(ofIndex i: Int) -> String {
        Self.join(scanPath, relativePathString(ofIndex: i))
    }

    func logicalPath(forRelative rel: String) -> String {
        if rel.isEmpty { return rootPath }
        if !firmlinks.isEmpty {
            var best: Firmlink?
            for f in firmlinks where rel == f.target || rel.hasPrefix(f.target + "/") {
                if best == nil || f.target.count > best!.target.count { best = f }
            }
            if let best { return best.source + rel.dropFirst(best.target.count) }
            return Self.join(scanPath, rel)
        }
        return Self.join(rootPath, rel)
    }

    /// Logical path for a real path produced while walking.
    func logicalPath(forReal real: String) -> String {
        guard let rel = relativePath(for: real) else { return real }
        return logicalPath(forRelative: rel)
    }

    /// Relative path below the root for a logical or real path; nil when the path is outside the tree.
    func relativePath(for rawPath: String) -> String? {
        let path = Self.normalize(rawPath)
        func strip(_ prefix: String) -> String? {
            if path == prefix { return "" }
            let p = prefix == "/" ? "/" : prefix + "/"
            return path.hasPrefix(p) ? String(path.dropFirst(p.count)) : nil
        }
        if let r = strip(scanPath) { return r }
        if !firmlinks.isEmpty {
            if path == rootPath { return "" }
            var best: Firmlink?
            for f in firmlinks where path == f.source || path.hasPrefix(f.source + "/") {
                if best == nil || f.source.count > best!.source.count { best = f }
            }
            if let best { return best.target + path.dropFirst(best.source.count) }
            return nil
        }
        if let r = strip(rootPath) { return r }
        return nil
    }

    static func join(_ base: String, _ rel: String) -> String {
        if rel.isEmpty { return base }
        return base == "/" ? "/" + rel : base + "/" + rel
    }

    static func normalize(_ path: String) -> String {
        var p = path
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

// MARK: - Codable (arrays packed as raw data so a 300k-node cache saves and loads in milliseconds)

extension ScanTree: Codable {
    static let formatVersion = 1

    enum CodingKeys: String, CodingKey {
        case version, root, scannedAt, rootPath, lastEventID, unreadable, scanPath, rootName, deviceID, eventsUUID
        case largeFileThreshold, firmlinks
        case parents, nameStart, nameLength, nameBytes, flags, ownBytes, ownFiles, ownModified
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported scan cache version \(version)")
        }
        root = try c.decode(NodeID.self, forKey: .root)
        scannedAt = try c.decode(Date.self, forKey: .scannedAt)
        rootPath = try c.decode(String.self, forKey: .rootPath)
        lastEventID = try c.decode(UInt64.self, forKey: .lastEventID)
        unreadable = try c.decode([String].self, forKey: .unreadable)
        scanPath = try c.decode(String.self, forKey: .scanPath)
        rootName = try c.decode(String.self, forKey: .rootName)
        deviceID = try c.decode(Int32.self, forKey: .deviceID)
        eventsUUID = try c.decodeIfPresent(String.self, forKey: .eventsUUID)
        largeFileThreshold = try c.decode(Int64.self, forKey: .largeFileThreshold)
        firmlinks = try c.decode([Firmlink].self, forKey: .firmlinks)
        parents = try Self.unpack(c.decode(Data.self, forKey: .parents))
        nameStart = try Self.unpack(c.decode(Data.self, forKey: .nameStart))
        nameLength = try Self.unpack(c.decode(Data.self, forKey: .nameLength))
        nameBytes = try Self.unpack(c.decode(Data.self, forKey: .nameBytes))
        flags = try Self.unpack(c.decode(Data.self, forKey: .flags))
        ownBytes = try Self.unpack(c.decode(Data.self, forKey: .ownBytes))
        ownFiles = try Self.unpack(c.decode(Data.self, forKey: .ownFiles))
        ownModified = try Self.unpack(c.decode(Data.self, forKey: .ownModified))
        try validateAndFinalize()
    }

    /// Checks loaded arrays for consistency, then rebuilds the derived arrays (keeping `unreadable`).
    mutating func validateAndFinalize() throws {
        let n = parents.count
        guard n > 0, [nameStart.count, nameLength.count, flags.count, ownBytes.count, ownFiles.count, ownModified.count].allSatisfy({ $0 == n }),
              parents[0] == -1,
              (1..<n).allSatisfy({ parents[$0] >= 0 && Int(parents[$0]) < $0 }),
              (0..<n).allSatisfy({ Int(nameStart[$0]) + Int(nameLength[$0]) <= nameBytes.count })
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Inconsistent scan cache"))
        }
        let savedUnreadable = unreadable
        finalize()
        unreadable = savedUnreadable
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .version)
        try c.encode(root, forKey: .root)
        try c.encode(scannedAt, forKey: .scannedAt)
        try c.encode(rootPath, forKey: .rootPath)
        try c.encode(lastEventID, forKey: .lastEventID)
        try c.encode(unreadable, forKey: .unreadable)
        try c.encode(scanPath, forKey: .scanPath)
        try c.encode(rootName, forKey: .rootName)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encodeIfPresent(eventsUUID, forKey: .eventsUUID)
        try c.encode(largeFileThreshold, forKey: .largeFileThreshold)
        try c.encode(firmlinks, forKey: .firmlinks)
        try c.encode(Self.pack(parents), forKey: .parents)
        try c.encode(Self.pack(nameStart), forKey: .nameStart)
        try c.encode(Self.pack(nameLength), forKey: .nameLength)
        try c.encode(Self.pack(nameBytes), forKey: .nameBytes)
        try c.encode(Self.pack(flags), forKey: .flags)
        try c.encode(Self.pack(ownBytes), forKey: .ownBytes)
        try c.encode(Self.pack(ownFiles), forKey: .ownFiles)
        try c.encode(Self.pack(ownModified), forKey: .ownModified)
    }

    static func pack<T: FixedWidthInteger>(_ array: [T]) -> Data {
        #if _endian(little)
        return array.withUnsafeBufferPointer { Data(buffer: $0) }
        #else
        return array.map { $0.littleEndian }.withUnsafeBufferPointer { Data(buffer: $0) }
        #endif
    }

    static func unpack<T: FixedWidthInteger>(_ data: Data) throws -> [T] {
        let size = MemoryLayout<T>.size
        guard data.count % size == 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Bad packed array length"))
        }
        var out = [T](repeating: 0, count: data.count / size)
        out.withUnsafeMutableBytes { dst in _ = data.copyBytes(to: dst) }
        #if _endian(big)
        out = out.map { T(littleEndian: $0) }
        #endif
        return out
    }
}
