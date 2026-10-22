import Foundation

/// When the soft "Buy me a coffee?" prompt may appear after a cleanup: at least 2 GB freed in one run,
/// at most once per 30 days, never after "Don't ask again".
public enum CoffeePrompt {
    public static let minimumBytes: Int64 = 2_000_000_000
    public static let minimumInterval: TimeInterval = 30 * 24 * 3600

    public static func shouldShow(freedBytes: Int64, lastShown: Date?, dismissedForever: Bool, now: Date) -> Bool {
        guard !dismissedForever, freedBytes >= minimumBytes else { return false }
        guard let lastShown else { return true }
        return now.timeIntervalSince(lastShown) >= minimumInterval
    }
}
