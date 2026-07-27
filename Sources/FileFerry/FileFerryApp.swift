import SwiftUI

@main
struct FileFerryApp: App {
    @State private var model = AppModel()
    @State private var preferences = Preferences.shared

    var body: some Scene {
        Window("FileFerry", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1240, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Device") {
                Button("Reconnect") { Task { await model.connect() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Copy to Phone") { model.transfer(.toPhone, mode: .copy) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(!model.canTransfer(.toPhone))
                Button("Copy to Mac") { model.transfer(.toMac, mode: .copy) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(!model.canTransfer(.toMac))
            }
        }

        Settings {
            SettingsView(preferences: preferences)
        }
    }
}
