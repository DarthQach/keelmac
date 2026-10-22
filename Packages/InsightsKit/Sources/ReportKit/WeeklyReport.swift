import Foundation

/// The weekly summary (C25): space change, battery capacity trend, top growing folders, reclaimable space.
///
/// The app builds its localized notification body from the values. `markdown(appVersion:)` is the export
/// for Notion and daily-brief workflows; it is written in English on purpose (a stable, tool-friendly
/// format), with sizes from Foundation's byte-count formatting in a fixed locale.
public struct WeeklyReport: Sendable, Equatable {
    /// How many growing folders the report lists.
    public static let topGrowthLimit = 5

    /// Used space now minus used space at the previous snapshot (0 without one).
    public let usedDelta: Int64
    public let batteryNow: Double?
    /// Capacity points since the previous snapshot; nil when either snapshot has no battery reading.
    public let batteryDelta: Double?
    /// Folders that grew, largest growth first, at most `topGrowthLimit`.
    public let topGrowth: [FolderChange]
    public let reclaimable: Int64
    /// The previous snapshot's date; nil for a first report with nothing to compare.
    public let periodStart: Date?
    public let periodEnd: Date
    public let volumeTotal: Int64
    public let volumeUsed: Int64

    public init(
        usedDelta: Int64, batteryNow: Double?, batteryDelta: Double?, topGrowth: [FolderChange], reclaimable: Int64,
        periodStart: Date?, periodEnd: Date, volumeTotal: Int64, volumeUsed: Int64
    ) {
        self.usedDelta = usedDelta
        self.batteryNow = batteryNow
        self.batteryDelta = batteryDelta
        self.topGrowth = topGrowth
        self.reclaimable = reclaimable
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.volumeTotal = volumeTotal
        self.volumeUsed = volumeUsed
    }

    public var hasComparison: Bool { periodStart != nil }

    public static func make(current: SnapshotValue, previous: SnapshotValue?) -> WeeklyReport {
        var growth: [FolderChange] = []
        if let previous {
            growth = Array(SnapshotDiff.compare(old: previous, new: current).filter { $0.delta > 0 }.prefix(topGrowthLimit))
        }
        var batteryDelta: Double?
        if let now = current.batteryMaxCapacityPercent, let then = previous?.batteryMaxCapacityPercent {
            batteryDelta = now - then
        }
        return WeeklyReport(
            usedDelta: previous.map { current.volumeUsed - $0.volumeUsed } ?? 0,
            batteryNow: current.batteryMaxCapacityPercent,
            batteryDelta: batteryDelta,
            topGrowth: growth,
            reclaimable: current.reclaimableBytes,
            periodStart: previous?.date,
            periodEnd: current.date,
            volumeTotal: current.volumeTotal,
            volumeUsed: current.volumeUsed
        )
    }

    // MARK: - Schedule

    /// True from Monday 09:00 (in `calendar`'s time zone) once per ISO week: when `now` is at or after this
    /// week's Monday 09:00 and no report was made since then.
    public static func isDue(lastReport: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let dueAt = dueMoment(weekOf: now, calendar: calendar), now >= dueAt else { return false }
        guard let lastReport else { return true }
        return lastReport < dueAt
    }

    /// Monday 09:00 of the ISO week containing `date`.
    public static func dueMoment(weekOf date: Date, calendar: Calendar = .current) -> Date? {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        guard let weekStart = iso.dateInterval(of: .weekOfYear, for: date)?.start else { return nil }
        return iso.date(bySettingHour: 9, minute: 0, second: 0, of: weekStart)
    }

    // MARK: - Markdown

    /// A tidy Markdown report: title, period, summary table (space, change, battery, reclaimable), top
    /// growing folders table, footer. Home folders are shortened to `~`.
    public func markdown(
        appVersion: String,
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> String {
        let day = Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day()
        let bytes = { (value: Int64) in Self.bytes(value, locale: locale) }

        var lines: [String] = ["# KeelMac weekly report", ""]
        if let start = periodStart {
            lines.append("**Period:** \(start.formatted(day)) to \(periodEnd.formatted(day))")
        } else {
            lines.append("**Snapshot:** \(periodEnd.formatted(day)) (first report, nothing to compare yet)")
        }
        lines += ["", "## Summary", "", "| Item | Value |", "| --- | --- |"]
        lines.append("| Space used | \(bytes(volumeUsed)) of \(bytes(volumeTotal)) |")
        lines.append("| Free space | \(bytes(max(volumeTotal - volumeUsed, 0))) |")
        lines.append("| Change since last report | \(hasComparison ? Self.signedBytes(usedDelta, locale: locale) : "n/a") |")
        lines.append("| Battery capacity | \(batteryText(locale: locale)) |")
        lines.append("| Reclaimable now | \(bytes(reclaimable)) |")

        lines += ["", "## Top growing folders", ""]
        if !hasComparison {
            lines.append("No earlier snapshot to compare yet.")
        } else if topGrowth.isEmpty {
            lines.append("No folder grew since the last report.")
        } else {
            lines += ["| Folder | Before | Now | Change |", "| --- | ---: | ---: | ---: |"]
            for change in topGrowth {
                let before = change.oldBytes.map(bytes) ?? "new"
                let now = change.newBytes.map(bytes) ?? "removed"
                lines.append("| \(Self.folderCell(change.path)) | \(before) | \(now) | \(Self.signedBytes(change.delta, locale: locale)) |")
            }
        }
        lines += ["", "---", "", "_Generated by KeelMac \(appVersion)._", ""]
        return lines.joined(separator: "\n")
    }

    private func batteryText(locale: Locale) -> String {
        guard let now = batteryNow else { return "No battery" }
        let current = Self.number(now, locale: locale) + "%"
        guard let delta = batteryDelta else { return current }
        if delta == 0 { return current + " (no change)" }
        let unit = abs(delta) == 1 ? "pt" : "pts"
        return current + " (\(delta > 0 ? "+" : "-")\(Self.number(abs(delta), locale: locale)) \(unit))"
    }

    static func bytes(_ value: Int64, locale: Locale) -> String {
        value.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }

    static func signedBytes(_ value: Int64, locale: Locale) -> String {
        if value == 0 { return bytes(0, locale: locale) }
        return (value > 0 ? "+" : "-") + bytes(value.magnitude > UInt64(Int64.max) ? Int64.max : Int64(value.magnitude), locale: locale)
    }

    static func number(_ value: Double, locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(locale))
    }

    /// `/Users/<name>/…` → `~/…`, in a code span; pipes escaped so the table stays intact.
    static func folderCell(_ path: String) -> String {
        let short = shortenHome(path)
        if short.contains("`") { return short.replacingOccurrences(of: "|", with: "\\|") }
        return "`" + short.replacingOccurrences(of: "|", with: "\\|") + "`"
    }

    static func shortenHome(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // ["", "Users", "<name>", ...]
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "Users", !parts[2].isEmpty, parts[2] != "Shared" else { return path }
        let rest = parts.dropFirst(3).joined(separator: "/")
        return rest.isEmpty ? "~" : "~/" + rest
    }
}
