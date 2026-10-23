import SafetyKit
import ServiceManagement
import SwiftUI

/// S18: Settings window. Each tab applies changes immediately.
struct SettingsView: View {
    @ViewBuilder var body: some View {
        if #available(macOS 15, *) {
            tabs.tabViewStyle(.grouped)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettings()
                .tabItem { Label("Menu bar", systemImage: "menubar.rectangle") }
            AlertSettings()
                .tabItem { Label("Alerts", systemImage: "bell") }
            CleanupSettings()
                .tabItem { Label("Cleanup and safety", systemImage: "checkmark.shield") }
            HelperSettings()
                .tabItem { Label("Helper", systemImage: "lock.rotation") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            AssistantSettings()
                .tabItem { Label("Assistant", systemImage: "sparkles") }
        }
        .padding(16)
        .frame(width: 700)
        .frame(minHeight: 520)
        .background(.kmBg)
        .foregroundStyle(.kmFg)
        .environment(\.defaultMinListRowHeight, Metrics.rowHeight)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.Key.appearance) private var appearance = "system"
    @AppStorage(Preferences.Key.byteUnits) private var byteUnits = "decimal"
    @AppStorage(Preferences.Key.temperatureUnit) private var temperatureUnit = "celsius"
    @AppStorage(Preferences.Key.trashWatcher) private var trashWatcher = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open KeelMac at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(verbatim: loginError).foregroundStyle(.kmDanger).font(.callout)
                }
                Toggle("Offer cleanup when I move an app to the Trash", isOn: $trashWatcher)
                    .onChange(of: trashWatcher) { _, on in model.apps.updateTrashWatcher(enabled: on) }
            }
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("Match the system").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .onChange(of: appearance) { _, value in Appearance.apply(value) }
                Picker("Show sizes", selection: $byteUnits) {
                    Text("Like Finder (1 GB = 1,000 MB)").tag("decimal")
                    Text("Binary (1 GiB = 1,024 MiB)").tag("binary")
                }
                Picker("Temperature", selection: $temperatureUnit) {
                    Text("Celsius").tag("celsius")
                    Text("Fahrenheit").tag("fahrenheit")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

enum Appearance {
    @MainActor
    static func apply(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

// MARK: - Menu bar

enum MenuBarItem: String, CaseIterable, Identifiable {
    case cpu, memory, disk, network, battery, temperature
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory pressure"
        case .disk: "Disk free"
        case .network: "Network"
        case .battery: "Battery"
        case .temperature: "Temperature"
        }
    }

    static func decode(_ raw: String) -> [MenuBarItem] {
        raw.split(separator: ",").compactMap { MenuBarItem(rawValue: String($0)) }
    }
}

struct MenuBarSettings: View {
    @AppStorage(Preferences.Key.menuBarItems) private var itemsRaw = "cpu,memory,temperature"
    @AppStorage(Preferences.Key.refreshInterval) private var interval = 2.0

    var body: some View {
        Form {
            Section("Show in the menu bar") {
                ForEach(MenuBarItem.allCases) { item in
                    Toggle(item.title, isOn: binding(for: item))
                }
                Text("With nothing selected, the menu bar shows the KeelMac mark.")
                    .font(.callout).foregroundStyle(.kmFgMuted)
            }
            Section {
                LabeledContent("Refresh every") {
                    HStack {
                        Slider(value: $interval, in: 1...10, step: 1).frame(width: 220)
                        Text("\(Int(interval)) s").tabular().frame(width: 36, alignment: .trailing)
                    }
                }
                Text("Shorter intervals use slightly more energy. Two seconds is a good balance.")
                    .font(.callout).foregroundStyle(.kmFgMuted)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func binding(for item: MenuBarItem) -> Binding<Bool> {
        Binding {
            MenuBarItem.decode(itemsRaw).contains(item)
        } set: { on in
            var items = MenuBarItem.decode(itemsRaw)
            if on { if !items.contains(item) { items.append(item) } } else { items.removeAll { $0 == item } }
            itemsRaw = MenuBarItem.allCases.filter(items.contains).map(\.rawValue).joined(separator: ",")
        }
    }
}

// MARK: - Alerts

struct AlertSettings: View {
    @AppStorage(Preferences.Key.alertsEnabled) private var enabled = true
    @AppStorage(Preferences.Key.alertDiskFreeGB) private var diskGB = 20.0
    @AppStorage(Preferences.Key.alertMemoryRedMinutes) private var memoryMinutes = 5
    @AppStorage(Preferences.Key.alertTemperatureC) private var temperature = 95.0
    @AppStorage(Preferences.Key.alertBatteryPercent) private var battery = 80.0
    @AppStorage(Preferences.Key.weeklySummary) private var weekly = true

    var body: some View {
        Form {
            Section {
                Toggle("Send alerts", isOn: $enabled)
            }
            Section("Notify me when") {
                LabeledContent("Disk free drops below") {
                    HStack { TextField("GB", value: $diskGB, format: .number).frame(width: 64).multilineTextAlignment(.trailing); Text("GB") }
                }
                LabeledContent("Memory pressure is red for") {
                    HStack { TextField("Minutes", value: $memoryMinutes, format: .number).frame(width: 64).multilineTextAlignment(.trailing); Text("min") }
                }
                LabeledContent("Temperature is above") {
                    HStack { TextField("°C", value: $temperature, format: .number).frame(width: 64).multilineTextAlignment(.trailing); Text("°C") }
                }
                LabeledContent("Battery capacity falls below") {
                    HStack { TextField("%", value: $battery, format: .number).frame(width: 64).multilineTextAlignment(.trailing); Text("%") }
                }
            }
            .disabled(!enabled)
            Section {
                Toggle("Weekly summary on Monday", isOn: $weekly)
                Text("Space change, battery trend, the folders that grew most and what can be cleaned.")
                    .font(.callout).foregroundStyle(.kmFgMuted)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Cleanup and safety

struct CleanupSettings: View {
    @AppStorage(Preferences.Key.deleteMode) private var deleteMode = "trash"
    @AppStorage(Preferences.Key.skipRunningAppCaches) private var skipRunning = true
    @State private var whitelist: [String] = UserDefaults.standard.stringArray(forKey: Preferences.Key.whitelist) ?? []
    @State private var exclusions: [String] = UserDefaults.standard.stringArray(forKey: Preferences.Key.scanExclusions) ?? []
    @State private var newEntry = ""
    @State private var newEntryProblem: WhitelistProblem?
    @State private var confirmPermanent = false
    @State private var projectRoots: [String] = UserDefaults.standard.stringArray(forKey: Preferences.Key.projectRoots) ?? []
    @AppStorage(Preferences.Key.projectStaleDays) private var projectStaleDays = 180
    @AppStorage(Preferences.Key.projectsVerifyGitHub) private var verifyGitHub = false

    var body: some View {
        Form {
            Section("When cleaning") {
                Toggle(isOn: Binding(get: { deleteMode == "trash" }, set: { on in
                    if on { deleteMode = "trash" } else { confirmPermanent = true }
                })) {
                    Text("Move items to the Trash")
                    Text("Turn off to delete permanently. Every delete still asks first.")
                }
                Toggle("Skip caches of apps that are open", isOn: $skipRunning)
            }
            Section {
                ForEach(whitelist, id: \.self) { entry in
                    HStack {
                        Text(verbatim: entry).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Remove") { whitelist.removeAll { $0 == entry }; save() }
                            .accessibilityLabel(Text("Remove \(entry) from the whitelist"))
                    }
                }
                HStack {
                    TextField("~/Library/Caches/com.example.app or ~/Developer/**/build", text: $newEntry)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(addTyped)
                    Button("Add", action: addTyped).disabled(newEntry.isEmpty)
                    Button("Choose folder…", action: chooseFolder)
                }
                if let problem = newEntryProblem {
                    Text(problem.message).foregroundStyle(.kmDanger).font(.callout)
                }
            } header: {
                Text("Never touch (whitelist)")
            } footer: {
                Text("Paths protect themselves and everything inside. Patterns can use * within a folder name and ** for any depth.")
                    .font(.callout).foregroundStyle(.kmFgMuted)
            }
            Section("Always protected") {
                Text("/System, /bin, /sbin, /usr (except Homebrew in /usr/local), other users’ homes, iCloud Drive, the Photos library, Mail, Messages, Safari history, Keychains and KeelMac’s own data. These can’t be changed.")
                    .foregroundStyle(.kmFgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Scan exclusions") {
                ForEach(exclusions, id: \.self) { entry in
                    HStack {
                        Text(verbatim: entry).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Remove") { exclusions.removeAll { $0 == entry }; save() }
                    }
                }
                Button("Add folder…") {
                    if let path = pickFolder() { exclusions.append(path); save() }
                }
            }
            Section {
                ForEach(projectRoots, id: \.self) { entry in
                    HStack {
                        Text(verbatim: entry).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Remove") { projectRoots.removeAll { $0 == entry }; save() }
                            .accessibilityLabel(Text("Remove \(entry) from project folders"))
                    }
                }
                Button("Add folder…") {
                    if let path = pickFolder() {
                        let display = (path as NSString).abbreviatingWithTildeInPath
                        if !projectRoots.contains(display) { projectRoots.append(display) }
                        save()
                    }
                }
                Stepper(value: $projectStaleDays, in: 30...1095, step: 30) {
                    Text("A project is stale after \(projectStaleDays) days without a commit or a file change").tabular()
                }
                Toggle(isOn: $verifyGitHub) {
                    Text("Verify with GitHub")
                    Text("Needed before a project can go to the Trash.")
                }
            } header: {
                Text("Projects")
            } footer: {
                Text("Off by default. When on, KeelMac runs git ls-remote and asks the gh tool you signed in to who you are, to prove every branch is on GitHub. Back up uses git and gh only when you click it. KeelMac stores no token and sends nothing else. Projects always go to the Trash.")
                    .font(.callout).foregroundStyle(.kmFgMuted)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .confirmationDialog("Delete permanently from now on?", isPresented: $confirmPermanent) {
            Button("Delete permanently", role: .destructive) { deleteMode = "permanent" }
            Button("Keep using the Trash", role: .cancel) {}
        } message: {
            Text("Items won’t go to the Trash, so you can’t put them back. KeelMac still shows a preview and asks before every cleanup.")
        }
    }

    private func addTyped() {
        let entry = newEntry.trimmingCharacters(in: .whitespaces)
        if let problem = Whitelist.validate(entry, home: NSHomeDirectory()) {
            newEntryProblem = problem
            return
        }
        newEntryProblem = nil
        if !whitelist.contains(entry) { whitelist.append(entry) }
        newEntry = ""
        save()
    }

    private func chooseFolder() {
        if let path = pickFolder() {
            let display = (path as NSString).abbreviatingWithTildeInPath
            if !whitelist.contains(display) { whitelist.append(display) }
            save()
        }
    }

    private func pickFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func save() {
        UserDefaults.standard.set(whitelist, forKey: Preferences.Key.whitelist)
        UserDefaults.standard.set(exclusions, forKey: Preferences.Key.scanExclusions)
        UserDefaults.standard.set(projectRoots, forKey: Preferences.Key.projectRoots)
    }
}

extension WhitelistProblem {
    var message: LocalizedStringKey {
        switch self {
        case .empty: "Type a path first."
        case .notAbsolute: "Start the path with / or ~/."
        case .doesNotExist: "That folder doesn’t exist. Check the spelling."
        }
    }
}

// MARK: - Helper and updates

struct HelperSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    switch model.helper.status {
                    case .enabled: StatusBadge(text: "Installed and allowed", tone: .success)
                    case .requiresApproval: StatusBadge(text: "Waiting for your approval in Login Items", tone: .warning)
                    case .notRegistered: Text("Not installed").foregroundStyle(.kmFgMuted)
                    case .notFound: Text("Not found in this copy of KeelMac").foregroundStyle(.kmDanger)
                    case .unavailable(let reason): Text(verbatim: reason).foregroundStyle(.kmDanger)
                    }
                }
                Text("The helper runs only the tasks listed in Maintenance and Login items, checks every path again before touching it, and accepts requests only from KeelMac signed by the same developer.")
                    .font(.callout).foregroundStyle(.kmFgMuted).fixedSize(horizontal: false, vertical: true)
                if let error = model.helper.lastError { Text(verbatim: error).font(.callout).foregroundStyle(.kmDanger) }
            }
            Section {
                HStack {
                    switch model.helper.status {
                    case .enabled:
                        Button("Remove helper") { Task { await model.helper.remove() } }
                    case .requiresApproval:
                        Button("Open Login Items") { model.helper.openApprovalSettings() }
                        Button("Remove helper") { Task { await model.helper.remove() } }
                    default:
                        Button("Install helper…") { model.helper.install() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { model.helper.refresh() }
    }
}

struct UpdateSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.Key.automaticUpdates) private var automatic = true

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $automatic)
                    .onChange(of: automatic) { _, on in model.updater.automaticallyChecks = on }
                LabeledContent("Version") {
                    Text(verbatim: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                }
                if let last = model.updater.lastCheck {
                    LabeledContent("Last checked") { Text(last.formatted(date: .abbreviated, time: .shortened)) }
                }
                HStack {
                    Button("Check now") { model.updater.checkForUpdates() }.disabled(!model.updater.canCheck)
                    Link("Release notes", destination: SupportLinks.releaseNotes).foregroundStyle(.kmAccentText)
                }
            } footer: {
                Text("Updates are signed. The update check is the only network request KeelMac makes on its own. Your local Ollama or LM Studio is used only if you turn the Assistant on, and GitHub only if you turn on Verify with GitHub in Projects or click Back up.")
                    .font(.callout).foregroundStyle(.kmFgMuted)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { if !VisualFixtures.enabled { automatic = model.updater.automaticallyChecks } }
    }
}
