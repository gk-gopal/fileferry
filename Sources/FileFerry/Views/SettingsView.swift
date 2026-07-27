import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var preferences: Preferences

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            transfers.tabItem { Label("Transfers", systemImage: "arrow.left.arrow.right") }
            advanced.tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 470, height: 290)
    }

    private var general: some View {
        Form {
            Toggle("Reopen the last folder on launch", isOn: $preferences.restoreLastFolder)
            Text("FileFerry remembers pinned folders and where each pane was looking. It never records what you transferred.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Preview a file when it's selected", isOn: $preferences.showPreviewStrip)
            LabeledContent("Preview files up to") {
                HStack {
                    Stepper(value: $preferences.autoPreviewLimitMB, in: 1...2048, step: 10) {
                        Text("\(preferences.autoPreviewLimitMB) MB").monospacedDigit()
                    }
                }
            }
            Text("Previewing a phone file has to fetch it over USB. Larger files offer a button instead of transferring automatically.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }

    private var transfers: some View {
        Form {
            Picker("When a file already exists", selection: $preferences.conflictPolicyName) {
                Text("Keep both (rename)").tag("rename")
                Text("Skip it").tag("skip")
                Text("Replace it").tag("overwrite")
                Text("Stop and ask").tag("fail")
            }

            LabeledContent("Simultaneous transfers") {
                Stepper(value: $preferences.concurrency, in: 1...4) {
                    Text("\(preferences.concurrency)").monospacedDigit()
                }
            }
            Text("USB is the bottleneck. More than two streams usually reduces total throughput rather than improving it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("A move deletes the original only after the copy is verified byte-for-byte. If verification fails, the original is left alone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }

    private var advanced: some View {
        Form {
            LabeledContent("adb location") {
                HStack {
                    TextField("Search the usual locations", text: $preferences.adbPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseADB() }
                }
            }
            Text("Leave empty to search ANDROID_HOME, Homebrew, then /usr/local. FileFerry does not bundle adb — Google's platform-tools may not be redistributed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            LabeledContent("Pinned folders") {
                Text("\(preferences.macPins.count) on Mac, \(preferences.phonePins.count) on phone")
                    .foregroundStyle(.secondary)
            }
            Button("Clear All Pins") {
                preferences.macPins = []
                preferences.phonePins = []
            }
            .disabled(preferences.macPins.isEmpty && preferences.phonePins.isEmpty)
        }
        .formStyle(.grouped)
    }

    private func chooseADB() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the adb executable"
        if panel.runModal() == .OK, let url = panel.url {
            preferences.adbPath = url.path
        }
    }
}

/// Jump straight to a path, for when you know where you're going.
struct GoToPathSheet: View {
    let title: String
    @Binding var path: String
    let go: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Go to Folder").font(.headline)
            Text(title).font(.caption).foregroundStyle(.secondary)

            TextField("/sdcard/DCIM/Camera", text: $path)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 380)
                .onSubmit { if isValid { go() } }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
    }

    private var isValid: Bool {
        path.hasPrefix("/") || path.hasPrefix("~")
    }
}
