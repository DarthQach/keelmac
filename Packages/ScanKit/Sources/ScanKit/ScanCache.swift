import Darwin
import Foundation

/// Saves and loads a `ScanTree`.
///
/// Format: `KSC1` magic, a little-endian UInt32 header length, a JSON header with the tree's metadata, then
/// the node arrays as raw little-endian bytes. Arrays are written straight from their buffers and read with
/// one copy each, so a ~1M-node tree saves in ~0.1 s without doubling memory. `load` also accepts a
/// property list or JSON produced by `ScanTree`'s `Codable` conformance.
public enum ScanCache {
    static let magic: [UInt8] = Array("KSC1".utf8)

    struct Header: Codable {
        var version: Int
        var root: NodeID
        var scannedAt: Date
        var rootPath: String
        var lastEventID: UInt64
        var unreadable: [String]
        var scanPath: String
        var rootName: String
        var deviceID: Int32
        var eventsUUID: String?
        var largeFileThreshold: Int64
        var firmlinks: [Firmlink]
        var nodeCount: Int
        var nameByteCount: Int
    }

    public static func save(_ tree: ScanTree, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = Header(version: ScanTree.formatVersion, root: tree.root, scannedAt: tree.scannedAt, rootPath: tree.rootPath,
                            lastEventID: tree.lastEventID, unreadable: tree.unreadable, scanPath: tree.scanPath,
                            rootName: tree.rootName, deviceID: tree.deviceID, eventsUUID: tree.eventsUUID,
                            largeFileThreshold: tree.largeFileThreshold, firmlinks: tree.firmlinks,
                            nodeCount: tree.nodeCount, nameByteCount: tree.nameBytes.count)
        let headerData = try JSONEncoder().encode(header)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            var prefix = Data(magic)
            withUnsafeBytes(of: UInt32(headerData.count).littleEndian) { prefix.append(contentsOf: $0) }
            try handle.write(contentsOf: prefix)
            try handle.write(contentsOf: headerData)
            try write(tree.parents, to: handle)
            try write(tree.nameStart, to: handle)
            try write(tree.nameLength, to: handle)
            try write(tree.flags, to: handle)
            try write(tree.ownBytes, to: handle)
            try write(tree.ownFiles, to: handle)
            try write(tree.ownModified, to: handle)
            try write(tree.nameBytes, to: handle)
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    public static func load(from url: URL) throws -> ScanTree {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 8, Array(data.prefix(4)) == magic else {
            // Codable fallbacks.
            if let tree = try? PropertyListDecoder().decode(ScanTree.self, from: data) { return tree }
            return try JSONDecoder().decode(ScanTree.self, from: data)
        }
        let headerLength = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) })
        guard 8 + headerLength <= data.count else { throw corrupt("truncated header") }
        let header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 8..<8 + headerLength))
        guard header.version == ScanTree.formatVersion else { throw corrupt("unsupported version \(header.version)") }
        guard header.nodeCount > 0, header.nameByteCount >= 0 else { throw corrupt("bad counts") }

        var tree = ScanTree(rootPath: header.rootPath, scanPath: header.scanPath, rootName: header.rootName,
                            deviceID: header.deviceID, lastEventID: header.lastEventID, eventsUUID: header.eventsUUID,
                            largeFileThreshold: header.largeFileThreshold, firmlinks: header.firmlinks, scannedAt: header.scannedAt)
        tree.root = header.root
        tree.unreadable = header.unreadable
        var offset = 8 + headerLength
        let n = header.nodeCount
        try data.withUnsafeBytes { raw in
            func read<T: FixedWidthInteger>(_ count: Int) throws -> [T] {
                let bytes = count * MemoryLayout<T>.size
                guard offset + bytes <= raw.count else { throw corrupt("truncated arrays") }
                var out = [T](repeating: 0, count: count)
                out.withUnsafeMutableBytes { dst in dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + bytes])) }
                offset += bytes
                #if _endian(big)
                out = out.map { T(littleEndian: $0) }
                #endif
                return out
            }
            tree.parents = try read(n)
            tree.nameStart = try read(n)
            tree.nameLength = try read(n)
            tree.flags = try read(n)
            tree.ownBytes = try read(n)
            tree.ownFiles = try read(n)
            tree.ownModified = try read(n)
            tree.nameBytes = try read(header.nameByteCount)
        }
        guard offset == data.count else { throw corrupt("trailing bytes") }
        try tree.validateAndFinalize()
        return tree
    }

    /// Default location: `~/Library/Application Support/<bundle id or KeelMac>/ScanCache/<root hash>.scan`.
    public static func defaultURL(forRoot root: String, appSupport: URL? = nil) -> URL {
        let base = appSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "KeelMac", isDirectory: true)
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a, stable across launches
        for b in root.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return base.appendingPathComponent("ScanCache", isDirectory: true)
            .appendingPathComponent(String(format: "%016llx.scan", hash))
    }

    private static func write<T: FixedWidthInteger>(_ array: [T], to handle: FileHandle) throws {
        #if _endian(big)
        let array = array.map { $0.littleEndian }
        #endif
        try array.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            // Chunked so the kernel never needs one huge contiguous write.
            let chunk = 8 << 20
            var start = 0
            while start < raw.count {
                let len = min(chunk, raw.count - start)
                try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: len, deallocator: .none))
                start += len
            }
        }
    }

    private static func corrupt(_ why: String) -> Error {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Scan cache: \(why)"))
    }
}
