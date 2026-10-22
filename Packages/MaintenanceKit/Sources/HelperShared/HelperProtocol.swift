import Foundation

/// The Mach service the KeelMac helper daemon listens on. Must match `MachServices` in the launchd plist.
public let helperMachServiceName = "mx.cvillegas.keelmac.helper"

/// Bumped whenever `HelperRequest`, `HelperOperation` or `HelperResponse` change shape.
/// The app refuses to talk to a helper that answers a different number (it asks the user to update it).
public let helperProtocolVersion = 1

/// Fixed identities of KeelMac's two signed executables.
public enum HelperIdentity {
    public static let teamID = "735MC85596"
    public static let appBundleID = "mx.cvillegas.keelmac"
    public static let helperBundleID = "mx.cvillegas.keelmac.helper"
    /// File name of the launchd plist in `KeelMac.app/Contents/Library/LaunchDaemons/`.
    public static let launchdPlistName = "mx.cvillegas.keelmac.helper.plist"
}

/// The whole XPC surface: a version handshake and one JSON-in/JSON-out call.
/// `request` is a JSON `HelperRequest`; the reply is a JSON `HelperResponse`.
@objc public protocol KeelMacHelperProtocol {
    func protocolVersion(reply: @escaping @Sendable (Int) -> Void)
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

extension NSXPCInterface {
    /// The interface both sides configure for `KeelMacHelperProtocol`.
    public static func keelMacHelper() -> NSXPCInterface {
        NSXPCInterface(with: KeelMacHelperProtocol.self)
    }
}
