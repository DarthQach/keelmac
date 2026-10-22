import ReportKit
import SwiftUI

/// S17: weekly snapshots, "what grew" between two of them, Markdown export.
struct SnapshotsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: UUID?
    @State private var compareID: UUID?

    private var service: SnapshotService { model.snapshots }
    private var selected: SnapshotValue? { service.snapshots.first { $0.id == selectedID } ?? service.snapshots.first }
    private var compareTo: SnapshotValue? {
        guard let selected else { return nil }
        if let id = compareID, let s = service.snapshots.first(where: { $0.id == id }), s.date < selected.date { return s }
        return service.snapshots.first { $0.date < selected.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = service.loadError {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.kmDanger)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Couldn’t load snapshots").fontWeight(.semibold)
                        Text(verbatim: error).foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Try again") { Task { await service.load() } }
                }
                .kmGroup()
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.bottom, 16)
            }
            content
        }
        .toolbar {
            ToolbarItem {
                Button("Export report…", action: export).disabled(selected == nil)
            }
            ToolbarItem {
                Button("Take snapshot") { Task { await service.takeSnapshot() } }
                    .disabled(service.isTaking)
            }
        }
        .task { await service.load() }
    }

    private var content: some View {
        Group {
            if service.snapshots.isEmpty {
                if service.isTaking {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Taking a snapshot of your home folder…").foregroundStyle(.kmFgMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(symbol: "calendar.badge.clock", title: "No snapshots yet", message: "KeelMac takes one every week, so you can see what grew.",
                                   actionTitle: "Take snapshot") { Task { await service.takeSnapshot() } }
                }
            } else {
                HSplitView {
                    List(selection: Binding(get: { selected?.id }, set: { selectedID = $0 })) {
                        Section("Weekly, every Monday at 09:00") {
                            ForEach(service.snapshots) { s in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(s.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                                        .fontWeight(.semibold)
                                    Text("\(Format.bytes(s.volumeUsed)) used").font(.callout).foregroundStyle(.kmFgMuted).tabular()
                                }
                                .frame(minHeight: Metrics.detailRowHeight)
                                .tag(s.id)
                            }
                        }
                    }
                    .frame(minWidth: 200, idealWidth: 230, maxWidth: 280)
                    if let selected {
                        SnapshotDetail(current: selected, previous: compareTo, all: service.snapshots, compareID: $compareID)
                            .frame(minWidth: 400)
                    }
                }
            }
        }
    }

    private func export() {
        guard let selected else { return }
        let md = service.markdownReport(current: selected, previous: compareTo)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "KeelMac report \(selected.date.formatted(.iso8601.year().month().day())).md"
        if panel.runModal() == .OK, let url = panel.url { try? md.write(to: url, atomically: true, encoding: .utf8) }
    }
}

private struct SnapshotDetail: View {
    let current: SnapshotValue
    let previous: SnapshotValue?
    let all: [SnapshotValue]
    @Binding var compareID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Text("What grew").font(.title3.weight(.semibold))
                    if !older.isEmpty {
                        Picker("since", selection: Binding(get: { previous?.id }, set: { compareID = $0 })) {
                            ForEach(older) { s in Text(s.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated)).tag(Optional(s.id)) }
                        }
                        .fixedSize()
                    }
                }
                if let previous {
                    let changes = SnapshotDiff.compare(old: previous, new: current)
                    summary(previous: previous)
                    Table(changes) {
                        TableColumn("Folder") { c in FileIdentity(name: (c.path as NSString).lastPathComponent, path: c.path, symbol: "folder") }
                        TableColumn(Text(previous.date, format: .dateTime.day().month(.abbreviated))) { c in
                            Text(c.oldBytes.map(Format.bytes) ?? "–").tabular().frame(maxWidth: .infinity, alignment: .trailing)
                        }.width(90)
                        TableColumn(Text(current.date, format: .dateTime.day().month(.abbreviated))) { c in
                            Text(c.newBytes.map(Format.bytes) ?? "–").tabular().frame(maxWidth: .infinity, alignment: .trailing)
                        }.width(90)
                        TableColumn("Change") { c in ChangeText(change: c).frame(maxWidth: .infinity, alignment: .trailing) }.width(110)
                    }
                    .frame(minHeight: 400)
                    .kmTableSurface()
                } else {
                    Text("This is the first snapshot. Next week’s will show what grew.")
                        .foregroundStyle(.kmFgMuted)
                    Table(current.entries.sorted { $0.value > $1.value }.map { FolderChange(path: $0.key, oldBytes: nil, newBytes: $0.value) }) {
                        TableColumn("Folder") { c in FileIdentity(name: (c.path as NSString).lastPathComponent, path: c.path, symbol: "folder") }
                        TableColumn("Size") { c in Text(Format.bytes(c.newBytes ?? 0)).tabular().frame(maxWidth: .infinity, alignment: .trailing) }.width(100)
                    }
                    .frame(minHeight: 400)
                    .kmTableSurface()
                }
            }
            .padding(Metrics.pagePadding)
        }
    }

    private var older: [SnapshotValue] { all.filter { $0.date < current.date } }

    @ViewBuilder private func summary(previous: SnapshotValue) -> some View {
        let usedDelta = current.volumeUsed - previous.volumeUsed
        Grid(alignment: .leading, horizontalSpacing: 0) {
            GridRow {
                stat(title: "Space used", value: usedDelta >= 0 ? Text("\(Format.bytes(usedDelta)) more") : Text("\(Format.bytes(-usedDelta)) less"))
                VRule()
                stat(title: "Battery capacity", value: batteryText(previous: previous))
                VRule()
                stat(title: "Reclaimable", value: Text(Format.bytes(current.reclaimableBytes)))
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func stat(title: LocalizedStringKey, value: Text) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.kmFgMuted)
            value.font(.title3.weight(.semibold)).tabular()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func batteryText(previous: SnapshotValue) -> Text {
        guard let now = current.batteryMaxCapacityPercent else { return Text("No battery") }
        let nowText = Format.percent(now / 100)
        guard let before = previous.batteryMaxCapacityPercent else { return Text(nowText) }
        let delta = now - before
        if abs(delta) < 0.05 { return Text("\(nowText), no change") }
        let points = abs(delta).formatted(.number.precision(.fractionLength(1)))
        return delta < 0 ? Text("\(nowText), down \(points)") : Text("\(nowText), up \(points)")
    }
}

private struct ChangeText: View {
    let change: FolderChange
    var body: some View {
        if change.isNew {
            Text("New, \(Format.bytes(change.delta))").tabular()
        } else if change.isRemoved {
            Text("Removed").foregroundStyle(.kmFgMuted)
        } else if change.delta == 0 {
            Text("No change").foregroundStyle(.kmFgMuted)
        } else if change.delta > 0 {
            Text(verbatim: "+" + Format.bytes(change.delta)).fontWeight(.semibold).tabular()
        } else {
            Text(verbatim: "−" + Format.bytes(-change.delta)).foregroundStyle(.kmFgMuted).tabular()
        }
    }
}
