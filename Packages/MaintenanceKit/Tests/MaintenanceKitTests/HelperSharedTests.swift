import Foundation
import Testing
import SafetyKit
@testable import HelperShared

@Suite("HelperCommandMap")
struct HelperCommandMapTests {
    typealias Inv = (String, [String])

    func expect(_ op: HelperOperation, uid: UInt32 = 501, _ expected: [Inv]) {
        let actual = HelperCommandMap.invocations(for: op, clientUID: uid)
        #expect(actual.count == expected.count, "\(op)")
        for (a, e) in zip(actual, expected) {
            #expect(a.executable == e.0, "\(op)")
            #expect(a.arguments == e.1, "\(op)")
        }
    }

    @Test func flushDNS() {
        expect(.flushDNS, [("/usr/bin/dscacheutil", ["-flushcache"]), ("/usr/bin/killall", ["-HUP", "mDNSResponder"])])
    }

    @Test func rebuildSpotlight() { expect(.rebuildSpotlight, [("/usr/bin/mdutil", ["-E", "/"])]) }

    @Test func runPeriodic() { expect(.runPeriodic, [("/usr/sbin/periodic", ["daily", "weekly", "monthly"])]) }

    @Test func thinLocalSnapshots() {
        expect(.thinLocalSnapshots(bytes: 20_000_000_000), [("/usr/bin/tmutil", ["thinlocalsnapshots", "/", "20000000000", "4"])])
    }

    @Test func removeSystemItemsRunsNoCommand() {
        expect(.removeSystemItems(paths: ["/Library/Caches/com.example"]), [])
        #expect(HelperCommandMap.steps(for: .removeSystemItems(paths: ["/Library/Caches/com.example"])) == [.trash(["/Library/Caches/com.example"])])
    }

    @Test func dumpBackgroundItems() { expect(.dumpBackgroundItems, [("/usr/bin/sfltool", ["dumpbtm"])]) }

    @Test func launchdDaemonUsesSystemDomain() {
        let plist = "/Library/LaunchDaemons/com.example.helperd.plist"
        expect(.launchd(label: "com.example.helperd", plistPath: plist, action: .enable), [
            ("/bin/launchctl", ["enable", "system/com.example.helperd"]),
            ("/bin/launchctl", ["bootstrap", "system", plist]),
        ])
        expect(.launchd(label: "com.example.helperd", plistPath: plist, action: .disable), [
            ("/bin/launchctl", ["disable", "system/com.example.helperd"]),
            ("/bin/launchctl", ["bootout", "system/com.example.helperd"]),
        ])
        expect(.launchd(label: "com.example.helperd", plistPath: plist, action: .remove), [
            ("/bin/launchctl", ["bootout", "system/com.example.helperd"]),
        ])
        #expect(HelperCommandMap.steps(for: .launchd(label: "com.example.helperd", plistPath: plist, action: .remove), clientUID: 501) == [
            .run(HelperInvocation("/bin/launchctl", ["bootout", "system/com.example.helperd"], bestEffort: true)),
            .trash([plist]),
        ])
    }

    @Test func launchdAgentUsesClientGuiDomain() {
        let plist = "/Library/LaunchAgents/com.example.agent.plist"
        expect(.launchd(label: "com.example.agent", plistPath: plist, action: .disable), uid: 502, [
            ("/bin/launchctl", ["disable", "gui/502/com.example.agent"]),
            ("/bin/launchctl", ["bootout", "gui/502/com.example.agent"]),
        ])
        expect(.launchd(label: "com.example.agent", plistPath: plist, action: .enable), uid: 502, [
            ("/bin/launchctl", ["enable", "gui/502/com.example.agent"]),
            ("/bin/launchctl", ["bootstrap", "gui/502", plist]),
        ])
    }

    @Test func bestEffortFlagsOnlyOnFollowUpLaunchctlSteps() {
        let plist = "/Library/LaunchDaemons/com.example.d.plist"
        for action in LaunchdAction.allCases {
            let runs = HelperCommandMap.steps(for: .launchd(label: "com.example.d", plistPath: plist, action: action)).compactMap { step -> HelperInvocation? in
                if case .run(let inv) = step { return inv }; return nil
            }
            let flags = runs.map(\.bestEffort)
            switch action {
            case .enable, .disable: #expect(flags == [false, true])
            case .remove: #expect(flags == [true])
            }
        }
        #expect(HelperCommandMap.steps(for: .flushDNS).allSatisfy { if case .run(let i) = $0 { return !i.bestEffort }; return false })
    }

    @Test func everyExecutableIsAbsoluteAndAllowed() {
        let ops: [HelperOperation] = [.flushDNS, .rebuildSpotlight, .runPeriodic, .thinLocalSnapshots(bytes: 1), .dumpBackgroundItems,
                                      .removeSystemItems(paths: ["/Library/Caches/x"])]
            + LaunchdAction.allCases.map { .launchd(label: "com.example.d", plistPath: "/Library/LaunchDaemons/com.example.d.plist", action: $0) }
        for op in ops {
            for inv in HelperCommandMap.invocations(for: op) {
                #expect(inv.executable.hasPrefix("/"))
                #expect(HelperCommandMap.allowedExecutables.contains(inv.executable))
            }
        }
    }
}

@Suite("HelperValidation")
struct HelperValidationTests {
    @Test(arguments: ["com.example.helper", "mx.cvillegas.keelmac.helper", "org.foo-bar.baz_2", "io.x"])
    func validLabels(_ label: String) {
        #expect(HelperValidation.isValidLabel(label))
    }

    @Test(arguments: ["", "com", "com.example helper", "com.example;rm", "com..example", ".com.example", "com.example.",
                      "com/example", "com.example/../x", "com.example\n", "com.example'", "com.\"x\"", "-com.example",
                      "com.ex$ample", "com.exämple", "com.example\u{0}"])
    func invalidLabels(_ label: String) {
        #expect(!HelperValidation.isValidLabel(label))
        let op = HelperOperation.launchd(label: label, plistPath: "/Library/LaunchDaemons/\(label).plist", action: .disable)
        #expect(HelperValidation.validate(op) != nil)
    }

    @Test func appleLabelsAreRefused() {
        let op = HelperOperation.launchd(label: "com.apple.mDNSResponder", plistPath: "/Library/LaunchDaemons/com.apple.mDNSResponder.plist", action: .disable)
        #expect(HelperValidation.validate(op) == .appleLabel)
    }

    @Test(arguments: [
        "/System/Library/LaunchDaemons/com.example.d.plist",
        "/Users/carlos/Library/LaunchAgents/com.example.d.plist",
        "/Library/LaunchDaemons/../LaunchDaemons/com.example.d.plist",
        "/Library/LaunchDaemons/sub/com.example.d.plist",
        "/Library/LaunchDaemons//com.example.d.plist",
        "Library/LaunchDaemons/com.example.d.plist",
        "/Library/LaunchDaemons/com.example.d.txt",
        "/tmp/com.example.d.plist",
        "/Library/LaunchDaemons",
        "/private/var/db/com.example.d.plist",
    ])
    func plistOutsideLaunchFoldersIsRefused(_ path: String) {
        let op = HelperOperation.launchd(label: "com.example.d", plistPath: path, action: .remove)
        #expect(HelperValidation.validate(op) == .plistOutsideLaunchFolders)
    }

    @Test func plistMustMatchLabel() {
        let mismatch = HelperOperation.launchd(label: "com.example.d", plistPath: "/Library/LaunchDaemons/com.other.d.plist", action: .disable)
        #expect(HelperValidation.validate(mismatch) == .plistLabelMismatch)
        // A plist named differently is accepted only when its Label key says so.
        #expect(HelperValidation.validate(mismatch, plistLabel: { _ in "com.example.d" }) == nil)
        #expect(HelperValidation.validate(mismatch, plistLabel: { _ in "com.evil.d" }) == .plistLabelMismatch)
        let ok = HelperOperation.launchd(label: "com.example.d", plistPath: "/Library/LaunchAgents/com.example.d.plist", action: .enable)
        #expect(HelperValidation.validate(ok) == nil)
    }

    @Test func removeSystemItemsPathsMustBeClean() {
        #expect(HelperValidation.validate(.removeSystemItems(paths: [])) == .noPaths)
        #expect(HelperValidation.validate(.removeSystemItems(paths: Array(repeating: "/Library/Caches/x", count: 1001))) == .tooManyPaths)
        for bad in ["relative/path", "/Library/Caches/../../System", "/Library/Caches/./x", "/Library//Caches/x", "/Library/Caches/x/",
                    "/Library/Caches/x\n/etc", "/", "~/Library/Caches"] {
            #expect(HelperValidation.validate(.removeSystemItems(paths: ["/Library/Caches/ok", bad])) == .invalidPath, "\(bad)")
        }
        #expect(HelperValidation.validate(.removeSystemItems(paths: ["/Library/Caches/com.example", "/Library/Logs/Example Log.log"])) == nil)
    }

    @Test func thinBytesMustBePositiveAndSane() {
        #expect(HelperValidation.validate(.thinLocalSnapshots(bytes: 0)) == .invalidByteCount)
        #expect(HelperValidation.validate(.thinLocalSnapshots(bytes: -5)) == .invalidByteCount)
        #expect(HelperValidation.validate(.thinLocalSnapshots(bytes: .max)) == .invalidByteCount)
        #expect(HelperValidation.validate(.thinLocalSnapshots(bytes: 10_000_000_000)) == nil)
    }
}

@Suite("CodeSigningRequirement")
struct CodeSigningRequirementTests {
    @Test func clientRequirement() {
        let req = CodeSigningRequirement.client(teamID: "735MC85596", bundleID: "mx.cvillegas.keelmac")
        #expect(req == #"anchor apple generic and identifier "mx.cvillegas.keelmac" and certificate leaf[subject.OU] = "735MC85596""#)
        #expect(CodeSigningRequirement.client() == req)
        #expect(CodeSigningRequirement.isValid(req))
    }

    @Test func helperRequirement() {
        let req = CodeSigningRequirement.helper()
        #expect(req == #"anchor apple generic and identifier "mx.cvillegas.keelmac.helper" and certificate leaf[subject.OU] = "735MC85596""#)
        #expect(CodeSigningRequirement.isValid(req))
    }

    @Test func builtFromTeamID() {
        let req = CodeSigningRequirement.client(teamID: "ABCDE12345", bundleID: "com.example.app")
        #expect(req.contains(#"leaf[subject.OU] = "ABCDE12345""#))
        #expect(req.contains(#"identifier "com.example.app""#))
    }

    @Test func invalidRequirementIsDetected() {
        #expect(!CodeSigningRequirement.isValid("anchor apple generic and"))
        #expect(!CodeSigningRequirement.isValid("=anchor apple"))
    }

    @Test func identityValidators() {
        #expect(CodeSigningRequirement.isValidTeamID("735MC85596"))
        #expect(!CodeSigningRequirement.isValidTeamID("735mc85596"))
        #expect(!CodeSigningRequirement.isValidTeamID("735MC8559\""))
        #expect(CodeSigningRequirement.isValidBundleID("mx.cvillegas.keelmac.helper"))
        #expect(!CodeSigningRequirement.isValidBundleID("mx.cvillegas\" or anchor apple"))
    }
}

@Suite("Coding")
struct CodingTests {
    @Test func responseRoundTrip() throws {
        let response = HelperResponse(
            exitCode: 1, output: "line 1\nline 2\n",
            outcomes: [
                HelperItemOutcome(path: "/Library/Caches/x", bytes: 42, result: .trashed, reason: nil, refusal: nil),
                HelperItemOutcome(path: "/System/x", bytes: 0, result: .refused, reason: "Protected location", refusal: .protectedLocation),
            ],
            rejection: nil, timedOut: false)
        let decoded = try #require(HelperCoding.decode(HelperResponse.self, from: HelperCoding.encode(response)))
        #expect(decoded == response)
        let rejected = HelperResponse.rejected(.invalidLabel)
        #expect(HelperCoding.decode(HelperResponse.self, from: HelperCoding.encode(rejected)) == rejected)
        #expect(rejected.exitCode == 64 && !rejected.succeeded)
    }

    @Test func requestRoundTripForEveryOperation() throws {
        let ops: [HelperOperation] = [.flushDNS, .rebuildSpotlight, .runPeriodic, .thinLocalSnapshots(bytes: 123), .dumpBackgroundItems,
                                      .removeSystemItems(paths: ["/Library/Caches/a", "/Library/Logs/b c"]),
                                      .launchd(label: "com.example.d", plistPath: "/Library/LaunchDaemons/com.example.d.plist", action: .remove)]
        for op in ops {
            let request = HelperRequest(operation: op)
            #expect(request.protocolVersion == helperProtocolVersion)
            #expect(HelperCoding.decode(HelperRequest.self, from: HelperCoding.encode(request)) == request)
        }
    }

    @Test func garbageAndOversizedMessagesAreRefused() {
        #expect(HelperCoding.decode(HelperRequest.self, from: Data("{\"protocolVersion\":1,\"operation\":{\"shell\":{}}}".utf8)) == nil)
        #expect(HelperCoding.decode(HelperRequest.self, from: Data(repeating: 0x20, count: HelperCoding.maxMessageBytes + 1)) == nil)
    }
}

@Suite("CommandLineFormatter")
struct CommandLineFormatterTests {
    @Test func quotesOnlyWhenNeeded() {
        #expect(CommandLineFormatter.format("/usr/bin/mdutil", ["-E", "/"]) == "/usr/bin/mdutil -E /")
        #expect(CommandLineFormatter.format("/bin/echo", ["a b", "it's", ""]) == #"/bin/echo 'a b' 'it'\''s' ''"#)
        #expect(CommandLineFormatter.join([("/a", ["1"]), ("/b", [])]) == "/a 1 && /b")
    }
}

@Suite("BackgroundItemsDump")
struct BackgroundItemsDumpTests {
    @Test func parsesFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "dumpbtm", withExtension: "txt", subdirectory: "Fixtures"))
        let records = BackgroundItemsDump.parse(try String(contentsOf: url, encoding: .utf8))
        #expect(records.count == 3)

        let developer = records[0]
        #expect(developer.ownerUID == -2)
        #expect(developer.type == "developer" && developer.typeCode == 0x20)
        #expect(developer.url == nil && developer.developerName == "Example Corp")
        #expect(developer.embeddedItemIdentifiers == ["16.com.example.helperd", "8.com.example.agent"])

        let daemon = records[1]
        #expect(daemon.uuid == "11111111-AAAA-4BBB-8CCC-000000000002")
        #expect(daemon.isDaemon && daemon.isLegacy && daemon.isEnabled && daemon.isAllowed)
        #expect(daemon.flags == ["legacy", "curated"])
        #expect(daemon.typeCode == 0x10010)
        #expect(daemon.url == "/Library/LaunchDaemons/com.example.helperd.plist")
        #expect(daemon.executablePath == "/Library/PrivilegedHelperTools/com.example.helperd")
        #expect(daemon.associatedBundleIDs == ["com.example.app", "com.example.app2"])
        #expect(daemon.teamIdentifier == "ABCDE12345")
        #expect(daemon.lastUse == "2026-10-22 07:50:36-06:00")
        #expect(daemon.embeddedItemIdentifiers.isEmpty)

        let login = records[2]
        #expect(login.ownerUID == 501)
        #expect(login.type == "login item")
        #expect(!login.isEnabled && !login.isAllowed)
        #expect(login.disposition == ["disabled", "disallowed", "notified"])
        #expect(login.developerName == nil)
        #expect(login.flags == ["sandboxed"])
        #expect(login.id == "501:33333333-CCCC-4DDD-8EEE-000000000003")
    }

    @Test func toleratesEmptyAndUnknownInput() {
        #expect(BackgroundItemsDump.parse("").isEmpty)
        #expect(BackgroundItemsDump.parse("Usage: sfltool …\n #1:\n Name: no uuid\n").isEmpty)
        #expect(BackgroundItemsDump.bracketList("[  ] (0)") == [])
    }
}
