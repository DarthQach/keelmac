import SafetyKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// S10: every operation KeelMac performed, searchable, filterable and exportable.
struct OperationLogView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \OperationRecord.date, order: .reverse) private var records: [OperationRecord]
    @State private var search = ""
    @State private var filter: ResultFilter = .all
    @State private var exportFormat: OperationLogExporter.Format?
    @State private var exportError: String?

    enum ResultFilter: String, CaseIterable, Identifiable {
        case all, removed, skipped, failed
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .removed: "Moved or deleted"
            case .skipped: "Skipped"
            case .failed: "Failed or refused"
            }
        }
        func matches(_ r: OperationResult) -> Bool {
            switch self {
            case .all: true
            case .removed: r.removedItem
            case .skipped: r == .skipped
            case .failed: r == .failed || r == .refused
            }
        }
    }

    private var filtered: [OperationRecord] {
        records.filter { r in
            filter.matches(r.resultValue) && (search.isEmpty || r.path.localizedCaseInsensitiveContains(search) || r.title.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        Group {
            if records.isEmpty {
                EmptyStateView(symbol: "list.bullet.rectangle", title: "No operations yet", message: "Everything KeelMac moves or deletes is listed here.")
            } else {
                VStack(spacing: 0) {
                    Table(filtered) {
                        TableColumn("Date") { r in Text(r.date, format: .dateTime.day().month(.abbreviated).hour().minute()).tabular() }
                            .width(min: 110, ideal: 130, max: 150)
                        TableColumn("Operation") { r in Text(verbatim: r.title).fontWeight(.medium).frame(minHeight: Metrics.detailRowHeight) }
                            .width(min: 90, ideal: 120, max: 150)
                        TableColumn("Path") { r in
                            Text(verbatim: (r.path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                                .help(r.path)
                        }
                        .width(min: 180, ideal: 260)
                        TableColumn("Size") { r in Text(r.bytes > 0 ? Format.bytes(r.bytes) : "–").tabular().frame(maxWidth: .infinity, alignment: .trailing) }
                            .width(min: 70, ideal: 80, max: 100)
                        TableColumn("Result") { r in ResultText(result: r.resultValue, reason: r.reason) }
                            .width(min: 140, ideal: 220, max: 280)
                    }
                    .kmTableSurface()
                    .padding(.horizontal, Metrics.pagePadding)
                    .contextMenu(forSelectionType: OperationRecord.ID.self) { ids in
                        Button("Reveal in Finder") {
                            FileActions.reveal(records.filter { ids.contains($0.id) && FileManager.default.fileExists(atPath: $0.path) }.map(\.path))
                        }
                    }
                    Divider()
                    HStack {
                        Text("\(records.count) operations. Stored in ~/Library/Application Support/KeelMac.")
                            .foregroundStyle(.kmFgMuted)
                            .tabular()
                        Spacer()
                    }
                    .font(.callout)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 8)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: Text("Search paths"))
        .toolbar {
            ToolbarItem {
                Picker("Result", selection: $filter) {
                    ForEach(ResultFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            ToolbarItem {
                Menu("Export log…") {
                    Button("CSV") { export(.csv) }
                    Button("JSON") { export(.json) }
                    Button("Markdown") { export(.markdown) }
                }
                .disabled(records.isEmpty)
            }
        }
        .alert("Couldn’t export the log", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: exportError ?? "")
        }
    }

    private func export(_ format: OperationLogExporter.Format) {
        let entries = filtered.map(\.entry)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "KeelMac operation log.\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OperationLogExporter.export(entries, as: format).write(to: url)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// Result text with its semantic colour and, when present, the reason.
struct ResultText: View {
    let result: OperationResult
    let reason: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(result.label)
            if let reason, !reason.isEmpty {
                Text(verbatim: "·").accessibilityHidden(true)
                Text(LocalizedStringKey(reason))
            }
        }
        .foregroundStyle(result.tone)
        .lineLimit(1)
        .help(reason ?? "")
    }
}

extension OperationResult {
    var label: LocalizedStringKey {
        switch self {
        case .trashed: "Moved to Trash"
        case .deleted: "Deleted"
        case .ran: "Ran"
        case .disabled: "Disabled"
        case .enabled: "Enabled"
        case .removed: "Removed"
        case .skipped: "Skipped"
        case .failed: "Failed"
        case .refused: "Refused"
        }
    }

    var tone: Color {
        switch self {
        case .trashed, .deleted, .ran, .disabled, .enabled, .removed: .kmSuccess
        case .skipped: .kmWarning
        case .failed, .refused: .kmDanger
        }
    }
}
