import Foundation
import HelperShared
import ServiceManagement

/// Registration state of the helper daemon, from `SMAppService.Status`.
public enum HelperStatus: Sendable, Equatable {
    case notRegistered
    /// Registered, waiting for the user in System Settings › General › Login Items & Extensions › Allow in the Background.
    case requiresApproval
    case enabled
    /// The plist isn't in the app bundle (a build problem) or the app isn't running from a bundle.
    case notFound
    case unavailable(String)

    public init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .unavailable("SMAppService.Status(\(status.rawValue))")
        }
    }
}

public enum HelperClientError: Error, Sendable, Equatable {
    /// The connection failed or was invalidated (includes a helper that fails the code-signing requirement).
    case connectionFailed(String)
    case timedOut
    /// The installed helper speaks another protocol version (the app should re-register it).
    case versionMismatch(expected: Int, actual: Int)
    case badResponse
}

/// Anything that can perform helper operations (the real `HelperClient`, or a fake in tests).
public protocol HelperPerforming: Sendable {
    func perform(_ op: HelperOperation) async throws -> HelperResponse
}

/// The app's side of the helper: `SMAppService` registration plus the privileged XPC connection.
public final class HelperClient: HelperPerforming, @unchecked Sendable {
    public static let plistName = HelperIdentity.launchdPlistName

    private let lock = NSLock()
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let requirement: String?
    private var connection: NSXPCConnection?
    private var generation = 0
    private var verifiedGeneration = -1

    /// Seconds allowed for the version handshake and added to each operation's own timeout.
    public var handshakeTimeout: TimeInterval = 10

    /// Connects to the installed helper over its Mach service, requiring it to be signed by our team.
    public convenience init() {
        self.init(connectionFactory: { NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged) },
                  requirement: CodeSigningRequirement.helper())
    }

    /// For tests: any connection (for example to an anonymous in-process listener) and an optional requirement.
    public init(connectionFactory: @escaping @Sendable () -> NSXPCConnection, requirement: String?) {
        self.makeConnection = connectionFactory
        self.requirement = requirement
    }

    deinit { connection?.invalidate() }

    // MARK: - Registration (SMAppService)

    private var service: SMAppService { SMAppService.daemon(plistName: Self.plistName) }

    public var status: HelperStatus { HelperStatus(service.status) }

    /// Registers the daemon. When macOS needs the user's approval it may throw; that isn't a failure
    /// here: the status becomes `.requiresApproval` and the app shows "Open Login Items".
    public func register() throws {
        do {
            try service.register()
        } catch {
            if service.status == .requiresApproval { return }
            throw error
        }
    }

    public func unregister() async throws {
        invalidate()
        try await service.unregister()
    }

    /// Opens System Settings › General › Login Items & Extensions.
    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - XPC

    /// Drops the current connection; the next call opens a new one.
    public func invalidate() {
        let old: NSXPCConnection? = lock.withLock {
            let c = connection
            connection = nil
            return c
        }
        old?.invalidate()
    }

    /// The helper's protocol version.
    public func remoteProtocolVersion() async throws -> Int {
        let (connection, _) = currentConnection()
        return try await call(on: connection, timeout: handshakeTimeout) { proxy, done in
            proxy.protocolVersion { done(.success($0)) }
        }
    }

    public func perform(_ op: HelperOperation) async throws -> HelperResponse {
        try await perform(op, timeout: op.timeout + handshakeTimeout)
    }

    public func perform(_ op: HelperOperation, timeout: TimeInterval) async throws -> HelperResponse {
        let (connection, gen) = currentConnection()
        if lock.withLock({ verifiedGeneration != gen }) {
            let version: Int = try await call(on: connection, timeout: handshakeTimeout) { proxy, done in
                proxy.protocolVersion { done(.success($0)) }
            }
            guard version == helperProtocolVersion else {
                throw HelperClientError.versionMismatch(expected: helperProtocolVersion, actual: version)
            }
            lock.withLock { if generation == gen { verifiedGeneration = gen } }
        }
        let request = HelperCoding.encode(HelperRequest(operation: op))
        let data: Data = try await call(on: connection, timeout: timeout) { proxy, done in
            proxy.perform(request) { done(.success($0)) }
        }
        guard let response = HelperCoding.decode(HelperResponse.self, from: data) else { throw HelperClientError.badResponse }
        return response
    }

    private func currentConnection() -> (NSXPCConnection, Int) {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return (connection, generation) }
        generation += 1
        let gen = generation
        let c = makeConnection()
        c.remoteObjectInterface = .keelMacHelper()
        if let requirement { c.setCodeSigningRequirement(requirement) }
        c.invalidationHandler = { [weak self] in self?.connectionEnded(generation: gen) }
        c.interruptionHandler = { [weak self] in self?.connectionInterrupted(generation: gen) }
        c.resume()
        connection = c
        return (c, gen)
    }

    private func connectionEnded(generation gen: Int) {
        lock.withLock { if generation == gen { connection = nil } }
    }

    private func connectionInterrupted(generation gen: Int) {
        // The helper exited (launchd restarts it on demand); re-check its version on the next call.
        lock.withLock { if generation == gen { verifiedGeneration = -1 } }
    }

    private func call<T: Sendable>(on connection: NSXPCConnection, timeout: TimeInterval,
                                   _ body: (KeelMacHelperProtocol, @escaping @Sendable (Result<T, HelperClientError>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = ResumeOnce(continuation)
            let raw = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(HelperClientError.connectionFailed((error as NSError).localizedDescription)))
            }
            guard let proxy = raw as? KeelMacHelperProtocol else {
                once.resume(.failure(HelperClientError.connectionFailed("No remote proxy")))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(.failure(HelperClientError.timedOut))
            }
            body(proxy) { result in once.resume(result.mapError { $0 as Error }) }
        }
    }
}

/// Resumes a continuation exactly once (reply, error handler and timeout race).
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        let c: CheckedContinuation<T, Error>? = lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
        c?.resume(with: result)
    }
}
