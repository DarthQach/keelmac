import SafetyKit
import ScanKit
import QuickLook
import SwiftUI

struct StorageMapView: View {
    @Environment(AppModel.self) private var model
    @State private var focus: NodeID?
    @State private var selection: MapItem?
    @State private var hovered: MapItem?
    @State private var expanded: Set<NodeID> = []
    @State private var location = MapLocation()
    @State private var treeKey: String?
    @State private var showContentsRequest = 0
    @AppStorage("storageView") private var savedMode: MapMode = .treemap
    @State private var fixtureMode: MapMode = .treemap
    private var mode: MapMode { VisualFixtures.enabled ? fixtureMode : savedMode }
    private var modeBinding: Binding<MapMode> {
        Binding(get: { mode }, set: { if VisualFixtures.enabled { fixtureMode = $0 } else { savedMode = $0 } })
    }
    @State private var confirmTrash = false
    @State private var quickLook: URL?
    @AppStorage("mapHighlight") private var highlightMode: HighlightMode = .none
    @AppStorage(ReviewKindFilter.storageKey) private var reviewKind = ReviewKindFilter.all
    @AppStorage("reviewMonths") private var reviewMonths = 6
    @State private var highlightItems: [ReviewItem] = []
    @State private var highlight: MapHighlight?

    enum MapMode: String { case treemap, sunburst }
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
            if let tree = storage.tree {
                if treeKey == KindShares.key(for: tree) { workspace(tree: tree) }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else if storage.phase == .scanning {
                ScanProgressView(progress: storage.progress) { storage.cancel() }
            } else if case .failed(let message) = storage.phase {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "The scan stopped", message: LocalizedStringKey(message), actionTitle: "Scan again") { storage.scan(full: true) }
            } else {
                EmptyStateView(symbol: "square.grid.3x3.square", title: "See what fills Macintosh HD",
                               message: "A full scan takes about a minute and never reads file contents. After that, rescans only look at folders that changed.",
                               actionTitle: "Scan disk") { storage.scan() }
            }
        }
        .toolbar { toolbar }
        .onAppear { storage.loadCache() }
        .onChange(of: selection) { _, _ in rememberLocation() }
        .onChange(of: storage.tree.map(KindShares.key(for:)), initial: true) { _, _ in
            guard let tree = storage.tree else { return }
            let restored = location.resolve(in: tree)
            focus = restored.focus
            selection = restored.selection.map(MapItem.node)
            hovered = nil
            expanded = []
            if let node = restored.selection, let parent = tree.parent(of: node), parent != restored.focus { expanded.insert(parent) }
            treeKey = KindShares.key(for: tree)
            rememberLocation()
        }
        .onChange(of: mode) { _, _ in hovered = nil }
        .task(id: "\(highlightMode.rawValue)-\(storage.tree?.scannedAt.timeIntervalSince1970 ?? 0)") { await loadHighlight() }
        .task(id: storage.tree.map(KindShares.key(for:))) { await storage.updateKindShares() }
        .quickLookPreview($quickLook)
        .confirmationDialog(trashTitle, isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { trashSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can put it back from the Trash. KeelMac logs it in the operation log.")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("View", selection: modeBinding) {
                Text("Treemap").tag(MapMode.treemap)
                Text("Sunburst").tag(MapMode.sunburst)
            }
            .pickerStyle(.segmented).fixedSize().tint(.kmControlAccent)
            .disabled(storage.tree == nil)
        }
        ToolbarItem {
            if storage.phase == .scanning { Button("Cancel scan") { storage.cancel() } }
            else { Button(storage.tree == nil ? "Scan disk" : "Rescan") { storage.scan() } }
        }
    }

    private func workspace(tree: ScanTree) -> some View {
        let current = focus ?? tree.root
        return VStack(spacing: 0) {
            MapBreadcrumb(tree: tree, node: current, go: { navigate($0, tree: tree) }, up: { goUp(tree) })
                .padding(.horizontal, Metrics.pagePadding).padding(.bottom, 16)
            GeometryReader { geo in
                let width = max(0, geo.size.width - Metrics.pagePadding * 2)
                let height = max(380, min(540, geo.size.height - 100))
                ScrollViewReader { proxy in
                  ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if width >= 1000 {
                            HStack(alignment: .top, spacing: 16) {
                                mapPanel(tree: tree, current: current).frame(width: (width - 16) * 0.6, height: height)
                                contents(tree: tree, current: current).frame(maxWidth: .infinity).frame(height: height).id("storage.contents.panel")
                            }
                        } else {
                            mapPanel(tree: tree, current: current).frame(height: 360)
                            contents(tree: tree, current: current).frame(height: 340).id("storage.contents.panel")
                        }
                        selectionDetails(tree: tree, current: current)
                    }
                    .padding(.horizontal, Metrics.pagePadding).padding(.bottom, 24)
                  }
                  .onChange(of: showContentsRequest) { _, _ in proxy.scrollTo("storage.contents.panel", anchor: .top) }
                }
            }
            actionBar(tree: tree, current: current)
        }
    }

    private func contents(tree: ScanTree, current: NodeID) -> some View {
        MapContentsList(tree: tree, root: current, selection: $selection, expanded: $expanded,
                        open: { open($0, tree: tree) }, goUp: { goUp(tree) }, colors: storage.kindShares)
    }

    private func mapPanel(tree: ScanTree, current: NodeID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let hovered {
                        Text(verbatim: hovered.name(in: tree)).font(.callout.weight(.semibold)).lineLimit(1)
                        Text("\(Format.bytes(hovered.bytes(in: tree))) · \(share(hovered, tree: tree, current: current)) of this folder")
                            .font(.caption).foregroundStyle(.kmFgMuted).tabular().lineLimit(1)
                    } else {
                        Text("Explore this folder").font(.callout.weight(.semibold))
                        Text("Select an item · double-click a folder to open").font(.caption).foregroundStyle(.kmFgMuted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker("Highlight", selection: $highlightMode) {
                    ForEach(HighlightMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize().accessibilityLabel("Highlight")
            }
            .frame(height: 36)
            Group {
                if tree.bytes(of: current) == 0 {
                    VStack(spacing: 12) {
                        Image(systemName: "folder").font(.largeTitle).foregroundStyle(.kmFgMuted)
                        Text(tree.info(current).isUnreadable ? "This folder needs access to be measured." : "This folder has no measured size.")
                            .foregroundStyle(.kmFgMuted)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if mode == .treemap {
                    TreemapView(tree: tree, root: current, selection: $selection, hovered: $hovered, highlight: highlight, colors: storage.kindShares) { open($0, tree: tree) }
                } else {
                    SunburstView(tree: tree, root: current, selection: $selection, hovered: $hovered, highlight: highlight, colors: storage.kindShares) { open($0, tree: tree) }
                }
            }
            .focusable().focusEffectDisabled()
            .onKeyPress(.escape) { goUp(tree); return .handled }
            .onKeyPress(.return) { if let node = selection?.node { open(node, tree: tree) }; return .handled }
            .onKeyPress(.downArrow) { move(1, tree: tree, current: current); return .handled }
            .onKeyPress(.rightArrow) { move(1, tree: tree, current: current); return .handled }
            .onKeyPress(.upArrow) { move(-1, tree: tree, current: current); return .handled }
            .onKeyPress(.leftArrow) { move(-1, tree: tree, current: current); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Storage visualization")
            .accessibilityHint("Use the contents list to browse every item.")
            .accessibilityIdentifier("storage.map")
            HStack(spacing: 8) {
                if highlight != nil {
                    Text("\(Format.bytes(highlightItems.reduce(0) { $0 + $1.bytes })) highlighted in \(highlightItems.count) items across the entire scan")
                        .font(.caption).foregroundStyle(.kmFgMuted).tabular()
                    Button("Review them") { reviewHighlighted() }.buttonStyle(.link).font(.caption)
                } else {
                    Menu {
                        ForEach(MapColorGroup.allCases, id: \.self) { group in
                            Button { highlightMode = group.highlight } label: {
                                Label { Text(group.title) } icon: { Image(systemName: group == .document ? "doc" : "circle.fill").foregroundStyle(group.color ?? Color.kmFgMuted) }
                            }
                        }
                    } label: { Label("File kinds", systemImage: "circle.grid.2x2") }
                    .menuStyle(.borderlessButton).fixedSize().font(.caption)
                    Spacer(minLength: 0)
                    Text("Two folder levels").font(.caption).foregroundStyle(.kmFgMuted)
                }
            }
        }
        .padding(16).kmTableSurface()
    }

    private func selectionDetails(tree: ScanTree, current: NodeID) -> some View {
        let item = selection ?? .node(current)
        let info = tree.info(item.container)
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: tree.path(of: item.container)).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.kmFgMuted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if item.node == nil {
                Text(item == .small(item.container)
                     ? "These small files are measured together. Individual names are not stored in this scan. Reveal the containing folder to inspect them."
                     : "These named items are too small to label on the map. They are highlighted in the contents list; select a row to inspect an individual item.")
                    .font(.callout).foregroundStyle(.kmFgMuted)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { metadata(info) }
                    VStack(alignment: .leading, spacing: 8) { metadata(info) }
                }
                if info.isUnreadable { Text("KeelMac couldn’t read this folder. Turn on Full Disk Access to measure it.").font(.callout).foregroundStyle(.kmWarningInk) }
                if let reason = FileActions.pathGuard().verdict(for: info.path, context: .userFile).reason {
                    Text(LocalizedStringKey(reason.englishDescription)).font(.caption).foregroundStyle(.kmFgMuted)
                }
            }
            if storage.phase == .scanning {
                HStack { ProgressView().controlSize(.small); Text("Rescanning…").font(.caption) }
            } else {
                Text("Scanned \(tree.scannedAt.formatted(.relative(presentation: .named))), \(tree.totalFileCount.formatted()) files")
                    .font(.caption).foregroundStyle(.kmFgMuted).tabular()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).kmGroup()
    }

    @ViewBuilder private func metadata(_ info: ScanNodeInfo) -> some View {
        if info.isDirectory { Text("\(info.fileCount.formatted()) files").font(.callout).tabular() }
        Text("Modified \(info.modified.formatted(date: .abbreviated, time: .shortened))").font(.callout).foregroundStyle(.kmFgMuted)
    }

    private func actionBar(tree: ScanTree, current: NodeID) -> some View {
        let item = selection ?? .node(current)
        return ActionBar {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.name(in: tree)).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)

                Text("\(Format.bytes(item.bytes(in: tree))) · \(share(item, tree: tree, current: current)) of this folder")
                    .font(.caption).foregroundStyle(.kmFgMuted)
            }
            .frame(maxWidth: 480, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: item.name(in: tree)))
            .accessibilityValue(Text(verbatim: "\(Format.bytes(item.bytes(in: tree))), \(share(item, tree: tree, current: current))"))
            .accessibilityIdentifier("storage.selection")
        } trailing: {
            if selection != nil {
                Button("Show in list") { showContentsRequest += 1 }
                    .fixedSize().accessibilityIdentifier("storage.showContents")
            }
            if let node = item.node, tree.isDirectory(node), node != current {
                Button("Open folder") { open(node, tree: tree) }.accessibilityIdentifier("storage.open").buttonStyle(.kmPrimary).keyboardShortcut(.return, modifiers: []).fixedSize()
            }
            Menu("Actions") {
                Button(item.node == nil ? "Reveal containing folder" : "Reveal in Finder") { FileActions.reveal([tree.path(of: item.container)]) }
                if let node = item.node {
                    Button("Quick Look") { quickLook = URL(fileURLWithPath: tree.path(of: node)) }
                    if tree.isDirectory(node) { Button("Rescan this folder") { storage.rescan(folder: tree.path(of: node)) } }
                    if node != tree.root {
                        Divider()
                        Button("Move to Trash…", role: .destructive) { selection = item; confirmTrash = true }
                            .disabled(!FileActions.pathGuard().verdict(for: tree.path(of: node), context: .userFile).allowed)
                    }
                }
            }
            .fixedSize().accessibilityIdentifier("storage.actions")
        }
    }

    private func share(_ item: MapItem, tree: ScanTree, current: NodeID) -> String {
        Format.percent(tree.bytes(of: current) > 0 ? Double(item.bytes(in: tree)) / Double(tree.bytes(of: current)) : 0, digits: 1)
    }
    private func rememberLocation() {
        guard let tree = storage.tree, treeKey == KindShares.key(for: tree) else { return }
        location = MapLocation(focusPath: tree.path(of: focus ?? tree.root), selectionPath: selection?.node.map(tree.path(of:)))
    }
    private func navigate(_ node: NodeID, tree: ScanTree) {
        focus = node; selection = nil; hovered = nil; expanded = []; rememberLocation()
    }
    private func open(_ node: NodeID, tree: ScanTree) {
        if tree.isDirectory(node) { navigate(node, tree: tree) } else { selection = .node(node) }
    }
    private func goUp(_ tree: ScanTree) {
        guard let current = focus, let parent = tree.parent(of: current) else { return }
        navigate(parent, tree: tree); selection = .node(current); rememberLocation()
    }
    private func move(_ delta: Int, tree: ScanTree, current: NodeID) {
        let rows = MapContentsList.rows(tree: tree, root: current, expanded: expanded)
        guard !rows.isEmpty else { return }
        let index = selection.flatMap { selected in rows.firstIndex { $0.item == selected } } ?? (delta > 0 ? -1 : rows.count)
        selection = rows[max(0, min(rows.count - 1, index + delta))].item
    }
    private var trashTitle: Text {
        guard let tree = storage.tree, let node = selection?.node else { return Text(verbatim: "") }
        return Text("Move “\(tree.name(of: node))” (\(Format.bytes(tree.bytes(of: node)))) to the Trash?")
    }
    private func trashSelection() {
        guard let tree = storage.tree, let node = selection?.node else { return }
        let info = tree.info(node)
        Task {
            let out = await FileActions.remove([RemovalRequest(path: info.path, bytes: info.bytes)], context: .userFile, kind: .trashFile,
                                               title: String(localized: "Trash file"), log: model.operationLog)
            if out.first?.result.removedItem == true {
                selection = nil
                storage.refresh(after: [info.path])
            } else if let reason = out.first?.reason { model.notice = reason }
        }
    }
    private func loadHighlight() async {
        guard !VisualFixtures.enabled else { return }
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

private struct MapBreadcrumb: View {
    let tree: ScanTree
    let node: NodeID
    let go: (NodeID) -> Void
    let up: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: tree.name(of: node)).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)

                Spacer()
                Text(Format.bytes(tree.bytes(of: node))).font(.title3).foregroundStyle(.kmFgMuted).tabular().fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: tree.name(of: node)))
            .accessibilityValue(Text(verbatim: Format.bytes(tree.bytes(of: node))))
            .accessibilityIdentifier("storage.folder")
            HStack(spacing: 8) {
                Button(action: up) { Image(systemName: "arrow.up").frame(width: 20) }
                    .keyboardShortcut(.escape, modifiers: []).disabled(node == tree.root).help("Up one folder").accessibilityLabel("Up one folder").accessibilityIdentifier("storage.up")
                ViewThatFits(in: .horizontal) {
                    trail(tree.ancestors(of: node) + [node])
                    HStack(spacing: 8) {
                        if node != tree.root {
                            Button { go(tree.root) } label: { Image(systemName: "internaldrive") }
                                .buttonStyle(.plain).accessibilityLabel(Text(verbatim: tree.name(of: tree.root)))
                            Menu {
                                ForEach(tree.ancestors(of: node), id: \.self) { id in Button(tree.name(of: id)) { go(id) } }
                            } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Parent folders")
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.kmFgMuted)
                        }
                        Text(verbatim: tree.name(of: node)).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.callout)
                Spacer(minLength: 0)
            }
        }
    }
    private func trail(_ nodes: [NodeID]) -> some View {
        HStack(spacing: 8) {
            ForEach(nodes, id: \.self) { id in
                if id != tree.root { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.kmFgMuted) }
                if id == node { Text(verbatim: tree.name(of: id)) }
                else { Button(tree.name(of: id)) { go(id) }.buttonStyle(.link) }
            }
        }.fixedSize()
    }
}
