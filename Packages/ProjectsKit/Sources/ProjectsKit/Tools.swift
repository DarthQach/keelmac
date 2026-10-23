import Foundation

/// The two command-line tools Projects uses, always by absolute path.
public enum ProjectTools {
    public static let git = "/usr/bin/git"
    /// Homebrew on Apple silicon, then Intel.
    public static let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]

    public static func gh(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        ghCandidates.first(where: isExecutable)
    }

    /// The command as a person would type it, for previews and the operation log. Display only: KeelMac runs the
    /// executable with the argument array, never this string.
    public static func commandLine(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).map(quote).joined(separator: " ")
    }

    static func quote(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,~^")
        if !word.isEmpty && word.unicodeScalars.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A GitHub repository name made from a folder name.
public enum RepoSlug {
    public static func make(_ folderName: String) -> String {
        let folded = folderName.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var out = ""
        for scalar in folded.unicodeScalars {
            if allowed.contains(scalar) { out.unicodeScalars.append(scalar) } else if !out.hasSuffix("-") { out += "-" }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        if out.count > 100 { out = String(out.prefix(100)).trimmingCharacters(in: CharacterSet(charactersIn: ".-")) }
        return out.isEmpty ? "project" : out
    }

    /// Whether GitHub accepts the name as typed.
    public static func isValid(_ name: String) -> Bool { !name.isEmpty && make(name) == name }
}
