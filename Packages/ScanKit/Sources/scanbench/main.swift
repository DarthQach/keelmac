import Darwin
import Foundation
import ScanKit

// Usage: scanbench <root> [--concurrency N] [--buffer KB] [--cache] [--rescan]
// Read-only metadata walk; prints elapsed time, node count and peak RSS.

func peakRSSMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576 // bytes on macOS
}

let args = CommandLine.arguments
var root = "/"
var config = ScanConfiguration()
var doCache = false
var doRescan = false
var doSystemData = false
var i = 1
while i < args.count {
    switch args[i] {
    case "--concurrency": i += 1; config.concurrency = Int(args[i]) ?? config.concurrency
    case "--buffer": i += 1; config.bulkBufferSize = (Int(args[i]) ?? 128) * 1024
    case "--cache": doCache = true
    case "--rescan": doRescan = true
    case "--systemdata": doSystemData = true
    default: root = args[i]
    }
    i += 1
}

if doSystemData {
    let t0 = Date()
    let items = await SystemDataBreakdown.measure(home: NSHomeDirectory())
    for item in items {
        let size = item.bytes.map { String(format: "%.2f GB", Double($0) / 1e9) } ?? "unknown"
        print("\(item.kind.rawValue): \(size) fda=\(item.needsFullDiskAccess) paths=\(item.paths.count)")
    }
    print(String(format: "systemdata elapsed=%.2fs peakRSS=%.1fMB", Date().timeIntervalSince(t0), peakRSSMB()))
    exit(0)
}

let scanner = DiskScanner(configuration: config)
let start = Date()
var tree: ScanTree?
var progressEvents = 0
do {
    for try await event in await scanner.scan(root: root) {
        switch event {
        case .progress: progressEvents += 1
        case .finished(let t): tree = t
        }
    }
} catch {
    print("scan failed: \(error)")
    exit(1)
}
let elapsed = Date().timeIntervalSince(start)
guard let tree else { exit(1) }
let gb = Double(tree.totalBytesOnDisk) / 1e9
print(String(format: "root=%@ scanPath=%@ name=%@", tree.rootPath, tree.scanPath, tree.rootName))
print(String(format: "elapsed=%.2fs nodes=%d files=%d bytes=%.2fGB unreadable=%d progressEvents=%d (%.1f/s) concurrency=%d",
             elapsed, tree.nodeCount, tree.totalFileCount, gb, tree.unreadable.count, progressEvents,
             Double(progressEvents) / max(elapsed, 0.001), config.concurrency))
print(String(format: "peakRSS=%.1fMB", peakRSSMB()))

if doCache {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scanbench-cache.scan")
    let t0 = Date()
    try ScanCache.save(tree, to: url)
    let t1 = Date()
    print(String(format: "peakRSS after save=%.1fMB", peakRSSMB()))
    let loaded = try ScanCache.load(from: url)
    let t2 = Date()
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print(String(format: "cache save=%.3fs load=%.3fs size=%.1fMB nodes=%d", t1.timeIntervalSince(t0), t2.timeIntervalSince(t1),
                 Double(size) / 1_048_576, loaded.nodeCount))
    try? FileManager.default.removeItem(at: url)
    print(String(format: "peakRSS after load (two trees alive)=%.1fMB", peakRSSMB()))
}

if doRescan {
    let r0 = Date()
    var newTree: ScanTree?
    for try await event in await scanner.rescan(tree) {
        if case .finished(let t) = event { newTree = t }
    }
    let summary = await scanner.lastRescan
    print(String(format: "rescan elapsed=%.2fs nodes=%d", Date().timeIntervalSince(r0), newTree?.nodeCount ?? 0),
          summary.map { "mode=\($0.mode) dirsRead=\($0.directoriesRead) changed=\($0.changedDirectories.count)" } ?? "")
    print(String(format: "peakRSS=%.1fMB", peakRSSMB()))
}
