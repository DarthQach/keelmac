import CleanKit
import ReportKit
import SafetyKit
import SwiftUI

/// S9: what was moved, what was skipped and why, and the coffee prompt after a big cleanup.
struct CleanupResultView: View {
    @Environment(AppModel.self) private var model
    let result: CleanupResult
    @AppStorage(Preferences.Key.coffeeDismissedForever) private var coffeeDismissed = false
    @State private var dontAsk = false
    @State private var coffeeVisible = false

    private var notRemoved: [RemovalOutcome] { result.outcomes.filter { !$0.result.removedItem } }
    private var failedCommands: [(String, CommandResult)] { result.commandResults.filter { !$0.value.succeeded }.map { ($0.key, $0.value) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.kmSuccess)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        headline.font(.title2.weight(.semibold))
                        Text("\(result.outcomes.filter(\.result.removedItem).count) items handled, \(notRemoved.count) skipped.")
                            .foregroundStyle(.kmFgMuted).tabular()
                        if result.bytesMovedToTrash > 0 && result.bytesDeleted + result.bytesFreedByCommands > 0 {
                            Text("\(Format.bytes(result.bytesDeleted + result.bytesFreedByCommands)) more was freed by emptying the Trash and running commands.")
                                .foregroundStyle(.kmFgMuted).tabular()
                        }
                        if result.bytesMovedToTrash > 0 {
                            Text("Empty the Trash to free the space.").foregroundStyle(.kmFgMuted)
                        }
                    }
                }

                if !notRemoved.isEmpty || !failedCommands.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Skipped").font(.headline)
                        Table(notRemoved, columns: {
                            TableColumn("Item") { o in PathText(path: o.path).foregroundStyle(.kmFg) }
                            TableColumn("Size") { o in Text(Format.bytes(o.bytes)).tabular().frame(maxWidth: .infinity, alignment: .trailing) }.width(80)
                            TableColumn("Reason") { o in Text(LocalizedStringKey(o.reason ?? "")).foregroundStyle(o.result == .failed ? .kmDanger : .kmWarning) }
                        })
                        .frame(minHeight: 160, maxHeight: 280)
                        ForEach(failedCommands, id: \.0) { id, r in
                            Text("A command failed with exit code \(r.exitCode): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                                .foregroundStyle(.kmDanger).font(.callout)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button("Done") { model.cleanup.finish(); Task { await model.cleanup.check(hasFullDiskAccess: model.hasFullDiskAccess) } }
                        .buttonStyle(.kmPrimary)
                        .keyboardShortcut(.defaultAction)
                    if result.bytesMovedToTrash > 0 {
                        Button("Show Trash") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) }
                    }
                    Button("View in operation log") { model.route = .operationLog }.buttonStyle(.link)
                }

                if coffeeVisible {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Freed \(Format.bytes(result.bytesFreed)). Buy me a coffee?").fontWeight(.semibold)
                            Text("KeelMac is free and stays free. This shows at most once a month.").foregroundStyle(.kmFgMuted)
                        }
                        Spacer()
                        Toggle("Don’t ask again", isOn: $dontAsk).toggleStyle(.checkbox)
                        Button("Not now") { closeCoffee() }
                        Button("Buy me a coffee") {
                            NSWorkspace.shared.open(SupportLinks.coffee)
                            closeCoffee()
                        }
                        .fontWeight(.semibold)
                    }
                    .kmGroup()
                }
            }
            .padding(32)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onAppear {
            let last = UserDefaults.standard.object(forKey: Preferences.Key.coffeeLastShown) as? Date
            coffeeVisible = CoffeePrompt.shouldShow(freedBytes: result.bytesFreed, lastShown: last, dismissedForever: coffeeDismissed, now: Date())
            if coffeeVisible { UserDefaults.standard.set(Date(), forKey: Preferences.Key.coffeeLastShown) }
        }
    }

    private var headline: Text {
        if result.bytesMovedToTrash > 0 {
            return Text("Moved \(Format.bytes(result.bytesMovedToTrash)) to Trash.")
        }
        return Text("Freed \(Format.bytes(result.bytesFreed)).")
    }

    private func closeCoffee() {
        if dontAsk { coffeeDismissed = true }
        coffeeVisible = false
    }
}

enum SupportLinks {
    static let coffee = URL(string: "https://buymeacoffee.com/keelmac")!
    static let repository = URL(string: "https://github.com/DarthQach/keelmac")!
    static let issues = URL(string: "https://github.com/DarthQach/keelmac/issues")!
    static let site = URL(string: "https://keelmac.flowrunnerapp.workers.dev")!
    static let releaseNotes = URL(string: "https://keelmac.flowrunnerapp.workers.dev/releases/")!
}

extension RemovalOutcome: @retroactive Identifiable {
    public var id: String { path }
}
