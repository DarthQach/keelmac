import Foundation
import UserNotifications

/// Local notifications only (alerts, weekly summary, trashed-app offer). Each carries a keelmac:// route.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()
    var onOpenURL: (@MainActor (URL) -> Void)?

    enum Category: String { case alert, weekly, trashedApp }
    static let reviewAction = "review"

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let review = UNNotificationAction(identifier: Notifier.reviewAction, title: String(localized: "Review files"), options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.alert.rawValue, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.weekly.rawValue, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.trashedApp.rawValue, actions: [review], intentIdentifiers: []),
        ])
    }

    /// Asks for permission the first time KeelMac has something to say.
    func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    func post(id: String, title: String, body: String, category: Category, url: URL?) async {
        guard await requestAuthorizationIfNeeded() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category.rawValue
        if let url { content.userInfo = ["url": url.absoluteString] }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: raw) else { return }
        await MainActor.run { onOpenURL?(url) }
    }
}
