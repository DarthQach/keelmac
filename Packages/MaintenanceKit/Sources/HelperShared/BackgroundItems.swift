import Foundation

/// One record of the Background Task Management database, as `sfltool dumpbtm` prints it.
/// These are the items listed in System Settings › General › Login Items & Extensions.
public struct BackgroundItemRecord: Sendable, Equatable, Identifiable, Hashable {
    /// `"<uid>:<UUID>"`; the same UUID can appear under several users.
    public var id: String { "\(ownerUID):\(uuid)" }
    /// The user the record belongs to (`-2` is the "nobody" set for system-wide items, `0` root).
    public var ownerUID: Int
    public var uuid: String
    public var name: String
    public var developerName: String?
    public var teamIdentifier: String?
    /// `app`, `login item`, `agent`, `legacy agent`, `legacy daemon`, `developer`, `background tasks`, …
    public var type: String
    public var typeCode: Int?
    public var flags: [String]
    /// For example `["enabled", "allowed", "notified"]`.
    public var disposition: [String]
    public var identifier: String
    public var url: String?
    public var executablePath: String?
    public var bundleIdentifier: String?
    public var parentIdentifier: String?
    public var associatedBundleIDs: [String]
    public var embeddedItemIdentifiers: [String]
    public var lastUse: String?

    public var isEnabled: Bool { disposition.contains("enabled") }
    public var isAllowed: Bool { disposition.contains("allowed") }
    public var isLegacy: Bool { flags.contains("legacy") }
    public var isDaemon: Bool { type.hasSuffix("daemon") }
    public var isAgent: Bool { type.hasSuffix("agent") }

    public init(ownerUID: Int, uuid: String, name: String = "", developerName: String? = nil, teamIdentifier: String? = nil,
                type: String = "", typeCode: Int? = nil, flags: [String] = [], disposition: [String] = [], identifier: String = "",
                url: String? = nil, executablePath: String? = nil, bundleIdentifier: String? = nil, parentIdentifier: String? = nil,
                associatedBundleIDs: [String] = [], embeddedItemIdentifiers: [String] = [], lastUse: String? = nil) {
        self.ownerUID = ownerUID; self.uuid = uuid; self.name = name; self.developerName = developerName
        self.teamIdentifier = teamIdentifier; self.type = type; self.typeCode = typeCode; self.flags = flags
        self.disposition = disposition; self.identifier = identifier; self.url = url; self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier; self.parentIdentifier = parentIdentifier
        self.associatedBundleIDs = associatedBundleIDs; self.embeddedItemIdentifiers = embeddedItemIdentifiers; self.lastUse = lastUse
    }
}

/// Parses `sfltool dumpbtm`. The format is not documented; unknown keys are ignored and a record
/// without a UUID is dropped, so a changed format degrades to fewer records rather than wrong ones.
public enum BackgroundItemsDump {
    /// On macOS 27 a normal user can run this (it lists every user's records). Older releases need the helper
    /// (`HelperOperation.dumpBackgroundItems`).
    public static let userInvocation: (executable: String, arguments: [String]) = (HelperCommandMap.sfltool, ["dumpbtm"])

    public static func parse(_ text: String) -> [BackgroundItemRecord] {
        var records: [BackgroundItemRecord] = []
        var current: BackgroundItemRecord?
        var uid = -2
        var inEmbedded = false

        func flush() {
            if let record = current, !record.uuid.isEmpty { records.append(record) }
            current = nil
            inEmbedded = false
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID") {
                flush()
                let rest = line.dropFirst("Records for UID".count).trimmingCharacters(in: .whitespaces)
                uid = Int(rest.split(separator: " ").first ?? "") ?? -2
                continue
            }
            if line.hasPrefix("#"), line.hasSuffix(":"), Int(line.dropFirst().dropLast()) != nil {
                flush()
                current = BackgroundItemRecord(ownerUID: uid, uuid: "")
                continue
            }
            guard current != nil else { continue }
            if line.isEmpty { inEmbedded = false; continue }
            if inEmbedded, line.hasPrefix("#"), let colon = line.firstIndex(of: ":") {
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { current?.embeddedItemIdentifiers.append(value) }
                continue
            }
            guard let range = line.range(of: ":") else { continue }
            let key = String(line[..<range.lowerBound])
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let optional: String? = (value.isEmpty || value == "(null)") ? nil : value
            switch key {
            case "UUID": current?.uuid = value
            case "Name": current?.name = optional ?? ""
            case "Developer Name": current?.developerName = optional
            case "Team Identifier": current?.teamIdentifier = optional
            case "Type":
                let (name, code) = splitCode(value)
                current?.type = name; current?.typeCode = code
            case "Flags": current?.flags = bracketList(value)
            case "Disposition": current?.disposition = bracketList(value)
            case "Identifier": current?.identifier = value
            case "URL": current?.url = optional
            case "Executable Path": current?.executablePath = optional
            case "Bundle Identifier": current?.bundleIdentifier = optional
            case "Parent Identifier": current?.parentIdentifier = optional
            case "Assoc. Bundle IDs": current?.associatedBundleIDs = bracketList(value)
            case "Last Use": current?.lastUse = optional
            case "Embedded Item Identifiers": inEmbedded = true
            default: break
            }
        }
        flush()
        return records
    }

    /// `"legacy daemon (0x10010)"` → (`"legacy daemon"`, 0x10010).
    static func splitCode(_ value: String) -> (String, Int?) {
        guard let open = value.lastIndex(of: "("), value.hasSuffix(")") else { return (value, nil) }
        let name = value[..<open].trimmingCharacters(in: .whitespaces)
        var code = value[value.index(after: open)..<value.index(before: value.endIndex)]
        if code.hasPrefix("0x") { code = code.dropFirst(2); return (name, Int(code, radix: 16)) }
        return (name, Int(code))
    }

    /// `"[ legacy, curated ] (0x5)"` → `["legacy", "curated"]`.
    static func bracketList(_ value: String) -> [String] {
        guard let open = value.firstIndex(of: "["), let close = value.lastIndex(of: "]"), open < close else { return [] }
        return value[value.index(after: open)..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
