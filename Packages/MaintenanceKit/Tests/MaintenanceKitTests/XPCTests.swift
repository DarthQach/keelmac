import Foundation
import Testing
import SafetyKit
import HelperShared
import HelperCore
import MaintenanceKit

/// An anonymous in-process listener running the real `HelperListenerDelegate`, with a recording runner.
/// No Mach service, no launchd, no root: XPC end to end inside the test process.
final class InProcessHelper: @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let delegate: HelperListenerDelegate
    let runner: RecordingCommandRunner

    init(requirement: String? = nil, handler: @escaping @Sendable (String, [String]) -> CommandResult = { _, _ in CommandResult(exitCode: 0, stdout: "done", stderr: "") }) {
        runner = RecordingCommandRunner(handler: handler)
        let remover = SafeRemover(pathGuard: PathGuard(home: "/Users/carlos", userName: "carlos", uid: 501), mode: .trash, context: .helper)
        let executor = HelperExecutor(runner: runner, remover: remover, clientUID: 501)
        delegate = HelperListenerDelegate(executor: executor, requirement: requirement, bindExecutor: { base, _ in base })
        listener.delegate = delegate
        listener.resume()
    }

    func client() -> HelperClient {
        let endpoint = EndpointBox(listener.endpoint)
        let client = HelperClient(connectionFactory: { NSXPCConnection(listenerEndpoint: endpoint.value) }, requirement: nil)
        client.handshakeTimeout = 5
        return client
    }

    deinit { listener.invalidate() }
}

final class EndpointBox: @unchecked Sendable {
    let value: NSXPCListenerEndpoint
    init(_ value: NSXPCListenerEndpoint) { self.value = value }
}

@Suite("XPC round trip", .serialized)
struct XPCTests {
    @Test func versionHandshake() async throws {
        let helper = InProcessHelper()
        let client = helper.client()
        #expect(try await client.remoteProtocolVersion() == helperProtocolVersion)
        client.invalidate()
    }

    @Test func performRunsThroughTheListener() async throws {
        let helper = InProcessHelper()
        let client = helper.client()
        let response = try await client.perform(.flushDNS, timeout: 10)
        #expect(response.succeeded)
        #expect(response.output == "done\ndone\n")
        #expect(helper.runner.calls.map(\.0) == ["/usr/bin/dscacheutil", "/usr/bin/killall"])

        let again = try await client.perform(.rebuildSpotlight, timeout: 10)
        #expect(again.exitCode == 0)
        #expect(helper.runner.calls.last?.1 == ["-E", "/"])
        client.invalidate()
    }

    @Test func helperRejectsInvalidOperationsOverXPC() async throws {
        let helper = InProcessHelper()
        let client = helper.client()
        let response = try await client.perform(.launchd(label: "com.example.d; reboot", plistPath: "/Library/LaunchDaemons/x.plist", action: .disable), timeout: 10)
        #expect(response.rejection == .invalidLabel)
        #expect(helper.runner.calls.isEmpty)
        client.invalidate()
    }

    @Test func maintenanceRunnerDrivesTheHelperClient() async throws {
        let helper = InProcessHelper { _, _ in CommandResult(exitCode: 0, stdout: "thinned 3 snapshots", stderr: "") }
        let client = helper.client()
        var runner = MaintenanceRunner(runner: RecordingCommandRunner(), helper: client)
        runner.executableExists = { _ in true }
        var lines: [String] = []
        var finished: Int32?
        for await event in runner.run(MaintenanceCatalog.task(.thinLocalSnapshots)) {
            switch event {
            case .output(let line): lines.append(line)
            case .finished(let code, _): finished = code
            case .failed(let failure): Issue.record("unexpected failure \(failure)")
            }
        }
        #expect(lines == ["thinned 3 snapshots"])
        #expect(finished == 0)
        #expect(helper.runner.calls.first?.1 == ["thinlocalsnapshots", "/", "20000000000", "4"])
        client.invalidate()
    }

    @Test func malformedRequestIsRejected() async throws {
        let helper = InProcessHelper()
        let connection = NSXPCConnection(listenerEndpoint: helper.listener.endpoint)
        connection.remoteObjectInterface = .keelMacHelper()
        connection.resume()
        defer { connection.invalidate() }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! KeelMacHelperProtocol
            proxy.perform(Data("{\"protocolVersion\":1,\"operation\":{\"shell\":{\"cmd\":\"rm -rf /\"}}}".utf8)) { continuation.resume(returning: $0) }
        }
        #expect(HelperCoding.decode(HelperResponse.self, from: data) == .rejected(.badRequest))
        let wrongVersion: Data = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! KeelMacHelperProtocol
            proxy.perform(HelperCoding.encode(HelperRequest(operation: .flushDNS, protocolVersion: 99))) { continuation.resume(returning: $0) }
        }
        #expect(HelperCoding.decode(HelperResponse.self, from: wrongVersion) == .rejected(.unsupportedVersion))
        #expect(helper.runner.calls.isEmpty)
    }

    @Test func clientThatFailsTheRequirementIsCutOff() async {
        // The test runner isn't KeelMac signed by our team, so the production requirement must refuse it.
        let helper = InProcessHelper(requirement: CodeSigningRequirement.client())
        let client = helper.client()
        await #expect(throws: HelperClientError.self) { _ = try await client.perform(.flushDNS, timeout: 5) }
        #expect(helper.runner.calls.isEmpty)
        client.invalidate()
    }

    @Test func invalidRequirementRefusesEveryConnection() async {
        let helper = InProcessHelper(requirement: "anchor apple generic and")
        let client = helper.client()
        await #expect(throws: HelperClientError.self) { _ = try await client.remoteProtocolVersion() }
        client.invalidate()
    }
}
