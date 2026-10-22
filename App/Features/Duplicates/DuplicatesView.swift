import DuplicatesKit
import SafetyKit
import SwiftUI

/// S16: byte-identical duplicates in chosen folders; extra copies go to the Trash by rule, one copy always kept.
struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("duplicateRoots") private var rootsRaw = "~/Documents\n~/Downloads\n~/Desktop\n~/Pictures"
    @State private var rule: RuleChoice = .newest
    @State private var preferredFolder: String?
    @State private var phase: Phase = .idle
    @State private var toRemove: Set<String> = []
    @State private var search: Task<Void, Never>?
    @State private var confirm = false
    @State private var lastOutcome: [RemovalOutcome]?

    enum Phase {
        case idle
        case searching(DuplicateProgress?)
        case done(DuplicateSearchResult)
        case failed(String)
    }

    enum RuleChoice: String, CaseIterable, Identifiable {
        case newest, oldest, preferred
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .newest: "Newest copy"
            case .oldest: "Oldest copy"
            case .preferred: "Copy in a preferred folder"
            }
        }
    }

    private var roots: [String] { rootsRaw.split(separator: "\n").map(String.init) }

    private var autoRule: AutoSelectRule {
        switch rule {
        case .newest: .newest
        case .oldest: .oldest
        case .preferred: preferredFolder.map { .preferredFolder($0) } ?? .newest
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            if case .done(let result) = phase, !result.groups.isEmpty {
                ActionBar {
                    Text("\(selectedFiles(result).count) copies selected, \(Format.bytes(selectedBytes(result))). One copy in every group is always kept.")
                } trailing: {
                    Button { confirm = true } label: { Text("Move \(selectedFiles(result).count) copies to Trash") }
                        .buttonStyle(.kmPrimary)
                        .disabled(toRemove.isEmpty || !everyGroupKeepsOne(result))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(verbatim: roots.joined(separator: ", "))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.kmFgMuted)
                    .lineLimit(1)
            }
            ToolbarItem { Button("Choose folders…", action: chooseFolders) }
            ToolbarItem {
                Picker("Keep", selection: $rule) {
                    ForEach(RuleChoice.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .onChange(of: rule) { _, new in
                    if new == .preferred, preferredFolder == nil { preferredFolder = pickFolder() }
                    applyRule()
                }
            }
            ToolbarItem {
                if case .searching = phase {
                    Button("Stop") { search?.cancel() }
                } else {
                    Button("Search") { start() }
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirm) {
            Button(FileActions.deleteMode == .permanent ? "Delete permanently" : "Move to Trash", role: .destructive) { removeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("One copy of each file stays where it is. Everything moved is listed in the operation log.")
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .idle:
            EmptyStateView(symbol: "doc.on.doc", title: "Find duplicate files", message: "KeelMac compares files in the folders above byte for byte. Nothing is moved until you choose.", actionTitle: "Search", action: start)
        case .searching(let progress):
            VStack(spacing: 12) {
                ProgressView(value: progress?.fraction)
                    .frame(maxWidth: 420)
                (progress.map(stageText) ?? Text("Listing files…"))
                    .foregroundStyle(.kmFgMuted)
                    .tabular()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            EmptyStateView(symbol: "exclamationmark.triangle", title: "The search stopped", message: LocalizedStringKey(message), actionTitle: "Search again", action: start)
        case .done(let result) where result.groups.isEmpty:
            EmptyStateView(symbol: "checkmark.circle", title: "No duplicates found", message: "\(result.filesConsidered) files compared. Try other folders with Choose folders….")
        case .done(let result):
            List {
                Section {
                    Text("\(result.groups.count) groups, \(Format.bytes(result.totalWastedBytes)) in extra copies. Files match byte for byte (SHA-256).")
                        .foregroundStyle(.kmFgMuted)
                    if !result.unreadablePaths.isEmpty {
                        Text("\(result.unreadablePaths.count) files couldn’t be read and were skipped.")
                            .foregroundStyle(.kmWarning)
                    }
                }
                ForEach(result.groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            DuplicateRow(file: file, isKept: !toRemove.contains(file.path), toggle: { toggle(file.path) })
                        }
                    } header: {
                        HStack {
                            Text(verbatim: (group.files.first?.path as NSString?)?.lastPathComponent ?? "")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.kmFg)
                            Spacer()
                            Text("\(group.files.count) copies, \(Format.bytes(group.bytesEach)) each").tabular()
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func stageText(_ p: DuplicateProgress) -> Text {
        switch p.stage {
        case .listing: Text("Listing files… \(p.done)")
        case .groupingBySize: Text("Grouping by size…")
        case .hashingHeads: Text("Comparing the start and end of \(p.done) of \(p.total) files…")
        case .hashingFull: Text("Comparing full contents: \(p.done) of \(p.total)")
        }
    }

    private func start() {
        search?.cancel()
        phase = .searching(nil)
        let finder = DuplicateFinder(pathGuard: FileActions.pathGuard())
        let roots = self.roots.map { ($0 as NSString).expandingTildeInPath }
        search = Task {
            do {
                let result = try await finder.search(roots: roots, minBytes: 1) { p in
                    Task { @MainActor in if case .searching = phase { phase = .searching(p) } }
                }
                phase = .done(result)
                applyRule()
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func applyRule() {
        guard case .done(let result) = phase else { return }
        toRemove = Set(result.groups.flatMap { autoRule.filesToRemove(in: $0).map(\.path) })
    }

    private func toggle(_ path: String) {
        if toRemove.contains(path) { toRemove.remove(path) } else { toRemove.insert(path) }
    }

    private func selectedFiles(_ r: DuplicateSearchResult) -> [DuplicateFile] {
        r.groups.flatMap(\.files).filter { toRemove.contains($0.path) }
    }

    private func selectedBytes(_ r: DuplicateSearchResult) -> Int64 { selectedFiles(r).reduce(0) { $0 + $1.bytes } }

    private func everyGroupKeepsOne(_ r: DuplicateSearchResult) -> Bool {
        r.groups.allSatisfy { g in g.files.contains { !toRemove.contains($0.path) } }
    }

    private var confirmTitle: Text {
        guard case .done(let r) = phase else { return Text(verbatim: "") }
        return Text("Move \(selectedFiles(r).count) copies (\(Format.bytes(selectedBytes(r)))) to the Trash?")
    }

    private func removeSelected() {
        guard case .done(let result) = phase else { return }
        let requests = selectedFiles(result).map { RemovalRequest(path: $0.path, bytes: $0.bytes, expectedModificationDate: $0.modified) }
        Task {
            let outcomes = await FileActions.remove(requests, context: .userFile, kind: .duplicates, title: String(localized: "Duplicates"), log: model.operationLog)
            lastOutcome = outcomes
            let removed = Set(outcomes.filter { $0.result.removedItem }.map(\.path))
            let groups = result.groups.compactMap { g -> DuplicateGroup? in
                let left = g.files.filter { !removed.contains($0.path) }
                return left.count > 1 ? DuplicateGroup(id: g.id, bytesEach: g.bytesEach, files: left) : nil
            }
            phase = .done(DuplicateSearchResult(groups: groups, unreadablePaths: result.unreadablePaths, protectedSkipped: result.protectedSkipped, filesConsidered: result.filesConsidered))
            applyRule()
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Search these folders")
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            rootsRaw = panel.urls.map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
            phase = .idle
        }
    }

    private func pickFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Prefer this folder")
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

private struct DuplicateRow: View {
    let file: DuplicateFile
    let isKept: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { !isKept }, set: { _ in toggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .accessibilityLabel(Text(isKept ? "Keep \(file.path)" : "Move \(file.path) to Trash"))
            PathText(path: file.path)
                .foregroundStyle(.kmFg)
            if isKept {
                Text("Keep")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.kmAccentText)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.kmAccentSoft, in: RoundedRectangle(cornerRadius: 4))
            }
            Spacer()
            Text("Modified \(file.modified.formatted(date: .abbreviated, time: .omitted))")
                .foregroundStyle(.kmFgMuted)
                .tabular()
        }
        .contextMenu {
            Button("Reveal in Finder") { FileActions.reveal([file.path]) }
            Button("Open") { FileActions.open(file.path) }
        }
    }
}
