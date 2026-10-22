import Foundation
import Security

/// Code-signing requirement strings (csreq language) for the two ends of the XPC connection.
/// `anchor apple generic` accepts certificates issued by Apple (Apple Development and Developer ID);
/// `certificate leaf[subject.OU]` pins the team. Ad-hoc signed builds never match.
public enum CodeSigningRequirement {
    /// What the helper requires of a connecting client: the KeelMac app signed by our team.
    public static func client(teamID: String = HelperIdentity.teamID, bundleID: String = HelperIdentity.appBundleID) -> String {
        make(teamID: teamID, bundleID: bundleID)
    }

    /// What the app requires of the helper it connects to.
    public static func helper(teamID: String = HelperIdentity.teamID, bundleID: String = HelperIdentity.helperBundleID) -> String {
        make(teamID: teamID, bundleID: bundleID)
    }

    static func make(teamID: String, bundleID: String) -> String {
        precondition(isValidTeamID(teamID), "Team IDs are 10 uppercase letters or digits")
        precondition(isValidBundleID(bundleID), "Bundle IDs are letters, digits, dots and hyphens")
        return "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Whether the Security framework compiles the requirement (`SecRequirementCreateWithString`).
    public static func isValid(_ requirement: String) -> Bool {
        var req: SecRequirement?
        return SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess && req != nil
    }

    public static func isValidTeamID(_ id: String) -> Bool {
        id.count == 10 && id.unicodeScalars.allSatisfy { ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") }
    }

    public static func isValidBundleID(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix(".") && !id.hasSuffix(".") && !id.contains("..")
            && id.unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || $0 == "." || $0 == "-" }
    }
}
