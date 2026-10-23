import Foundation

/// UserDefaults keys and defaults. Views read them with @AppStorage(Preferences.Key.x).
enum Preferences {
    enum Key {
        static let welcomeShown = "welcomeShown"
        static let refreshInterval = "refreshInterval"            // seconds, 1…10
        static let menuBarItems = "menuBarItems"                  // comma-separated MenuBarItem raw values
        static let deleteMode = "deleteMode"                      // DeleteMode raw value
        static let whitelist = "whitelist"                        // [String]
        static let scanExclusions = "scanExclusions"              // [String]
        static let skipRunningAppCaches = "skipRunningAppCaches"
        static let logMinAgeDays = "logMinAgeDays"
        static let alertDiskFreeGB = "alertDiskFreeGB"
        static let alertMemoryRedMinutes = "alertMemoryRedMinutes"
        static let alertTemperatureC = "alertTemperatureC"
        static let alertBatteryPercent = "alertBatteryPercent"
        static let alertsEnabled = "alertsEnabled"
        static let weeklySummary = "weeklySummary"
        static let trashWatcher = "trashWatcher"
        static let coffeeLastShown = "coffeeLastShown"
        static let coffeeDismissedForever = "coffeeDismissedForever"
        static let healthCache = "healthCache"
        static let appearance = "appearance"                      // system, light, dark
        static let byteUnits = "byteUnits"                        // decimal, binary
        static let temperatureUnit = "temperatureUnit"            // celsius, fahrenheit
        static let automaticUpdates = "automaticUpdates"
        static let assistantEnabled = "assistantEnabled"            // off by default: no local server is contacted until the user opts in
        static let assistantProvider = "assistantProvider"          // AssistantProvider raw value: ollama, lmStudio
        static let assistantProviderChosen = "assistantProviderChosen" // set once the user picked a server or first-enable detection ran
        static let assistantHost = "assistantHost"                  // Ollama base URL
        static let assistantLMStudioHost = "assistantLMStudioHost"  // LM Studio base URL
        static let assistantModel = "assistantModel"                // model name from the server's list; empty = first tool-capable one
        static let assistantPanelOpen = "assistantPanelOpen"
        static let projectRoots = "projectRoots"                    // [String], folders whose subfolders are projects
        static let projectStaleDays = "projectStaleDays"            // a project is stale when untouched this long
        static let projectsVerifyGitHub = "projectsVerifyGitHub"    // off by default: nothing reaches GitHub until the user opts in
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.refreshInterval: 2.0,
            Key.menuBarItems: "cpu,memory,temperature",
            Key.deleteMode: "trash",
            Key.whitelist: [String](),
            Key.scanExclusions: ["/Volumes", "~/Library/Mobile Documents"],
            Key.skipRunningAppCaches: true,
            Key.logMinAgeDays: 7,
            Key.alertDiskFreeGB: 20.0,
            Key.alertMemoryRedMinutes: 5,
            Key.alertTemperatureC: 95.0,
            Key.alertBatteryPercent: 80.0,
            Key.alertsEnabled: true,
            Key.weeklySummary: true,
            Key.trashWatcher: false,
            Key.coffeeDismissedForever: false,
            Key.appearance: "system",
            Key.byteUnits: "decimal",
            Key.temperatureUnit: "celsius",
            Key.automaticUpdates: true,
            Key.assistantEnabled: false,
            Key.assistantProvider: "ollama",
            Key.assistantProviderChosen: false,
            Key.assistantHost: "http://localhost:11434",
            Key.assistantLMStudioHost: "http://localhost:1234",
            Key.assistantModel: "",
            Key.assistantPanelOpen: false,
            Key.projectRoots: ["~/Developer"],
            Key.projectStaleDays: 180,
            Key.projectsVerifyGitHub: false,
        ])
    }
}
