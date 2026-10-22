import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding(get: { model.route }, set: { if let r = $0 { model.route = r } })) {
                ForEach(Route.Section.allCases) { section in
                    Section(section.title) {
                        ForEach(section.routes) { route in
                            Label(route.title, systemImage: route.symbol)
                                .tag(route)
                                .accessibilityIdentifier("sidebar.\(route.rawValue)")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) {
                if !model.hasFullDiskAccess {
                    Button {
                        model.showWelcome = true
                    } label: {
                        Label("Full Disk Access is off", systemImage: "lock.shield")
                            .font(.callout)
                            .foregroundStyle(.kmWarningInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .padding(12)
                }
            }
        } detail: {
            RouteView(route: model.route)
                .id(model.route)
        }
        .sheet(isPresented: $model.showWelcome) {
            WelcomeView()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFullDiskAccess()
        }
    }
}

/// Maps a route to its screen.
struct RouteView: View {
    let route: Route

    var body: some View {
        Page {
            switch route {
            default:
                PlaceholderScreen(route: route)
            }
        }
        .navigationTitle(route.title)
    }
}

/// Designed empty state for screens whose feature hasn't loaded data yet.
struct PlaceholderScreen: View {
    let route: Route

    var body: some View {
        switch route {
        case .dashboard:
            EmptyStateView(symbol: "gauge.with.dots.needle.33percent", title: "Measuring your Mac…", message: "The Health Score appears as soon as the first readings are in.")
        case .monitor:
            EmptyStateView(symbol: "waveform.path.ecg", title: "Measuring…", message: "Live charts fill in from the left every two seconds.")
        case .storageMap:
            EmptyStateView(symbol: "square.grid.3x3.square", title: "See what fills Macintosh HD", message: "A full scan takes about a minute and never reads file contents. After that, rescans only look at folders that changed.")
        case .largeOld:
            EmptyStateView(symbol: "doc.badge.clock", title: "Scan first", message: "Large and old files come from the storage scan.")
        case .systemData:
            EmptyStateView(symbol: "internaldrive", title: "Scan to break down System Data", message: "KeelMac measures the folders macOS counts as System Data.")
        case .duplicates:
            EmptyStateView(symbol: "doc.on.doc", title: "Choose folders to search", message: "KeelMac compares files byte for byte. Nothing is moved until you choose.")
        case .snapshots:
            EmptyStateView(symbol: "calendar.badge.clock", title: "No snapshots yet", message: "KeelMac takes one every week, so you can see what grew.")
        case .cleanup:
            EmptyStateView(symbol: "trash", title: "Nothing to clean right now", message: "KeelMac checks again each time you open Cleanup.")
        case .apps:
            EmptyStateView(symbol: "app.badge", title: "Reading your apps…", message: "Apps in /Applications and ~/Applications appear here with their size and last use.")
        case .leftovers:
            EmptyStateView(symbol: "shippingbox", title: "No leftovers from deleted apps", message: "Files in your Library from apps that are no longer installed appear here.")
        case .loginItems:
            EmptyStateView(symbol: "power", title: "No login items or background agents", message: "Agents and daemons that start with your Mac appear here.")
        case .maintenance:
            EmptyStateView(symbol: "wrench.and.screwdriver", title: "Maintenance", message: "Each task shows the exact command it runs.")
        case .operationLog:
            EmptyStateView(symbol: "list.bullet.rectangle", title: "No operations yet", message: "Everything KeelMac moves or deletes is listed here.")
        }
    }
}
