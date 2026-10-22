import SafetyKit
import ScanKit
import QuickLook
import SwiftUI

/// S6: large files filtered by size and by when they were last opened (C9, C11).
struct LargeOldView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("largeMinBytes") private var minBytes = 500_000_000
    @AppStorage("largeMonths") private var months = 3
    @State private var files: [LargeFile] = []
    @State private var loading = false
    @State private var selection: Set<String> = []
    @State private var confirm = false
    @State private var quickLook: URL?

    var body: some View {
        VStack(spacing: 0) {
            if model.storage.tree == nil {
                if model.storage.phase == .scanning {
                    ScanProgressView(progress: model.storage.progress) { model.storage.cancel() }
                } else {
                    EmptyStateView(symbol: "doc.badge.clock", title: "Scan first", message: "Large and old files come from the storage scan.",
                                   actionTitle: "Scan disk") { model.storage.scan() }
                }
            } else if loading && files.isEmpty {
                ProgressView("Checking when each file was last opened…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "Nothing matches these filters",
                               message: "No files over \(Format.bytes(Int64(minBytes))) that you haven’t opened in \(months) months.")
            } else {
                Table(files, selection: $selection) {
                    TableColumn("Name") { f in
                        Text(verbatim: (f.path as NSString).lastPathComponent).lineLimit(1)
                    }
                    TableColumn("Where") { f in PathText(path: (f.path as NSString).deletingLastPathComponent) }
                    TableColumn("Size") { f in Text(Format.bytes(f.bytes)).tabular().frame(maxWidth: .infinity, alignment: .trailing) }.width(90)
                    TableColumn("Last opened") { f in
                        Text(f.lastOpened.map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "Never"))
                            .tabular().frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(120)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Reveal in Finder") { FileActions.reveal(Array(ids)) }
                    Button("Quick Look") { quickLook = ids.first.map { URL(fileURLWithPath: $0) } }
                } primaryAction: { ids in
                    if let p = ids.first { FileActions.reveal([p]) }
                }
                ActionBar {
                    Text("\(selection.count) selected, \(Format.bytes(selectedBytes)). Last opened comes from Spotlight, or the last access date when Spotlight doesn’t know.")
                        .lineLimit(1)
                } trailing: {
                    Button("Reveal in Finder") { FileActions.reveal(Array(selection)) }.disabled(selection.isEmpty)
                    Button("Quick Look") { quickLook = selection.first.map { URL(fileURLWithPath: $0) } }.disabled(selection.isEmpty)
                    Button { confirm = true } label: { RemoveLabel(bytes: selectedBytes) }
                        .buttonStyle(.kmPrimary).disabled(selection.isEmpty)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Larger than", selection: $minBytes) {
                    Text("Larger than 100 MB").tag(100_000_000)
                    Text("Larger than 500 MB").tag(500_000_000)
                    Text("Larger than 1 GB").tag(1_000_000_000)
                }
                .fixedSize()
            }
            ToolbarItem {
                Picker("Not opened for", selection: $months) {
                    Text("Opened any time").tag(0)
                    Text("Not opened for 3 months").tag(3)
                    Text("Not opened for 6 months").tag(6)
                    Text("Not opened for 1 year").tag(12)
                }
                .fixedSize()
            }
        }
        .quickLookPreview($quickLook, in: selection.map { URL(fileURLWithPath: $0) })
        .task(id: "\(minBytes)-\(months)-\(model.storage.tree?.scannedAt.timeIntervalSince1970 ?? 0)") { await reload() }
        .confirmationDialog(Text("Move \(selection.count) files (\(Format.bytes(selectedBytes))) to the Trash?"), isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { trash() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var selectedBytes: Int64 { files.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.bytes } }

    private func reload() async {
        guard let tree = model.storage.tree else { return }
        loading = true
        let cutoff = months == 0 ? nil : Calendar.current.date(byAdding: .month, value: -months, to: Date())
        let min = Int64(minBytes)
        files = await Task.detached(priority: .userInitiated) { LargeFileFinder.find(in: tree, minBytes: min, notOpenedSince: cutoff) }.value
        selection = selection.intersection(files.map(\.id))
        loading = false
    }

    private func trash() {
        let chosen = files.filter { selection.contains($0.id) }
        Task {
            let out = await FileActions.remove(chosen.map { RemovalRequest(path: $0.path, bytes: $0.bytes, expectedModificationDate: $0.modified) },
                                               context: .userFile, kind: .trashFile, title: String(localized: "Trash file"), log: model.operationLog)
            let removed = Set(out.filter(\.result.removedItem).map(\.path))
            files.removeAll { removed.contains($0.path) }
            selection.subtract(removed)
            if let refused = out.first(where: { !$0.result.removedItem })?.reason { model.notice = refused }
            if !removed.isEmpty { model.storage.refresh(after: Array(removed)) }
        }
    }
}

/// S7: the folders behind macOS's "System Data" (C10).
struct SystemDataView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let storage = model.storage
        Group {
            if let items = storage.systemData {
                let measured = items.compactMap(\.bytes).reduce(0, +)
                let largest = max(1, items.compactMap(\.bytes).max() ?? 1)
                List {
                    Section {
                        Text("“System Data” is everything macOS can’t put in another category. These are the folders behind it. Some are safe to clean in Cleanup; others macOS manages and you should leave alone.")
                            .foregroundStyle(.kmFgMuted)
                        Text("KeelMac measured \(Format.bytes(measured)) in these folders.").tabular()
                    }
                    Section {
                        ForEach(items.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }) { item in
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.kind.title).fontWeight(.semibold)
                                    PathText(path: item.paths.first ?? "")
                                    Text(item.kind.explanation).font(.callout).foregroundStyle(.kmFgMuted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .trailing, spacing: 6) {
                                    if let b = item.bytes {
                                        Text(Format.bytes(b)).tabular()
                                        if b > 0 { Capsule().fill(.kmWater).frame(width: max(4, 140 * CGFloat(Double(b) / Double(largest))), height: 6) }
                                    } else if item.needsFullDiskAccess {
                                        Text("Needs Full Disk Access").foregroundStyle(.kmWarning)
                                    } else {
                                        Text("–").foregroundStyle(.kmFgMuted)
                                    }
                                }
                                .frame(width: 160, alignment: .trailing)
                                if item.cleanupCategory != nil {
                                    Button("Cleanup") { model.route = .cleanup }.buttonStyle(.link).foregroundStyle(.kmAccentText).frame(width: 100)
                                } else if item.kind == .localSnapshots {
                                    Button("Maintenance") { model.route = .maintenance }.buttonStyle(.link).foregroundStyle(.kmAccentText).frame(width: 100)
                                } else if let p = item.paths.first, item.kind != .localSnapshots {
                                    Button("Reveal") { FileActions.reveal([p]) }.frame(width: 100)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Measuring the folders macOS counts as System Data…").foregroundStyle(.kmFgMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem { Button("Measure again") { Task { await storage.measureSystemData() } }.disabled(storage.measuringSystemData) }
        }
        .task { if storage.systemData == nil { await storage.measureSystemData() } }
    }
}

extension SystemDataKind {
    var title: LocalizedStringKey {
        switch self {
        case .simulators: "iOS Simulators"
        case .localSnapshots: "Local Time Machine snapshots"
        case .swap: "Swap and sleep image"
        case .appCaches: "App caches"
        case .temporaryFiles: "Temporary files"
        case .systemCaches: "System caches"
        case .logs: "Logs and diagnostics"
        case .iosBackups: "iPhone and iPad backups"
        case .xcode: "Xcode data"
        case .mailDownloads: "Mail downloads"
        case .other: "Other"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .simulators: "Simulator devices and runtimes. Unavailable devices can be removed in Cleanup."
        case .localSnapshots: "macOS deletes these when it needs space. You can thin them in Maintenance."
        case .swap: "Managed by macOS. Shrinks after a restart."
        case .appCaches: "Rebuilt by apps as needed. Listed in Cleanup."
        case .temporaryFiles: "Per-app temporary items. macOS clears them on restart."
        case .systemCaches: "Shared caches. Cleaning them needs the helper."
        case .logs: "Old logs and crash reports. Listed in Cleanup."
        case .iosBackups: "Backups of your iPhone and iPad. Old ones are listed in Cleanup."
        case .xcode: "DerivedData, archives and device support. Listed in Cleanup."
        case .mailDownloads: "Attachments you opened from Mail."
        case .other: "Everything else macOS counts here."
        }
    }
}
