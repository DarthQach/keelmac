import AppsKit
import SafetyKit
import ScanKit
import QuickLook
import SwiftUI

/// S6: big files and AI models worth reviewing, by kind, owner and when they were last opened (C9, C11).
struct LargeOldView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("largeMinBytes") private var minBytes = 500_000_000
    @AppStorage("reviewMonths") private var months = 6
    @AppStorage(ReviewKindFilter.storageKey) private var kindFilter = ReviewKindFilter.all
    @State private var rows: [ReviewRow] = []
    @State private var loading = false
    @State private var selection: Set<String> = []
    @State private var confirm = false
    @State private var quickLook: URL?

    private var shown: [ReviewRow] {
        kindFilter == ReviewKindFilter.all ? rows : rows.filter { $0.item.kind.rawValue == kindFilter }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.storage.tree == nil {
                if model.storage.phase == .scanning {
                    ScanProgressView(progress: model.storage.progress) { model.storage.cancel() }
                } else {
                    EmptyStateView(symbol: "doc.badge.clock", title: "Scan first", message: "The review comes from the storage scan.",
                                   actionTitle: "Scan disk") { model.storage.scan() }
                }
            } else if loading && rows.isEmpty {
                ProgressView("Checking when each file was last opened…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "Nothing matches these filters",
                               message: "No files over \(Format.bytes(Int64(minBytes))) that you haven’t opened in \(months) months.")
            } else {
                KindStrip(rows: rows, filter: $kindFilter)
                Divider()
                table
                ActionBar {
                    Text("\(selection.count) selected, \(Format.bytes(selectedBytes)). Locked rows belong to an app that is open; quit it to remove them.")
                        .fixedSize(horizontal: false, vertical: true)
                } trailing: {
                    Button("Reveal in Finder") { FileActions.reveal(selectedRows.map(\.item.path)) }.disabled(selection.isEmpty)
                    Button("Quick Look") { quickLook = selectedRows.first.map { URL(fileURLWithPath: $0.item.path) } }.disabled(selection.isEmpty)
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
        .quickLookPreview($quickLook, in: selectedRows.map { URL(fileURLWithPath: $0.item.path) })
        .task(id: "\(minBytes)-\(months)-\(model.storage.tree?.scannedAt.timeIntervalSince1970 ?? 0)") { await reload() }
        .onChange(of: selection) { _, new in
            let locked = Set(rows.filter(\.isLocked).map(\.id))
            if !new.isDisjoint(with: locked) { selection = new.subtracting(locked) }
        }
        .confirmationDialog(Text("Remove \(selection.count) items (\(Format.bytes(selectedBytes)))?"), isPresented: $confirm) {
            Button("Remove", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var table: some View {
        Table(shown, selection: $selection) {
            TableColumn("Name") { r in
                FileIdentity(name: r.item.name, path: (r.item.path as NSString).deletingLastPathComponent,
                             symbol: r.item.kind.symbol)
                    .opacity(r.isLocked ? 0.55 : 1)
            }.width(min: 220, ideal: 300)
            TableColumn("Size") { r in Text(Format.bytes(r.item.bytes)).tabular().frame(maxWidth: .infinity, alignment: .trailing) }.width(80)
            TableColumn("Last opened") { r in
                Text(r.item.lastOpened.map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "Never"))
                    .tabular().frame(maxWidth: .infinity, alignment: .trailing)
            }.width(110)
            TableColumn("Used by") { r in
                Text(verbatim: r.owner?.name ?? String(localized: "Your files")).lineLimit(1)
                    .foregroundStyle(r.owner == nil ? .kmFgMuted : .kmFg)
            }.width(min: 90, ideal: 110, max: 140)
            TableColumn("Status") { r in StatusText(status: r.status) }.width(min: 110, ideal: 140, max: 180)

        }
        .kmTableSurface()
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 16)
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Reveal in Finder") { FileActions.reveal(rows.filter { ids.contains($0.id) }.map(\.item.path)) }
            Button("Quick Look") { quickLook = rows.first { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.item.path) } }
        } primaryAction: { ids in
            if let r = rows.first(where: { ids.contains($0.id) }) { FileActions.reveal([r.item.path]) }
        }
    }

    private var selectedRows: [ReviewRow] { rows.filter { selection.contains($0.id) } }
    private var selectedBytes: Int64 { selectedRows.reduce(0) { $0 + $1.item.bytes } }

    private var confirmMessage: String {
        let recent = selectedRows.compactMap { r -> String? in
            if case .recentlyUsed(let app, let date) = r.status {
                return String(localized: "\(app) was used \(date.formatted(.relative(presentation: .named))).")
            }
            return nil
        }
        let base = String(localized: "Files go to the Trash, where you can put them back. Ollama models are removed with ollama rm and would need to be downloaded again.")
        return (Array(Set(recent)).sorted() + [base]).joined(separator: " ")
    }

    private func reload() async {
        if VisualFixtures.enabled { rows = VisualFixtures.state == "empty" ? [] : VisualFixtures.reviewRows; return }
        guard let tree = model.storage.tree else { return }
        loading = true
        let cutoff = months == 0 ? nil : Calendar.current.date(byAdding: .month, value: -months, to: Date())
        let min = Int64(minBytes)
        let home = NSHomeDirectory()
        rows = await Task.detached(priority: .userInitiated) {
            OwnerResolver.rows(for: ReviewFinder.find(in: tree, home: home, minBytes: min, notOpenedSince: cutoff))
        }.value
        selection = selection.intersection(rows.filter { !$0.isLocked }.map(\.id))
        loading = false
    }

    private func remove() {
        let chosen = selectedRows.filter { !$0.isLocked }
        let tree = model.storage.tree
        Task {
            var removed: [String] = []
            var notice: String?
            var requests: [RemovalRequest] = []
            for r in chosen {
                switch r.item.removal {
                case .trash(let paths):
                    requests += paths.map { p in
                        RemovalRequest(path: p, bytes: tree.flatMap { t in t.lookup(path: p).map(t.bytes(of:)) } ?? r.item.bytes)
                    }
                case .ollamaRemove(let name):
                    if let failure = await OllamaCLI.remove(r.item, model: name, runner: ProcessCommandRunner(), log: model.operationLog) {
                        notice = notice ?? failure
                    } else {
                        removed.append(r.item.path)
                    }
                }
            }
            if !requests.isEmpty {
                let out = await FileActions.remove(requests, context: .userFile, kind: .trashFile, title: String(localized: "Trash file"), log: model.operationLog)
                removed += out.filter(\.result.removedItem).map(\.path)
                if let refused = out.first(where: { !$0.result.removedItem })?.reason { notice = notice ?? refused }
            }
            if let notice { model.notice = notice }
            selection = []
            if !removed.isEmpty {
                model.storage.refresh(after: removed)
                await reload()
            }
        }
    }
}

/// The values stored for the kind filter (`all` or a `FileKind` raw value), shared with the map's Highlight.
enum ReviewKindFilter {
    static let storageKey = "reviewKind"
    static let all = "all"
}

/// One chip per kind with its total; clicking filters the list.
private struct KindStrip: View {
    let rows: [ReviewRow]
    @Binding var filter: String

    var body: some View {
        let totals = Dictionary(grouping: rows, by: \.item.kind).mapValues { $0.reduce(Int64(0)) { $0 + $1.item.bytes } }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: Text("All"), bytes: rows.reduce(0) { $0 + $1.item.bytes }, value: ReviewKindFilter.all, symbol: "square.stack")
                ForEach(FileKind.allCases.filter { totals[$0] != nil }.sorted { totals[$0]! > totals[$1]! }, id: \.self) { kind in
                    chip(title: Text(kind.title), bytes: totals[kind]!, value: kind.rawValue, symbol: kind.symbol)
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.vertical, 16)
        }
    }

    private func chip(title: Text, bytes: Int64, value: String, symbol: String) -> some View {
        let on = filter == value
        return Button { filter = value } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                title.fontWeight(.semibold)
                Text(Format.bytes(bytes)).tabular().foregroundStyle(on ? .kmOnAccent : .kmFgMuted)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(on ? .kmOnAccent : .kmFg)
            .background(on ? Color.kmAccent : Color.kmSurfaceMuted, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct StatusText: View {
    let status: ReviewStatus
    var body: some View {
        switch status {
        case .locked(let app):
            Label("\(app) is open", systemImage: "lock.fill").foregroundStyle(.kmWarning).lineLimit(1)
        case .recentlyUsed(let app, let date):
            Text("\(app) used \(date.formatted(.relative(presentation: .named)))").foregroundStyle(.kmFgMuted).lineLimit(1)
        case .free:
            Text(verbatim: "")
        }
    }
}

extension FileKind {
    var title: LocalizedStringKey {
        switch self {
        case .document: "Documents"
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Images"
        case .archive: "Archives and disk images"
        case .aiModel: "AI models"
        case .virtualMachine: "Virtual machines"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .document: "doc.text"
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .archive: "archivebox"
        case .aiModel: "cpu"
        case .virtualMachine: "desktopcomputer"
        case .other: "doc"
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
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.kind.title).fontWeight(.semibold)
                                    PathText(path: item.paths.first ?? "")
                                    Text(item.kind.explanation).font(.callout).foregroundStyle(.kmFgMuted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .trailing, spacing: 6) {
                                    if let b = item.bytes {
                                        Text(Format.bytes(b)).font(.title3.weight(.semibold)).tabular()
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
                            .padding(.vertical, 12)
                        }
                    }
                }
                .listStyle(.inset)
                .kmTableSurface()
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.bottom, Metrics.pagePadding)
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
