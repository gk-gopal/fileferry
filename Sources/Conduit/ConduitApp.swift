import SwiftUI

@main
struct ConduitApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Conduit", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1180, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Device") {
                Button("Reconnect") { Task { await model.connect() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
