import Foundation
import Testing
@testable import AppsKit

final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, String?, String)] = []
    func add(_ item: (String, String?, String)) { lock.withLock { items.append(item) } }
    var all: [(String, String?, String)] { lock.withLock { items } }
}

@Suite(.serialized) struct TrashWatcherTests {
    func waitFor(_ condition: @escaping @Sendable () -> Bool, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    @Test func reportsAnAppMovedIntoTheFolder() async throws {
        let fx = Fixture()
        let trash = fx.dir("Trash")
        fx.app("Trash/AlreadyThere.app", bundleID: "com.old.app", name: "Old")
        let source = fx.app("Applications/Fresh.app", bundleID: "com.fresh.app", name: "FreshName", displayName: "Fresh")
        fx.file("Applications/notes.txt")

        let reports = Reports()
        let watcher = TrashWatcher(trashPath: trash, debounce: 0.2) { path, bid, name in reports.add((path, bid, name)) }
        watcher.start()
        watcher.start()                                  // idempotent
        #expect(watcher.isRunning)
        try await Task.sleep(nanoseconds: 300_000_000)   // let the stream settle

        try FileManager.default.moveItem(atPath: source, toPath: trash + "/Fresh.app")
        try FileManager.default.moveItem(atPath: fx.path("Applications/notes.txt"), toPath: trash + "/notes.txt")

        #expect(await waitFor { !reports.all.isEmpty })
        try await Task.sleep(nanoseconds: 600_000_000)   // nothing else should arrive
        let all = reports.all
        #expect(all.count == 1)
        #expect(all.first?.0 == trash + "/Fresh.app")
        #expect(all.first?.1 == "com.fresh.app")
        #expect(all.first?.2 == "Fresh")

        watcher.stop()
        watcher.stop()                                   // idempotent
        #expect(!watcher.isRunning)

        // Stopped: further arrivals are not reported.
        let another = fx.app("Applications/Later.app", bundleID: "com.later.app", name: "Later")
        try FileManager.default.moveItem(atPath: another, toPath: trash + "/Later.app")
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(reports.all.count == 1)
    }

    @Test func restartsAndDeinitsCleanly() async throws {
        let fx = Fixture()
        let trash = fx.dir("Trash")
        let reports = Reports()
        var watcher: TrashWatcher? = TrashWatcher(trashPath: trash, debounce: 0.1) { p, b, n in reports.add((p, b, n)) }
        watcher?.start(); watcher?.stop(); watcher?.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        let source = fx.app("Applications/Again.app", bundleID: "com.again.app", name: "Again")
        try FileManager.default.moveItem(atPath: source, toPath: trash + "/Again.app")
        #expect(await waitFor { reports.all.count == 1 })
        watcher = nil                                    // deinit stops the stream
        #expect(watcher == nil)
    }
}
