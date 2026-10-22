import AppKit
import AppsKit
import Foundation
import SafetyKit
import ScanKit

/// The app a review item belongs to, and whether it is in use right now.
struct OwnerApp: Hashable, Sendable {
    let name: String
    let bundleID: String?
    let isRunning: Bool
    let lastUsed: Date?
}

/// Whether an item can be removed now (C9).
enum ReviewStatus: Hashable, Sendable {
    /// The owner app is open: removing its files now could break it, so the row is locked.
    case locked(app: String)
    /// The owner app (or, for Ollama, the model) was used in the last 30 days: removal asks first.
    case recentlyUsed(app: String, date: Date)
    case free
}

struct ReviewRow: Identifiable, Hashable, Sendable {
    let item: ReviewItem
    let owner: OwnerApp?
    let status: ReviewStatus
    var id: String { item.id }
    var isLocked: Bool { if case .locked = status { true } else { false } }
}

enum ReviewRules {
    static let recentDays = 30

    static func status(for item: ReviewItem, owner: OwnerApp?, now: Date = .now) -> ReviewStatus {
        guard let owner else { return .free }
        let recent = Calendar.current.date(byAdding: .day, value: -recentDays, to: now) ?? now
        // `ollama rm` talks to the running Ollama app, so Ollama being open never locks a model;
        // the model's own last use is what matters.
        if item.owner == .ollama {
            if let used = item.lastOpened, used >= recent { return .recentlyUsed(app: owner.name, date: used) }
            return .free
        }
        if owner.isRunning { return .locked(app: owner.name) }
        if let used = owner.lastUsed, used >= recent { return .recentlyUsed(app: owner.name, date: used) }
        return .free
    }

    /// Group Containers can be named `TEAMID.com.example.app`; the bundle id is what follows the team id.
    static func bundleID(fromContainer id: String) -> String {
        let parts = id.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isUppercase || $0.isNumber }) { return String(parts[1]) }
        return id
    }
}

/// Looks up owner apps through LaunchServices, NSWorkspace and Spotlight.
enum OwnerResolver {
    static let ollamaBundleID = "com.electron.ollama"
    static let lmStudioBundleID = "ai.elementlabs.lmstudio"

    static func resolve(_ owner: ReviewOwner) -> OwnerApp? {
        switch owner {
        case .ollama: return app(bundleID: ollamaBundleID, fallbackName: "Ollama")
        case .lmStudio: return app(bundleID: lmStudioBundleID, fallbackName: "LM Studio")
        case .huggingFace: return OwnerApp(name: "Hugging Face", bundleID: nil, isRunning: false, lastUsed: nil)
        case .app(let id): return app(bundleID: ReviewRules.bundleID(fromContainer: id), fallbackName: id)
        case .appSupport(let folder):
            let bundle = ["/Applications", NSHomeDirectory() + "/Applications"].map { "\($0)/\(folder).app" }
                .lazy.compactMap(AppInventory.app(at:)).first
            if let id = bundle?.bundleID { return app(bundleID: id, fallbackName: folder) }
            return OwnerApp(name: folder, bundleID: nil, isRunning: false, lastUsed: nil)
        case .none: return nil
        }
    }

    static func app(bundleID: String, fallbackName: String) -> OwnerApp {
        let path = RunningApps.registeredAppPaths(bundleID: bundleID).first
        return OwnerApp(name: path.flatMap(AppInventory.app(at:))?.name ?? fallbackName, bundleID: bundleID,
                        isRunning: RunningApps.isRunning(bundleID: bundleID),
                        lastUsed: path.flatMap(LargeFileFinder.spotlightLastOpened))
    }

    /// Owners resolved once per distinct owner, then a row per item.
    static func rows(for items: [ReviewItem]) -> [ReviewRow] {
        var owners: [ReviewOwner: OwnerApp?] = [:]
        return items.map { item in
            if owners[item.owner] == nil { owners[item.owner] = .some(resolve(item.owner)) }
            let owner = owners[item.owner] ?? nil
            return ReviewRow(item: item, owner: owner, status: ReviewRules.status(for: item, owner: owner))
        }
    }
}

/// `ollama rm`, through the command runner, logged like any other removal.
enum OllamaCLI {
    static let candidates = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]

    static func executable(isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        candidates.first(where: isExecutable)
    }

    /// Removes one model. Returns nil on success, or a message to show.
    static func remove(_ item: ReviewItem, model: String, runner: CommandRunning, log: OperationLogging) async -> String? {
        let failure: String?
        if let exe = executable() {
            let result = await runner.run(exe, ["rm", model], timeout: 120)
            failure = result.succeeded ? nil
                : result.stderr.contains("connect") ? String(localized: "Open Ollama, then try again. KeelMac removes models through Ollama.")
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            failure = String(localized: "KeelMac couldn’t find the ollama command.")
        }
        await log.record([OperationEntry(batchID: UUID(), kind: .trashFile, title: String(localized: "Remove AI model"), path: item.path,
                                         bytes: item.bytes, result: failure == nil ? .removed : .failed, reason: failure)])
        return failure
    }
}
