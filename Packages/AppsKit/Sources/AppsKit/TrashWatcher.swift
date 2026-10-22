import CoreServices
import Foundation

/// Watches a Trash folder with FSEvents and reports `.app` bundles that appear in it.
///
/// Events are debounced; after each quiet period the folder's top-level `.app` entries are compared with the ones
/// already seen, so a bundle is reported once per arrival and bundles already in the Trash at `start()` are not
/// reported. `start()` and `stop()` are idempotent and may be called from any thread.
public final class TrashWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (_ appPath: String, _ bundleID: String?, _ name: String) -> Void

    private let core: Core

    public init(trashPath: String, onAppTrashed: @escaping Handler) {
        core = Core(trashPath: trashPath, debounce: 0.75, handler: onAppTrashed)
    }

    /// `debounce` seconds of quiet before the folder is compared.
    public init(trashPath: String, debounce: TimeInterval, onAppTrashed: @escaping Handler) {
        core = Core(trashPath: trashPath, debounce: debounce, handler: onAppTrashed)
    }

    deinit { core.stop() }

    public func start() { core.start() }
    public func stop() { core.stop() }
    public var isRunning: Bool { core.isRunning }

    /// The stream's context retains the core, not the watcher, so the watcher can deinit and stop it.
    final class Core: @unchecked Sendable {
        let trashPath: String
        let debounce: TimeInterval
        let handler: Handler
        let queue = DispatchQueue(label: "keelmac.appskit.trashwatcher")
        private let key = DispatchSpecificKey<Bool>()

        // Guarded by `queue`.
        private var stream: FSEventStreamRef?
        private var known = Set<String>()
        private var pending: DispatchWorkItem?

        init(trashPath: String, debounce: TimeInterval, handler: @escaping Handler) {
            var path = trashPath
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            self.trashPath = path; self.debounce = debounce; self.handler = handler
            queue.setSpecific(key: key, value: true)
        }

        private func onQueue<T>(_ work: () -> T) -> T {
            DispatchQueue.getSpecific(key: key) == true ? work() : queue.sync(execute: work)
        }

        var isRunning: Bool { onQueue { stream != nil } }

        func start() {
            onQueue {
                guard stream == nil else { return }
                known = Set(appNames())
                var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(self).toOpaque(),
                                                   retain: nil, release: nil, copyDescription: nil)
                let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                    guard let info else { return }
                    Unmanaged<Core>.fromOpaque(info).takeUnretainedValue().eventsArrived()
                }
                let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                                   | kFSEventStreamCreateFlagWatchRoot)
                guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                                        [trashPath] as CFArray,
                                                        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                        0.3, flags) else {
                    Unmanaged.passUnretained(self).release()
                    return
                }
                FSEventStreamSetDispatchQueue(created, queue)
                guard FSEventStreamStart(created) else {
                    FSEventStreamInvalidate(created)
                    FSEventStreamRelease(created)
                    Unmanaged.passUnretained(self).release()
                    return
                }
                stream = created
            }
        }

        func stop() {
            onQueue {
                pending?.cancel()
                pending = nil
                guard let stream else { return }
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
                // Balances passRetained in start(). The caller still holds the core, so this never deallocates
                // it while we are running on it.
                Unmanaged.passUnretained(self).release()
            }
        }

        /// Runs on `queue`.
        private func eventsArrived() {
            pending?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.compare() }
            pending = item
            queue.asyncAfter(deadline: .now() + debounce, execute: item)
        }

        /// Runs on `queue`.
        private func compare() {
            pending = nil
            guard stream != nil else { return }
            let current = Set(appNames())
            let arrived = current.subtracting(known).sorted()
            known = current
            for name in arrived {
                let path = trashPath + "/" + name
                let info = BundleReader.read(bundle: path)
                let displayName = info?.displayName ?? info?.bundleName ?? BundleReader.stem(of: path)
                handler(path, info?.bundleID, displayName)
            }
        }

        private func appNames() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: trashPath)) ?? []).filter { $0.hasSuffix(".app") }
        }
    }
}
