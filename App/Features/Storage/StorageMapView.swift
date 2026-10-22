import SafetyKit
import ScanKit
import QuickLook
import SwiftUI

/// S5: treemap or sunburst of the startup disk, drill-down, selection inspector and file actions.
struct StorageMapView: View {
    @Environment(AppModel.self) private var model
    @State private var focus: NodeID?
    @State private var selection: NodeID?
    @AppStorage("storageView") private var mode: MapMode = .treemap
    @State private var confirmTrash = false
    @State private var quickLook: URL?
    @AppStorage("mapHighlight") private var highlightMode: HighlightMode = .none
    @AppStorage(ReviewKindFilter.storageKey) private var reviewKind = ReviewKindFilter.all
    @AppStorage("reviewMonths") private var reviewMonths = 6
    @State private var highlightItems: [ReviewItem] = []
    @State private var highlight: MapHighlight?

    enum MapMode: String { case treemap, sunburst }

    /// What the map lights up: review candidates of one kind, or anything not opened in 6 months.
    enum HighlightMode: String, CaseIterable {
        case none, stale, aiModel, video, archive, document

        var kind: FileKind? { FileKind(rawValue: rawValue) }

        var title: LocalizedStringKey {
            switch self {
            case .none: "No highlight"
            case .stale: "Not opened in 6 months"
            case .aiModel: "AI models"
            case .video: "Video"
            case .archive: "Archives and disk images"
            case .document: "Documents"
            }
        }
    }

    private var storage: StorageModel { model.storage }

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess, let tree = storage.tree, !tree.unreadable.isEmpty {
                PermissionBanner(title: "\(tree.unreadable.count) folders were skipped.", message: "KeelMac needs Full Disk Access to measure them.",
                                 actionTitle: "Open Privacy & Security") { model.openFullDiskAccessSettings() }
            }
            content
        }
        .toolbar { toolbar }
        .onAppear { storage.loadCache() }
        .task(id: "\(highlightMode.rawValue)-\(storage.tree?.scannedAt.timeIntervalSince1970 ?? 0)") { await loadHighlight() }
        .quickLookPreview($quickLook)
        .confirmationDialog(trashTitle, isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { trashSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can put it back from the Trash. KeelMac logs it in the operation log.")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let tree = storage.tree, let root = focus ?? Optional(tree.root) {
                Breadcrumb(tree: tree, node: root) { focus = $0; selection = nil }
            }
        }
        ToolbarItem {
            Picker("Highlight", selection: $highlightMode) {
                ForEach(HighlightMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .disabled(storage.tree == nil)
            .help("Light up big files worth reviewing")
        }
        ToolbarItem {
            Picker("View", selection: $mode) {
                Text("Treemap").tag(MapMode.treemap)
                Text("Sunburst").tag(MapMode.sunburst)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(storage.tree == nil)
        }
        ToolbarItem {
            if storage.phase == .scanning {
                Button("Cancel scan") { storage.cancel() }
            } else {
                Button(storage.tree == nil ? "Scan disk" : "Rescan") { storage.scan() }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if storage.phase == .scanning && storage.tree == nil {
            ScanProgressView(progress: storage.progress) { storage.cancel() }
        } else if let tree = storage.tree {
            let current = focus ?? tree.root
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        switch mode {
                        case .treemap:
                            TreemapView(tree: tree, root: current, selection: $selection, highlight: highlight) { open($0, tree: tree) }
                        case .sunburst:
                            SunburstView(tree: tree, root: current, selection: $selection, highlight: highlight) { open($0, tree: tree) }
                        }
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.escape) { goUp(tree); return .handled }
                    .onKeyPress(.return) { if let s = selection { open(s, tree: tree) }; return .handled }
                    .onKeyPress(.rightArrow) { move(1, tree: tree, in: current); return .handled }
                    .onKeyPress(.downArrow) { move(1, tree: tree, in: current); return .handled }
                    .onKeyPress(.leftArrow) { move(-1, tree: tree, in: current); return .handled }
                    .onKeyPress(.upArrow) { move(-1, tree: tree, in: current); return .handled }
                    .accessibilityRepresentation { accessibilityList(tree: tree, root: current) }
                    HStack {
                        if highlight != nil {
                            Text("\(Format.bytes(highlightItems.reduce(0) { $0 + $1.bytes })) highlighted in \(highlightItems.count) items")
                                .font(.callout.weight(.semibold)).tabular()
                            Button("Review them") { reviewHighlighted() }.buttonStyle(.link).font(.callout)
                        } else {
                            Text("Click a block to select it, double-click to open it. Arrow keys move the selection, Return opens, Escape goes up.")
                                .font(.callout).foregroundStyle(.kmFgMuted)
                        }
                        Spacer()
                        if storage.phase == .scanning {
                            ProgressView().controlSize(.small)
                            Text("Rescanning…").font(.callout).foregroundStyle(.kmFgMuted)
                        } else {
                            Text("Scanned \(tree.scannedAt.formatted(.relative(presentation: .named))), \(tree.totalFileCount.formatted()) files")
                                .font(.callout).foregroundStyle(.kmFgMuted).tabular()
                        }
                    }
                }
                .padding(16)
                Divider()
                Inspector(tree: tree, node: selection ?? current,
                          onReveal: { FileActions.reveal([$0]) },
                          onQuickLook: { quickLook = URL(fileURLWithPath: $0) },
                          onTrash: { confirmTrash = true },
                          onRescan: { storage.rescan(folder: $0) })
                    .frame(width: 280)
            }
        } else if case .failed(let message) = storage.phase {
            EmptyStateView(symbol: "exclamationmark.triangle", title: "The scan stopped", message: LocalizedStringKey(message), actionTitle: "Scan again") { storage.scan(full: true) }
        } else {
            EmptyStateView(symbol: "square.grid.3x3.square", title: "See what fills Macintosh HD",
                           message: "A full scan takes about a minute and never reads file contents. After that, rescans only look at folders that changed.",
                           actionTitle: "Scan disk") { storage.scan() }
        }
    }

    private func loadHighlight() async {
        guard highlightMode != .none, let tree = storage.tree else { highlight = nil; highlightItems = []; return }
        let mode = highlightMode
        let cutoff = mode == .stale ? Calendar.current.date(byAdding: .month, value: -6, to: Date()) : nil
        let home = NSHomeDirectory()
        let (items, lit) = await Task.detached(priority: .userInitiated) {
            let items = ReviewFinder.find(in: tree, home: home, minBytes: 100_000_000, notOpenedSince: cutoff)
                .filter { mode.kind == nil || $0.kind == mode.kind }
            return (items, MapHighlight(items: items, tree: tree))
        }.value
        guard mode == highlightMode else { return }
        highlightItems = items
        highlight = lit
    }

    /// Opens Review with the same kind (and, for "not opened in 6 months", the same age filter).
    private func reviewHighlighted() {
        reviewKind = highlightMode.kind?.rawValue ?? ReviewKindFilter.all
        if highlightMode == .stale { reviewMonths = 6 }
        model.route = .largeOld
    }

    private func open(_ id: NodeID, tree: ScanTree) {
        if tree.isDirectory(id) && tree.childCount(of: id) > 0 { focus = id; selection = nil }
        else { selection = id }
    }

    private func goUp(_ tree: ScanTree) {
        guard let f = focus, let p = tree.parent(of: f) else { return }
        selection = f
        focus = p == tree.root ? nil : p
    }

    private func move(_ delta: Int, tree: ScanTree, in parent: NodeID) {
        let kids = tree.children(of: parent)
        guard !kids.isEmpty else { return }
        let i = selection.flatMap { kids.firstIndex(of: $0) } ?? -1
        selection = kids[max(0, min(kids.count - 1, i + delta))]
    }

    private func accessibilityList(tree: ScanTree, root: NodeID) -> some View {
        List(tree.children(of: root).prefix(10), id: \.self) { id in
            Text(verbatim: "\(tree.name(of: id)), \(Format.bytes(tree.bytes(of: id)))")
        }
    }

    private var trashTitle: Text {
        guard let tree = storage.tree, let s = selection else { return Text(verbatim: "") }
        return Text("Move “\(tree.name(of: s))” (\(Format.bytes(tree.bytes(of: s)))) to the Trash?")
    }

    private func trashSelection() {
        guard let tree = storage.tree, let s = selection else { return }
        let info = tree.info(s)
        Task {
            let out = await FileActions.remove([RemovalRequest(path: info.path, bytes: info.bytes)], context: .userFile, kind: .trashFile,
                                               title: String(localized: "Trash file"), log: model.operationLog)
            if out.first?.result.removedItem == true {
                selection = nil
                storage.refresh(after: [info.path])
            } else if let reason = out.first?.reason {
                model.notice = reason
            }
        }
    }
}

struct ScanProgressView: View {
    let progress: ScanProgress?
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Scanning Macintosh HD…").fontWeight(.semibold)
                Spacer()
                if let p = progress { Text(Duration.seconds(p.elapsed).formatted(.units(allowed: [.minutes, .seconds], width: .narrow))).tabular().foregroundStyle(.kmFgMuted) }
            }
            ProgressView().progressViewStyle(.linear)
            if let p = progress {
                Text("\(p.filesCounted.formatted()) files, \(Format.bytes(p.bytesCounted)) counted").foregroundStyle(.kmFgMuted).tabular()
                Text(verbatim: (p.currentPath as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.kmFgMuted).lineLimit(1).truncationMode(.middle)
                if p.unreadableCount > 0 {
                    Text("\(p.unreadableCount) folders skipped without Full Disk Access").font(.callout).foregroundStyle(.kmWarning)
                }
            }
            HStack { Spacer(); Button("Cancel scan", action: cancel) }
        }
        .frame(maxWidth: 560)
        .kmGroup(padding: 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Breadcrumb: View {
    let tree: ScanTree
    let node: NodeID
    let go: (NodeID?) -> Void

    var body: some View {
        HStack(spacing: 4) {
            let chain = tree.ancestors(of: node) + [node]
            ForEach(Array(chain.enumerated()), id: \.offset) { i, id in
                if i > 0 { Text(verbatim: "/").foregroundStyle(.kmFgMuted) }
                if id == node {
                    Text(verbatim: tree.name(of: id)).fontWeight(.semibold)
                } else {
                    Button(tree.name(of: id)) { go(id == tree.root ? nil : id) }.buttonStyle(.link)
                }
            }
            Text(Format.bytes(tree.bytes(of: node))).foregroundStyle(.kmFgMuted).tabular().padding(.leading, 6)
        }
        .lineLimit(1)
    }
}

private struct Inspector: View {
    let tree: ScanTree
    let node: NodeID
    let onReveal: (String) -> Void
    let onQuickLook: (String) -> Void
    let onTrash: () -> Void
    let onRescan: (String) -> Void

    var body: some View {
        let info = tree.info(node)
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: info.name).font(.title3.weight(.semibold)).lineLimit(2)
            Text(verbatim: (info.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.kmFgMuted).textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Size").foregroundStyle(.kmFgMuted); Text(Format.bytes(info.bytes)) }
                if info.isDirectory { GridRow { Text("Items").foregroundStyle(.kmFgMuted); Text("\(info.fileCount.formatted()) files") } }
                GridRow { Text("Modified").foregroundStyle(.kmFgMuted); Text(info.modified.formatted(date: .abbreviated, time: .shortened)) }
            }
            .tabular()
            if info.isUnreadable {
                Text("KeelMac couldn’t read this folder. Turn on Full Disk Access to measure it.").font(.callout).foregroundStyle(.kmWarning)
            }
            if node != tree.root {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Reveal in Finder") { onReveal(info.path) }
                    Button("Quick Look") { onQuickLook(info.path) }
                    if info.isDirectory { Button("Rescan this folder") { onRescan(info.path) } }
                    Button("Move to Trash…", action: onTrash)
                        .disabled(!FileActions.pathGuard().verdict(for: info.path, context: .userFile).allowed)
                }
                .controlSize(.large)
                if let reason = FileActions.pathGuard().verdict(for: info.path, context: .userFile).reason {
                    Text(LocalizedStringKey(reason.englishDescription)).font(.callout).foregroundStyle(.kmFgMuted)
                }
            }
            Spacer()
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
