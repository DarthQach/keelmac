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

    var body: some Scene {
        Window("KeelMac", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
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
