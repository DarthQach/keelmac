import CoreServices
import Foundation

/// Replays FSEvents history for a path since a stored event id.
enum FSEventsReplay {
    struct Result: Sendable {
        var paths: [String] = []
        /// Set when a full scan is needed.
        var fullScanReason: RescanSummary.FullScanReason?
    }

    static func currentEventID() -> UInt64 { FSEventsGetCurrentEventId() }

    static func uuid(forDevice dev: dev_t) -> String? {
        guard let uuid = FSEventsCopyUUIDForDevice(dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var paths = Set<String>()
        var reason: RescanSummary.FullScanReason?
        var continuation: CheckedContinuation<Void, Never>?
        var done = false

        func finish(_ reason: RescanSummary.FullScanReason? = nil) {
            lock.lock()
            if let reason, self.reason == nil { self.reason = reason }
            let c = done ? nil : continuation
            done = true
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    private struct StreamBox: @unchecked Sendable { let stream: FSEventStreamRef }

    /// Collects the directories changed under `path` since `eventID`, stopping at HistoryDone.
    static func replay(path: String, since eventID: UInt64, timeout: TimeInterval = 20) async -> Result {
        let collector = Collector()
        let queue = DispatchQueue(label: "ScanKit.FSEventsReplay")
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            let cPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var historyDone = false
            var reason: RescanSummary.FullScanReason?
            collector.lock.lock()
            for i in 0..<count {
                let flags = Int(eventFlags[i])
                if flags & kFSEventStreamEventFlagHistoryDone != 0 { historyDone = true; continue }
                if flags & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                            | kFSEventStreamEventFlagKernelDropped) != 0 { reason = reason ?? .mustScanSubDirs }
                if flags & (kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                    reason = .rootChanged
                }
                if flags & (kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 { continue }
                collector.paths.insert(String(cString: cPaths[i]))
            }
            collector.lock.unlock()
            if let reason { collector.finish(reason) } else if historyDone { collector.finish() }
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(eventID), 0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else {
            return Result(fullScanReason: .historyUnavailable)
        }
        let box = StreamBox(stream: stream)
        FSEventStreamSetDispatchQueue(stream, queue)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            collector.lock.lock()
            collector.continuation = c
            collector.lock.unlock()
            if !FSEventStreamStart(box.stream) {
                collector.finish(.historyUnavailable)
                return
            }
            queue.asyncAfter(deadline: .now() + timeout) { collector.finish(.historyUnavailable) }
        }
        queue.sync {
            FSEventStreamStop(box.stream)
            FSEventStreamInvalidate(box.stream)
            FSEventStreamRelease(box.stream)
        }
        collector.lock.lock(); defer { collector.lock.unlock() }
        var result = Result()
        result.fullScanReason = collector.reason
        result.paths = collector.paths.map { ScanTree.normalize($0) }.sorted()
        return result
    }
}
