import Darwin
import Foundation

/// One child worth keeping as a node: a subdirectory or a large file.
struct ChildEntry: Sendable {
    var nameStart: UInt32
    var nameLength: UInt16
    var isDirectory: Bool
    var bytes: Int64
    var modified: UInt32
}

/// What one `getattrlistbulk` pass over a folder found.
struct DirListing: Sendable {
    var errorCode: Int32 = 0
    var cancelled = false
    var otherDevice = false
    /// Allocated bytes of the folder's own (non-directory) entries, hard links counted once.
    var ownBytes: Int64 = 0
    var ownFiles: UInt32 = 0
    /// Newest modification among the folder's entries.
    var maxModified: UInt32 = 0
    var names: [UInt8] = []
    var entries: [ChildEntry] = []

    func withName<R>(_ e: ChildEntry, _ body: (UnsafeRawBufferPointer) -> R) -> R {
        names.withUnsafeBytes { raw in
            body(UnsafeRawBufferPointer(rebasing: raw[Int(e.nameStart)..<Int(e.nameStart) + Int(e.nameLength)]))
        }
    }

    func name(_ e: ChildEntry) -> String {
        withName(e) { String(decoding: $0, as: UTF8.self) }
    }
}

/// File ids of files with more than one link, so each is counted once per scan.
final class HardLinkSet: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<UInt64>()

    /// True the first time `fileID` is seen.
    func insert(_ fileID: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert(fileID).inserted
    }
}

/// Reusable aligned buffers for `getattrlistbulk` (avoids an mmap/munmap per folder).
final class BufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private var free: [UnsafeMutableRawPointer] = []
    let size: Int

    init(size: Int) { self.size = size }

    deinit { for b in free { b.deallocate() } }

    func take() -> UnsafeMutableRawPointer {
        lock.lock()
        if let b = free.popLast() { lock.unlock(); return b }
        lock.unlock()
        return UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    }

    func give(_ b: UnsafeMutableRawPointer) {
        lock.lock(); free.append(b); lock.unlock()
    }
}

enum BulkReader {
    static let commonAttrs: attrgroup_t = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
        | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FILEID)
    static let dirAttrs: attrgroup_t = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
    static let fileAttrs: attrgroup_t = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)

    /// Lists `path` with `getattrlistbulk`. Never follows symlinks; skips mount points, autofs triggers
    /// and entries on another device.
    static func read(path: String, device: Int32, largeFileThreshold: Int64, hardLinks: HardLinkSet,
                     pool: BufferPool, isCancelled: () -> Bool) -> DirListing {
        var listing = DirListing()
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            listing.errorCode = errno
            return listing
        }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) == 0, st.st_dev != device {
            listing.otherDevice = true
            return listing
        }

        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = commonAttrs
        attrs.dirattr = dirAttrs
        attrs.fileattr = fileAttrs

        let buffer = pool.take()
        defer { pool.give(buffer) }
        let bufferSize = pool.size

        let vdir = UInt32(VDIR.rawValue)
        while true {
            if isCancelled() { listing.cancelled = true; break }
            let count = getattrlistbulk(fd, &attrs, buffer, bufferSize, 0)
            if count < 0 {
                if errno == EINTR { continue }
                listing.errorCode = errno
                break
            }
            if count == 0 { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var f = entry + 4
                let returned = f.loadUnaligned(as: attribute_set_t.self)
                f += MemoryLayout<attribute_set_t>.size
                var entryError: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    entryError = f.loadUnaligned(as: UInt32.self); f += 4
                }
                var namePtr: UnsafeRawPointer?
                var nameLen = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let ref = f.loadUnaligned(as: attrreference_t.self)
                    namePtr = f + Int(ref.attr_dataoffset)
                    nameLen = max(0, Int(ref.attr_length) - 1) // drop the NUL
                    f += MemoryLayout<attrreference_t>.size
                }
                if entryError != 0 { continue }
                var devid: Int32 = device
                if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
                    devid = f.loadUnaligned(as: Int32.self); f += 4
                }
                var objType: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    objType = f.loadUnaligned(as: UInt32.self); f += 4
                }
                var mtime: Int = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    mtime = f.loadUnaligned(as: Int.self)
                    f += MemoryLayout<timespec>.size
                }
                var fileID: UInt64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    fileID = f.loadUnaligned(as: UInt64.self); f += 8
                }
                let modified = UInt32(clamping: max(0, mtime))
                if devid != device { continue }

                if objType == vdir {
                    var mountStatus: UInt32 = 0
                    if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
                        mountStatus = f.loadUnaligned(as: UInt32.self); f += 4
                    }
                    if mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0 { continue }
                    if modified > listing.maxModified { listing.maxModified = modified }
                    guard let namePtr, nameLen > 0 else { continue }
                    listing.entries.append(ChildEntry(nameStart: UInt32(listing.names.count), nameLength: UInt16(nameLen),
                                                      isDirectory: true, bytes: 0, modified: modified))
                    listing.names.append(contentsOf: UnsafeRawBufferPointer(start: namePtr, count: nameLen))
                } else {
                    var linkCount: UInt32 = 1
                    if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                        linkCount = f.loadUnaligned(as: UInt32.self); f += 4
                    }
                    var alloc: Int64 = 0
                    if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                        alloc = f.loadUnaligned(as: Int64.self); f += 8
                    }
                    if linkCount > 1, fileID != 0, !hardLinks.insert(fileID) { continue }
                    listing.ownBytes &+= alloc
                    listing.ownFiles &+= 1
                    if modified > listing.maxModified { listing.maxModified = modified }
                    if alloc >= largeFileThreshold, let namePtr, nameLen > 0 {
                        listing.entries.append(ChildEntry(nameStart: UInt32(listing.names.count), nameLength: UInt16(nameLen),
                                                          isDirectory: false, bytes: alloc, modified: modified))
                        listing.names.append(contentsOf: UnsafeRawBufferPointer(start: namePtr, count: nameLen))
                    }
                }
            }
        }
        return listing
    }
}
