import SwiftUI

/// Every destination in the main window's sidebar, in sidebar order.
enum Route: String, CaseIterable, Identifiable, Hashable, Codable {
    case dashboard, monitor
    case storageMap, largeOld, systemData, duplicates, snapshots
    case cleanup, apps, leftovers, loginItems, maintenance, projects
    case operationLog

    var id: String { rawValue }

    enum Section: String, CaseIterable, Identifiable {
        case overview, storage, clean, history
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .overview: "Overview"
            case .storage: "Storage"
            case .clean: "Clean"
            case .history: "History"
            }
        }

        var routes: [Route] { Route.allCases.filter { $0.section == self } }
    }

    var section: Section {
        switch self {
        case .dashboard, .monitor: .overview
        case .storageMap, .largeOld, .systemData, .duplicates, .snapshots: .storage
        case .cleanup, .apps, .leftovers, .loginItems, .maintenance, .projects: .clean
        case .operationLog: .history
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: "Dashboard"
        case .monitor: "Monitor"
        case .storageMap: "Storage map"
        case .largeOld: "Review large files"
        case .systemData: "System Data"
        case .duplicates: "Duplicates"
        case .snapshots: "Snapshots"
        case .cleanup: "Cleanup"
        case .apps: "Apps"
        case .leftovers: "Leftovers"
        case .loginItems: "Login items"
        case .maintenance: "Maintenance"
        case .projects: "Projects"
        case .operationLog: "Operation log"
        }
    }

    /// SF Symbol, outlined; the sidebar shows the filled variant when selected.
    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .monitor: "waveform.path.ecg"
        case .storageMap: "square.grid.3x3.square"
        case .largeOld: "doc.badge.clock"
        case .systemData: "internaldrive"
        case .duplicates: "doc.on.doc"
        case .snapshots: "calendar.badge.clock"
        case .cleanup: "trash"
        case .apps: "app.badge"
        case .leftovers: "shippingbox"
        case .loginItems: "power"
        case .maintenance: "wrench.and.screwdriver"
        case .projects: "folder.badge.gearshape"
        case .operationLog: "list.bullet.rectangle"
        }
    }

    /// ⌘1…⌘9 for the first nine destinations.
    var shortcut: KeyEquivalent? {
        guard let index = Route.allCases.firstIndex(of: self), index < 9 else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }

    /// keelmac://open/<route>
    init?(url: URL) {
        guard url.scheme == "keelmac", url.host == "open", let name = url.pathComponents.dropFirst().first,
              let route = Route(rawValue: name) else { return nil }
        self = route
    }
}


extension Route {
    var subtitle: LocalizedStringKey {
        switch self {
        case .dashboard: "A clear view of your Mac."
        case .monitor: "Live activity, at a glance."
        case .storageMap: "See where your space goes."
        case .largeOld: "Find what is worth keeping."
        case .systemData: "Understand the space behind System Data."
        case .duplicates: "Compare copies before removing them."
        case .snapshots: "See how your storage changes over time."
        case .cleanup: "More room. Every item in your control."
        case .apps: "Your apps and everything that comes with them."
        case .leftovers: "Review files left behind by removed apps."
        case .loginItems: "Know what starts with your Mac."
        case .maintenance: "Purposeful tools. Transparent commands."
        case .projects: "Keep what you work on. Let go of what GitHub already has."
        case .operationLog: "A record of every change."
        }
    }
}
