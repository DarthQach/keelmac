import Foundation

/// Cleanup categories, in the order the Cleanup screen lists them.
public enum CleanupCategory: String, Sendable, Codable, CaseIterable {
    case developer, userCaches, browserCaches, logs, installers, iosBackups, docker, languageFiles, trash
}

/// Text shipped inside `cleanup-rules.json`. English and Spanish are both required.
public struct LocalizedText: Sendable, Codable, Equatable, Hashable {
    public let en: String
    public let es: String

    public init(en: String, es: String) { self.en = en; self.es = es }

    /// `"es"`, `"es-MX"`, `"es_419"` give Spanish; everything else English.
    public func value(for languageCode: String) -> String {
        languageCode.lowercased().hasPrefix("es") ? es : en
    }
}

public enum RuleKind: String, Sendable, Codable {
    /// Items are files and folders found by expanding `paths`; they go through `SafeRemover`.
    case paths
    /// One item that runs `command` through `CommandRunning`.
    case command
}

/// An external command: an absolute executable (or `{tool}`, the resolved `toolPaths` entry) and fixed arguments.
public struct CommandSpec: Sendable, Codable, Equatable, Hashable {
    public let executable: String
    public let arguments: [String]
    /// Seconds before the command is stopped. Default 600 when run, 15 for checks and measurements.
    public let timeoutSeconds: Double?

    public init(executable: String, arguments: [String], timeoutSeconds: Double? = nil) {
        self.executable = executable; self.arguments = arguments; self.timeoutSeconds = timeoutSeconds
    }

    /// The executable with `{tool}` replaced.
    public func resolvedExecutable(tool: String?) -> String {
        if executable == CleanupRule.toolPlaceholder, let tool { return tool }
        return executable
    }
}

/// Built-in measurements for command rules whose size can't be found from fixed paths.
public enum MeasureMethod: String, Sendable, Codable, CaseIterable {
    /// `xcrun simctl list devices unavailable -j`, then the size of each unavailable device's folder.
    case simctlUnavailableDevices
    /// `{tool} store path` (pnpm), then the size of that folder.
    case pnpmStorePath
    /// `{tool} system df --format '{{json .}}'` (docker): reclaimable bytes of containers and build cache.
    case dockerSystemDF
}

/// Built-in item filters for path rules that need more than globs.
public enum RuleFilter: String, Sendable, Codable, CaseIterable {
    /// `paths` match `.app` bundles. Only unsigned bundles are used (no `Contents/_CodeSignature` and
    /// `codesign -dv` fails); their `Contents/Resources/*.lproj` folders become the items, except the
    /// languages in `keepLanguages` and the user's preferred languages.
    case unsignedAppLanguages
}

/// Extra information read from each item for the preview.
public enum ItemInfoKind: String, Sendable, Codable, CaseIterable {
    /// An iOS/iPadOS backup folder: device name, model, iOS version and date from its `Info.plist`.
    case iosBackup
}

/// One cleanup rule from `cleanup-rules.json`. See `RULES.md` for the schema.
public struct CleanupRule: Sendable, Codable, Identifiable, Equatable {
    public static let toolPlaceholder = "{tool}"
    public static let uidPlaceholder = "{uid}"

    public let id: String
    public let category: CleanupCategory
    public let title: LocalizedText
    public let detail: LocalizedText
    /// Contributor notes (English, not shown in the app): why folders are excluded, sources.
    public let note: String?
    public let kind: RuleKind
    /// Globs (`*`, `?` within one component; no `**`). Absolute or `~`; `{uid}` is the user's uid.
    public let paths: [String]
    /// Globs; a match (or anything inside it) is never an item, and an item that would contain one is dropped.
    public let exclude: [String]
    /// Items whose newest modification (the newest file inside, for folders) is more recent are left alone.
    public let minAgeDays: Int
    /// Opt-in rules are listed but unchecked by default.
    public let optIn: Bool
    /// Needs administrator rights (the helper). CleanKit doesn't run these; the group reports `.needsHelper`.
    public let needsAdmin: Bool
    /// Without Full Disk Access the group reports `.needsFullDiskAccess` and offers no items.
    public let needsFullDiskAccess: Bool
    /// Bundle ids: while one of these apps runs, the whole rule is skipped (`.appRunning`).
    public let skipIfRunning: [String]
    /// When true, an item named like a running app's bundle id (or `<bundle id>.something`) is skipped.
    public let skipItemIfAppRunning: Bool
    /// For each entry in `paths` separately, the newest N matches (by newest modification) are kept.
    public let keepNewest: Int
    /// Items are deleted permanently instead of moved to the Trash (only for emptying the Trash itself).
    public let deletesPermanently: Bool
    /// The command a `command` rule runs.
    public let command: CommandSpec?
    /// Folders whose size is the expected saving of a command rule (also never offered by path rules).
    public let measure: [String]?
    /// A built-in measurement for command rules.
    public let measureWith: MeasureMethod?
    /// Name of the tool the rule needs (shown when missing). Resolved from `toolPaths`.
    public let requiresTool: String?
    /// Where to look for the tool, in order. The first executable one becomes `{tool}`.
    public let toolPaths: [String]
    /// A check that must exit 0 before the rule is offered (for example `docker info`: the daemon responds).
    public let toolCheck: CommandSpec?
    /// A built-in filter for path rules.
    public let filter: RuleFilter?
    /// Languages always kept by `unsignedAppLanguages` (the user's preferred languages are kept too).
    public let keepLanguages: [String]
    /// Extra information to read from each item.
    public let itemInfo: ItemInfoKind?

    public init(
        id: String, category: CleanupCategory, title: LocalizedText, detail: LocalizedText, note: String? = nil,
        kind: RuleKind = .paths, paths: [String] = [], exclude: [String] = [], minAgeDays: Int = 0,
        optIn: Bool = false, needsAdmin: Bool = false, needsFullDiskAccess: Bool = false,
        skipIfRunning: [String] = [], skipItemIfAppRunning: Bool = false, keepNewest: Int = 0,
        deletesPermanently: Bool = false, command: CommandSpec? = nil, measure: [String]? = nil,
        measureWith: MeasureMethod? = nil, requiresTool: String? = nil, toolPaths: [String] = [],
        toolCheck: CommandSpec? = nil, filter: RuleFilter? = nil, keepLanguages: [String] = [],
        itemInfo: ItemInfoKind? = nil
    ) {
        self.id = id; self.category = category; self.title = title; self.detail = detail; self.note = note
        self.kind = kind; self.paths = paths; self.exclude = exclude; self.minAgeDays = minAgeDays
        self.optIn = optIn; self.needsAdmin = needsAdmin; self.needsFullDiskAccess = needsFullDiskAccess
        self.skipIfRunning = skipIfRunning; self.skipItemIfAppRunning = skipItemIfAppRunning
        self.keepNewest = keepNewest; self.deletesPermanently = deletesPermanently; self.command = command
        self.measure = measure; self.measureWith = measureWith; self.requiresTool = requiresTool
        self.toolPaths = toolPaths; self.toolCheck = toolCheck; self.filter = filter
        self.keepLanguages = keepLanguages; self.itemInfo = itemInfo
    }

    enum CodingKeys: String, CodingKey {
        case id, category, title, detail, note, kind, paths, exclude, minAgeDays, optIn, needsAdmin
        case needsFullDiskAccess, skipIfRunning, skipItemIfAppRunning, keepNewest, deletesPermanently
        case command, measure, measureWith, requiresTool, toolPaths, toolCheck, filter, keepLanguages, itemInfo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decode(CleanupCategory.self, forKey: .category)
        title = try c.decode(LocalizedText.self, forKey: .title)
        detail = try c.decode(LocalizedText.self, forKey: .detail)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        kind = try c.decodeIfPresent(RuleKind.self, forKey: .kind) ?? .paths
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        minAgeDays = try c.decodeIfPresent(Int.self, forKey: .minAgeDays) ?? 0
        optIn = try c.decodeIfPresent(Bool.self, forKey: .optIn) ?? false
        needsAdmin = try c.decodeIfPresent(Bool.self, forKey: .needsAdmin) ?? false
        needsFullDiskAccess = try c.decodeIfPresent(Bool.self, forKey: .needsFullDiskAccess) ?? false
        skipIfRunning = try c.decodeIfPresent([String].self, forKey: .skipIfRunning) ?? []
        skipItemIfAppRunning = try c.decodeIfPresent(Bool.self, forKey: .skipItemIfAppRunning) ?? false
        keepNewest = try c.decodeIfPresent(Int.self, forKey: .keepNewest) ?? 0
        deletesPermanently = try c.decodeIfPresent(Bool.self, forKey: .deletesPermanently) ?? false
        command = try c.decodeIfPresent(CommandSpec.self, forKey: .command)
        measure = try c.decodeIfPresent([String].self, forKey: .measure)
        measureWith = try c.decodeIfPresent(MeasureMethod.self, forKey: .measureWith)
        requiresTool = try c.decodeIfPresent(String.self, forKey: .requiresTool)
        toolPaths = try c.decodeIfPresent([String].self, forKey: .toolPaths) ?? []
        toolCheck = try c.decodeIfPresent(CommandSpec.self, forKey: .toolCheck)
        filter = try c.decodeIfPresent(RuleFilter.self, forKey: .filter)
        keepLanguages = try c.decodeIfPresent([String].self, forKey: .keepLanguages) ?? []
        itemInfo = try c.decodeIfPresent(ItemInfoKind.self, forKey: .itemInfo)
    }

    /// The fixed folder of each path pattern (everything before the first wildcard), for the preview,
    /// e.g. `~/Library/Developer/Xcode/DerivedData`. For command rules, the command line.
    public var displayPaths: [String] {
        if kind == .command, let command {
            return [CommandInvocation.commandLine(command.executable == CleanupRule.toolPlaceholder ? (requiresTool ?? "{tool}") : command.executable, command.arguments)]
        }
        var seen = Set<String>(), out: [String] = []
        for p in paths {
            let parts = p.split(separator: "/", omittingEmptySubsequences: false)
            let fixed = parts.prefix { !$0.contains("*") && !$0.contains("?") }.joined(separator: "/")
            let shown = fixed.isEmpty ? p : fixed
            if seen.insert(shown).inserted { out.append(shown) }
        }
        return out
    }
}

/// The rules file.
public struct RuleSet: Sendable, Codable, Equatable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let rules: [CleanupRule]

    public init(schemaVersion: Int = RuleSet.supportedSchemaVersion, rules: [CleanupRule]) {
        self.schemaVersion = schemaVersion; self.rules = rules
    }

    public enum LoadError: Error, Equatable {
        case missingResource
        case unsupportedSchemaVersion(Int)
        case invalid([RuleProblem])
    }

    /// The rules shipped with KeelMac (`Resources/cleanup-rules.json`).
    public static func bundled() throws -> RuleSet {
        guard let url = Bundle.module.url(forResource: "cleanup-rules", withExtension: "json") else { throw LoadError.missingResource }
        return try load(from: Data(contentsOf: url))
    }

    /// Decodes and validates a rules file.
    public static func load(from data: Data) throws -> RuleSet {
        let set = try JSONDecoder().decode(RuleSet.self, from: data)
        guard set.schemaVersion == supportedSchemaVersion else { throw LoadError.unsupportedSchemaVersion(set.schemaVersion) }
        let problems = set.validate()
        if !problems.isEmpty { throw LoadError.invalid(problems) }
        return set
    }

    public func rule(id: String) -> CleanupRule? { rules.first { $0.id == id } }

    /// Everything wrong with the file. Empty means it is valid.
    public func validate() -> [RuleProblem] {
        var problems: [RuleProblem] = []
        var ids = Set<String>()
        for rule in rules {
            func add(_ issue: RuleProblem.Issue) { problems.append(RuleProblem(ruleID: rule.id, issue: issue)) }
            if rule.id.isEmpty || rule.id.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-") }) { add(.badID) }
            if !ids.insert(rule.id).inserted { add(.duplicateID) }
            for text in [rule.title, rule.detail] where text.en.trimmingCharacters(in: .whitespaces).isEmpty || text.es.trimmingCharacters(in: .whitespaces).isEmpty {
                add(.missingTranslation)
            }
            let allPaths = rule.paths + rule.exclude + (rule.measure ?? []) + rule.toolPaths
            for p in allPaths {
                if !(p.hasPrefix("/") || p.hasPrefix("~/")) { add(.relativePath(p)) }
                if p.split(separator: "/").contains("**") { add(.recursiveGlob(p)) }
                if p.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) { add(.dotComponent(p)) }
            }
            if rule.toolPaths.contains(where: { $0.contains("*") || $0.contains("?") }) { add(.wildcardToolPath) }
            if rule.minAgeDays < 0 || rule.keepNewest < 0 { add(.negativeNumber) }
            switch rule.kind {
            case .paths:
                if rule.paths.isEmpty { add(.noPaths) }
                if rule.command != nil { add(.commandOnPathRule) }
            case .command:
                guard let command = rule.command else { add(.missingCommand); break }
                if !rule.paths.isEmpty { add(.pathsOnCommandRule) }
                for spec in [command] + (rule.toolCheck.map { [$0] } ?? []) {
                    if spec.executable == CleanupRule.toolPlaceholder {
                        if rule.toolPaths.isEmpty { add(.toolPlaceholderWithoutToolPaths) }
                    } else if !spec.executable.hasPrefix("/") {
                        add(.relativeExecutable(spec.executable))
                    }
                }
            }
        }
        return problems
    }
}

public struct RuleProblem: Sendable, Equatable, CustomStringConvertible {
    public enum Issue: Sendable, Equatable {
        case badID, duplicateID, missingTranslation, relativePath(String), recursiveGlob(String), dotComponent(String)
        case wildcardToolPath, negativeNumber, noPaths, commandOnPathRule, missingCommand, pathsOnCommandRule
        case toolPlaceholderWithoutToolPaths, relativeExecutable(String)
    }
    public let ruleID: String
    public let issue: Issue
    public var description: String { "\(ruleID): \(issue)" }
}
