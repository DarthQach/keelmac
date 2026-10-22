import Foundation

public enum LaunchAdviceAction: Sendable, Hashable {
    case remove, turnOff
}

/// Why an item is worth acting on. No text is built here; the app writes the sentence.
public enum LaunchAdviceReason: Sendable, Hashable {
    /// The program, or the app it belongs to, is no longer installed.
    case appGone
    /// The same label is also in another launchd folder; `otherPath` is the copy that stays.
    case duplicate(otherPath: String)
    /// It only checks for updates; the app updates itself when it's opened.
    case updater
    /// The owning app hasn't been opened since `lastUsed`.
    case appUnused(lastUsed: Date)
}

public struct LaunchAdvice: Sendable, Hashable {
    public let action: LaunchAdviceAction
    public let reason: LaunchAdviceReason
    /// Strong advice is recommended outright; weak advice is "worth a look" (device helpers are rarely opened,
    /// so an old last-used date alone doesn't prove the agent is unneeded).
    public let isStrong: Bool

    public init(action: LaunchAdviceAction, reason: LaunchAdviceReason, isStrong: Bool) {
        self.action = action; self.reason = reason; self.isStrong = isStrong
    }
}

/// Picks the login items worth turning off or removing. Only enabled items get advice: a disabled one is
/// already off, and turning it off again changes nothing.
public enum LaunchAdvisor {
    /// An owning app not opened for this many days makes its agent "worth a look".
    public static let unusedDays = 90
    /// Lowercased fragments of a label or program name that mark an update checker.
    static let updaterMarkers = ["update", "keystone"]

    /// Advice keyed by `LaunchItem.id`; items without advice are absent. First matching rule wins:
    /// app gone → remove; same label in both agent folders → turn off the copy in `~/Library/LaunchAgents`;
    /// an update checker that starts on its own → turn off; owner app unused for `unusedDays` → turn off (weak).
    public static func advise(_ items: [LaunchItem], installed: [InstalledApp], now: Date) -> [String: LaunchAdvice] {
        let globalAgents = Dictionary(items.filter { $0.domain == .globalAgent }.map { ($0.label.lowercased(), $0) },
                                      uniquingKeysWith: { a, _ in a })
        var out: [String: LaunchAdvice] = [:]
        for item in items where !item.isDisabled {
            if !item.ownerInstalled {
                out[item.id] = LaunchAdvice(action: .remove, reason: .appGone, isStrong: true)
            } else if item.domain == .userAgent, let other = globalAgents[item.label.lowercased()], !other.isDisabled {
                out[item.id] = LaunchAdvice(action: .turnOff, reason: .duplicate(otherPath: other.plistPath), isStrong: true)
            } else if item.startsOnItsOwn, isUpdater(item) {
                out[item.id] = LaunchAdvice(action: .turnOff, reason: .updater, isStrong: true)
            } else if item.startsOnItsOwn, let lastUsed = ownerLastUsed(item, installed: installed),
                      now.timeIntervalSince(lastUsed) > Double(unusedDays) * 86_400 {
                out[item.id] = LaunchAdvice(action: .turnOff, reason: .appUnused(lastUsed: lastUsed), isStrong: false)
            }
        }
        return out
    }

    static func isUpdater(_ item: LaunchItem) -> Bool {
        let names = [item.label, item.program.map { ($0 as NSString).lastPathComponent } ?? ""].map { $0.lowercased() }
        return names.contains { name in updaterMarkers.contains { name.contains($0) } }
    }

    static func ownerLastUsed(_ item: LaunchItem, installed: [InstalledApp]) -> Date? {
        guard let bid = item.ownerBundleID else { return nil }
        return installed.first { $0.bundleID?.caseInsensitiveCompare(bid) == .orderedSame }?.lastUsed
    }
}
