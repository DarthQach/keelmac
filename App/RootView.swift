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
                .alternatingRowBackgrounds(.disabled)
        }
        .task { model.start() }
        .alert(Text("KeelMac didn’t change that item"), isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(model.notice ?? ""))
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
            case .dashboard:
                DashboardView()
            case .monitor:
                MonitorView()
            case .operationLog:
                OperationLogView()
            case .duplicates:
                DuplicatesView()
            case .snapshots:
                SnapshotsView()
            case .maintenance:
                MaintenanceView()
            case .cleanup:
                CleanupView()
            case .storageMap:
                StorageMapView()
            case .largeOld:
                LargeOldView()
            case .systemData:
                SystemDataView()
            case .apps:
                AppsView()
            case .leftovers:
                LeftoversView()
            case .loginItems:
                LoginItemsView()
            }
        }
        .navigationTitle(route.title)
    }
}
