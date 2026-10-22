import Foundation

/// The parts of a launchd job plist KeelMac reads.
struct LaunchdPlist: Sendable, Equatable {
    var label: String
    var program: String?
    var programArguments: [String]
    var runAtLoad: Bool
    var keepAlive: Bool
    var startInterval: Int?
    var hasCalendarInterval: Bool
    var hasWatchPaths: Bool
    var hasOnDemandTriggers: Bool
    var associatedBundleIDs: [String]
    var disabledInPlist: Bool

    /// Program, else the first of ProgramArguments.
    var executable: String? { program ?? programArguments.first }

    /// Every absolute path the job mentions (program and arguments), for owner detection.
    var mentionedPaths: [String] {
        ([program].compactMap { $0 } + programArguments).filter { $0.hasPrefix("/") }
    }

    var schedule: LaunchSchedule {
        if keepAlive { return .keepAlive }
        if let startInterval, startInterval > 0 { return .interval(startInterval) }
        if hasCalendarInterval { return .calendar }
        if runAtLoad { return .atLoad }
        return .onDemand
    }

    static func read(_ path: String) -> LaunchdPlist? {
        guard let dict = BundleReader.plist(at: path) else { return nil }
        return parse(dict, fallbackLabel: BundleReader.stem(of: path))
    }

    static func parse(_ dict: [String: Any], fallbackLabel: String) -> LaunchdPlist {
        let label = (dict["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackLabel
        let args = (dict["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        let keepAlive: Bool
        switch dict["KeepAlive"] {
        case let b as Bool: keepAlive = b
        case let d as [String: Any]: keepAlive = !d.isEmpty
        default: keepAlive = false
        }
        let interval: Int?
        switch dict["StartInterval"] {
        case let n as Int: interval = n
        case let n as NSNumber: interval = n.intValue
        default: interval = nil
        }
        let calendar: Bool
        switch dict["StartCalendarInterval"] {
        case is [String: Any]: calendar = true
        case let a as [Any]: calendar = !a.isEmpty
        default: calendar = false
        }
        let watch = !((dict["WatchPaths"] as? [Any]) ?? []).isEmpty
        let onDemand = watch || dict["QueueDirectories"] != nil || dict["Sockets"] != nil
            || dict["MachServices"] != nil || dict["LaunchEvents"] != nil
        let associated: [String]
        switch dict["AssociatedBundleIdentifiers"] {
        case let s as String: associated = [s]
        case let a as [Any]: associated = a.compactMap { $0 as? String }
        default: associated = []
        }
        return LaunchdPlist(label: label, program: dict["Program"] as? String, programArguments: args,
                            runAtLoad: dict["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
                            startInterval: interval, hasCalendarInterval: calendar, hasWatchPaths: watch,
                            hasOnDemandTriggers: onDemand, associatedBundleIDs: associated,
                            disabledInPlist: dict["Disabled"] as? Bool ?? false)
    }
}
