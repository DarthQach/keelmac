import Foundation
import ReportKit

/// Turns AlertEngine events into localized notifications (C7).
enum AlertNotifications {
    static func post(_ events: [AlertEvent]) async {
        for e in events {
            let (title, body, route) = text(e)
            await Notifier.shared.post(id: "alert-\(e.kind.rawValue)-\(Int(Date().timeIntervalSince1970))", title: title, body: body,
                                       category: .alert, url: URL(string: "keelmac://open/\(route)"))
        }
    }

    static func text(_ e: AlertEvent) -> (String, String, String) {
        switch e.kind {
        case .diskLow:
            return (String(localized: "Disk space is low"),
                    String(localized: "\(Format.bytes(Int64(e.value))) free on Macintosh HD, below your \(Format.bytes(Int64(e.threshold))) alert."), "cleanup")
        case .memoryRed:
            return (String(localized: "Memory pressure is high"),
                    String(localized: "It has been high for \(Int(e.threshold)) minutes. Open Monitor to see which app is using the most."), "monitor")
        case .temperatureHigh:
            return (String(localized: "Your Mac is running hot"),
                    String(localized: "\(Format.temperature(e.value)), above your \(Format.temperature(e.threshold)) alert."), "monitor")
        case .batteryWorn:
            return (String(localized: "Battery capacity is getting low"),
                    String(localized: "Maximum capacity is \(Format.percent(e.value / 100)), below your \(Format.percent(e.threshold / 100)) alert."), "monitor")
        }
    }
}
