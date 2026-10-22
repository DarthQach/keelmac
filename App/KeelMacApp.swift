import SwiftUI

@main
struct KeelMacApp: App {
    @State private var model: AppModel

    init() {
        Preferences.registerDefaults()
        _model = State(initialValue: AppModel())
        let appearance = UserDefaults.standard.string(forKey: Preferences.Key.appearance) ?? "system"
        Task { @MainActor in Appearance.apply(appearance) }
    }

    @ViewBuilder private var mainContent: some View {
        if VisualFixtures.enabled, let surface = VisualFixtures.argument("-fixture-surface") {
            switch surface {
            case "settings": SettingsView()
            case "welcome": WelcomeView()
            case "about": AboutView()
            case "menuBar": MenuBarPopover()
            case "result": FixtureResultView()
            case "uninstall": UninstallSheet(app: VisualFixtures.apps[0])
            default: RootView()
            }
        } else { RootView().frame(minWidth: 960, minHeight: 640) }
    }

    var body: some Scene {
        Window("KeelMac", id: "main") {
            mainContent
                .environment(model)
                .background(FixtureWindowSetup())
                .onOpenURL { model.open($0) }
                .modelContainer(model.container)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
                Button("Check for Updates…") { model.updater.checkForUpdates() }
                    .disabled(!model.updater.canCheck)
            }
            CommandGroup(after: .sidebar) {
                Button(model.assistant.isPresented ? "Hide Assistant" : "Show Assistant") {
                    let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    withAnimation(still ? nil : .snappy(duration: 0.28)) { model.assistant.togglePanel() }
                }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                ForEach(Route.allCases) { route in
                    if let key = route.shortcut {
                        Button(route.title) { model.route = route }.keyboardShortcut(key, modifiers: .command)
                    } else {
                        Button(route.title) { model.route = route }
                    }
                }
            }
        }

        Window("About KeelMac", id: "about") {
            AboutView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarPopover()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
