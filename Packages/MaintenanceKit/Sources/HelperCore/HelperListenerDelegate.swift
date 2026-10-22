import Foundation
import HelperShared
import SafetyKit

/// Accepts XPC connections for the helper. Each new connection gets the code-signing requirement
/// (so a peer that isn't the KeelMac app signed by our team is cut off on its first message), the
/// `KeelMacHelperProtocol` interface, and an executor bound to the connecting user's uid.
public final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public let executor: HelperExecutor
    /// The csreq string a client must satisfy. `nil` only in tests (anonymous in-process listeners).
    public let requirement: String?
    /// Turns the base executor into the one used for a connection, given the client's effective uid.
    public let bindExecutor: @Sendable (HelperExecutor, UInt32) -> HelperExecutor

    /// - Parameters:
    ///   - executor: the base executor (its runner is shared by every connection).
    ///   - requirement: `CodeSigningRequirement.client()` in production.
    ///   - bindExecutor: defaults to `HelperListenerDelegate.bindToClient`, which builds a `.helper` remover
    ///     moving into the client's `~/.Trash/KeelMac`.
    public init(executor: HelperExecutor, requirement: String?,
                bindExecutor: @escaping @Sendable (HelperExecutor, UInt32) -> HelperExecutor = HelperListenerDelegate.bindToClient) {
        self.executor = executor
        self.requirement = requirement
        self.bindExecutor = bindExecutor
    }

    /// The configuration the KeelMacHelper daemon uses.
    public static func production() -> HelperListenerDelegate {
        HelperListenerDelegate(
            executor: HelperExecutor.forClient(uid: 0),
            requirement: CodeSigningRequirement.client()
        )
    }

    @Sendable public static func bindToClient(_ base: HelperExecutor, uid: UInt32) -> HelperExecutor {
        var bound = HelperExecutor.forClient(uid: uid, runner: base.runner, whitelist: base.remover.pathGuard.whitelist)
        bound.plistLabelReader = base.plistLabelReader
        bound.maxOutputBytes = base.maxOutputBytes
        return bound
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        if let requirement {
            // An invalid requirement would accept or crash unpredictably; refuse everyone instead.
            guard CodeSigningRequirement.isValid(requirement) else { return false }
            newConnection.setCodeSigningRequirement(requirement)
        }
        let uid = UInt32(bitPattern: Int32(truncatingIfNeeded: newConnection.effectiveUserIdentifier))
        newConnection.exportedInterface = .keelMacHelper()
        newConnection.exportedObject = HelperService(executor: bindExecutor(executor, uid))
        newConnection.resume()
        return true
    }
}

/// The object exported on each connection.
final class HelperService: NSObject, KeelMacHelperProtocol, @unchecked Sendable {
    let executor: HelperExecutor

    init(executor: HelperExecutor) { self.executor = executor }

    func protocolVersion(reply: @escaping @Sendable (Int) -> Void) {
        reply(helperProtocolVersion)
    }

    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let decoded = HelperCoding.decode(HelperRequest.self, from: request) else {
            reply(HelperCoding.encode(HelperResponse.rejected(.badRequest)))
            return
        }
        guard decoded.protocolVersion == helperProtocolVersion else {
            reply(HelperCoding.encode(HelperResponse.rejected(.unsupportedVersion)))
            return
        }
        let executor = self.executor
        Task {
            let response = await executor.perform(decoded.operation)
            reply(HelperCoding.encode(response))
        }
    }
}
