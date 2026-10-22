import SwiftUI

@main
struct KeelMacApp: App {
    @State private var model: AppModel

    init() {
        Preferences.registerDefaults()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        Window("KeelMac", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
                .onOpenURL { model.open($0) }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
