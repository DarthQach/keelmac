import AppsKit
import SafetyKit
import SwiftUI
import UniformTypeIdentifiers

/// S11: installed apps by size and last use, with a drop zone and the uninstall action (C16, C18, C20).
struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: InstalledApp.ID?
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\InstalledApp.sortBytes, order: .reverse)]
    @State private var dropTargeted = false

    private var apps: AppsModel { model.apps }

    private var rows: [InstalledApp] {
        apps.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.sorted(using: sortOrder)
    }

    var body: some View {
        @Bindable var apps = model.apps
        HStack(spacing: 0) {
            Group {
                if apps.apps.isEmpty && apps.loadingApps {
                    ProgressView("Reading your apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if apps.apps.isEmpty {
                    EmptyStateView(symbol: "app.badge", title: "No apps found", message: "Apps in /Applications and ~/Applications appear here with their size and last use.")
                } else {
                    VStack(spacing: 0) {
                        Table(rows, selection: $selection, sortOrder: $sortOrder) {
                            TableColumn("Name", value: \.name) { app in
                                HStack(spacing: 8) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 28, height: 28)
                                    Text(verbatim: app.name).fontWeight(.medium).lineLimit(1)
                                }
                                .frame(minHeight: Metrics.rowHeight)
                                .help(app.name)
                            }.width(min: 160, ideal: 260)
                            TableColumn("Size", value: \.sortBytes) { app in
                                Text(app.bytes.map(Format.bytes) ?? "…").tabular().frame(maxWidth: .infinity, alignment: .trailing)
                            }.width(90)
                            TableColumn("Last used", value: \.sortLastUsed) { app in
                                Text(app.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "Unknown"))
                                    .tabular().frame(maxWidth: .infinity, alignment: .trailing)
                            }.width(130)
                            TableColumn("Version") { app in Text(verbatim: app.version ?? "").foregroundStyle(.kmFgMuted) }.width(90)
                        }
                        .kmTableSurface()
                        .contextMenu(forSelectionType: InstalledApp.ID.self) { ids in
                            if let app = apps.apps.first(where: { ids.contains($0.id) }) {
                                Button("Uninstall…") { apps.uninstallTarget = app }
                                Button("Reveal in Finder") { FileActions.reveal([app.path]) }
                            }
                        } primaryAction: { ids in
                            if let app = apps.apps.first(where: { ids.contains($0.id) }) { apps.uninstallTarget = app }
                        }
                        Divider()
                        HStack {
                            Text("\(apps.apps.count) apps, \(Format.bytes(apps.apps.compactMap(\.bytes).reduce(0, +))). Apple’s built-in apps aren’t listed.")
                                .foregroundStyle(.kmFgMuted).tabular()
                            Spacer()
                            if apps.loadingApps { ProgressView().controlSize(.small); Text("Measuring sizes…").foregroundStyle(.kmFgMuted) }
                        }
                        .font(.callout)
                        .padding(.horizontal, Metrics.pagePadding).padding(.vertical, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let app = apps.apps.first(where: { $0.id == selection }) {
                        AppInspector(app: app) { apps.uninstallTarget = app }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .kmGroup()
                    }
                    dropZone
                }
            }
            .frame(width: 240)
            .padding(.leading, 16)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.bottom, Metrics.pagePadding)
        .searchable(text: $search, placement: .toolbar, prompt: Text("Search apps"))
        .task { if apps.apps.isEmpty { await apps.loadApps() } }
        .sheet(item: $apps.uninstallTarget) { app in UninstallSheet(app: app) }
        .assistantContext(.apps(apps, selected: apps.apps.first { $0.id == selection }))
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down").font(.title.weight(.light)).foregroundStyle(.kmFgMuted)
            Text("Drop an app here to uninstall it").fontWeight(.semibold).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text("You’ll see every related file first.").font(.callout).foregroundStyle(.kmFgMuted).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(dropTargeted ? Color.kmAccentSoft : Color.clear, in: RoundedRectangle(cornerRadius: Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radius).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(dropTargeted ? Color.kmAccent : Color.kmBorderStrong))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension == "app" else { return }
                let path = url.path
                Task { @MainActor in
                    if let app = AppInventory.app(at: path) { model.apps.uninstallTarget = AppInventory.measure(app) }
                }
            }
            return true
        }
        .accessibilityLabel("Drop an app here to uninstall it")
    }
}

private struct AppInspector: View {
    let app: InstalledApp
    let uninstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: app.name).font(.title3.weight(.semibold))
                    if let bid = app.bundleID { Text(verbatim: bid).font(.system(.caption, design: .monospaced)).foregroundStyle(.kmFgMuted).lineLimit(2).truncationMode(.middle) }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Size").foregroundStyle(.kmFgMuted); Text(app.bytes.map(Format.bytes) ?? "…") }
                GridRow { Text("Last used").foregroundStyle(.kmFgMuted); Text(app.lastUsed.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? String(localized: "Unknown")) }
                if let v = app.version { GridRow { Text("Version").foregroundStyle(.kmFgMuted); Text(verbatim: v) } }
            }
            .tabular()
            Button("Uninstall…", action: uninstall).buttonStyle(.kmPrimary)
            Button("Reveal in Finder") { FileActions.reveal([app.path]) }
        }
    }
}

extension InstalledApp {
    var sortBytes: Int64 { bytes ?? -1 }
    var sortLastUsed: Date { lastUsed ?? .distantPast }
}

/// S12: everything that will be removed with an app, previewed and checkable.
struct UninstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let app: InstalledApp
    @State private var files: [RelatedFile]?
    @State private var excluded: Set<String> = []
    @State private var running = false
    @State private var outcome: [RemovalOutcome]?
    @State private var working = false

    private var inTrash: Bool { PathGuard.isWithin(app.path, NSHomeDirectory() + "/.Trash") }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(inTrash ? "Clean up after \(app.name)?" : "Uninstall \(app.name)?").font(.title3.weight(.semibold))
            if let outcome {
                result(outcome)
            } else {
                if let bid = app.bundleID {
                    Text("Found by bundle ID \(bid) and the app’s name. Uncheck anything you want to keep.").foregroundStyle(.kmFgMuted)
                }
                if running {
                    HStack {
                        Text("\(app.name) is open. Quit it to uninstall it, so its files aren’t in use.")
                        Spacer()
                        Button("Quit \(app.name)") {
                            NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID ?? "").forEach { $0.terminate() }
                            Task { try? await Task.sleep(for: .seconds(1.5)); running = RunningApps.isRunning(appAt: app.path) }
                        }
                    }
                    .padding(10)
                    .background(.kmWarningSoft, in: RoundedRectangle(cornerRadius: 8))
                }
                if let files {
                    List {
                        if !inTrash {
                            Section("App") {
                                HStack { Toggle(isOn: .constant(true)) { PathText(path: app.path).foregroundStyle(.kmFg) }.toggleStyle(.checkbox).disabled(true).frame(minHeight: Metrics.rowHeight); Spacer(); Text(app.bytes.map(Format.bytes) ?? "").tabular() }
                            }
                        }
                        Section("Related files") {
                            if files.isEmpty {
                                Text("Only the app bundle was found.").foregroundStyle(.kmFgMuted)
                            }
                            ForEach(files) { f in
                                HStack {
                                    Toggle(isOn: Binding(get: { !excluded.contains(f.id) }, set: { on in if on { excluded.remove(f.id) } else { excluded.insert(f.id) } })) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            FileIdentity(name: (f.path as NSString).lastPathComponent, path: f.path)
                                            if f.isShared { Text("Shared with other apps from the same developer, unchecked").font(.caption).foregroundStyle(.kmWarning) }
                                            if f.needsHelper && !model.helper.isEnabled { Text("Needs the KeelMac helper").font(.caption).foregroundStyle(.kmFgMuted) }
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .disabled(f.needsHelper && !model.helper.isEnabled)
                                    Spacer()
                                    Text(Format.bytes(f.bytes)).tabular().foregroundStyle(.kmFgMuted)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .kmTableSurface()
                    .frame(minHeight: 260)
                } else {
                    ProgressView("Finding related files…").frame(maxWidth: .infinity, minHeight: 200)
                }
                HStack {
                    Text("Everything goes to the Trash and is logged.").foregroundStyle(.kmFgMuted)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button { uninstall() } label: { Text("Move \(Format.bytes(total)) to Trash") }
                        .buttonStyle(.kmPrimary)
                        .disabled(files == nil || running || working)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 680)
        .background(.kmBg)
        .task {
            running = !VisualFixtures.enabled && !inTrash && RunningApps.isRunning(appAt: app.path)
            let found = await model.apps.relatedFiles(for: app)
            excluded = Set(found.filter { $0.isShared || ($0.needsHelper && !model.helper.isEnabled) }.map(\.id))
            files = found
        }
    }

    private var chosen: [RelatedFile] { (files ?? []).filter { !excluded.contains($0.id) } }
    private var total: Int64 { (inTrash ? 0 : (app.bytes ?? 0)) + chosen.reduce(0) { $0 + $1.bytes } }

    private func uninstall() {
        working = true
        Task {
            outcome = await model.apps.uninstall(app, files: chosen)
            working = false
        }
    }

    @ViewBuilder private func result(_ out: [RemovalOutcome]) -> some View {
        let failed = out.filter { !$0.result.removedItem }
        Text("Moved \(Format.bytes(out.filter(\.result.removedItem).reduce(0) { $0 + $1.bytes })) to Trash.").tabular()
        if !failed.isEmpty {
            ForEach(failed) { o in
                HStack { PathText(path: o.path); Spacer(); Text(LocalizedStringKey(o.reason ?? "")).foregroundStyle(.kmWarning) }
            }
        }
        HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.kmPrimary).keyboardShortcut(.defaultAction) }
    }
}
