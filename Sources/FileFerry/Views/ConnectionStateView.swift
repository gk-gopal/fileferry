import SwiftUI

/// Every device state gets its own screen with the actual fix. ADB's whole
/// cost is one-time USB debugging setup, so a generic "no device found" is
/// where this app would lose people.
struct ConnectionStateView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3).bold()
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)

            if case .noDevice = model.status {
                steps
            }
            if let command {
                HStack(spacing: 6) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
            }

            Button("Try Again") { Task { await model.connect() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            step(1, "Settings → About phone → tap **Build number** seven times")
            step(2, "Settings → System → Developer options → turn on **USB debugging**")
            step(3, "Connect the cable, then tap **Allow** on the phone")
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 400)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption).bold().monospacedDigit()
                .frame(width: 18, height: 18)
                .background(Color.accentColor, in: Circle())
                .foregroundStyle(.white)
            Text(.init(text)).font(.caption)
        }
    }

    private var symbol: String {
        switch model.status {
        case .starting: "hourglass"
        case .adbMissing, .adbTooOld: "shippingbox"
        case .serverUnavailable: "exclamationmark.triangle"
        case .noDevice: "cable.connector"
        case .unauthorized: "lock.shield"
        case .offline: "arrow.triangle.2.circlepath"
        case .ready: "iphone"
        }
    }

    private var title: String {
        switch model.status {
        case .starting: "Looking for your phone…"
        case .adbMissing: "FileFerry needs Android platform-tools"
        case .adbTooOld: "That version of adb is too old"
        case .serverUnavailable: "Couldn't reach the adb server"
        case .noDevice: "No phone connected"
        case .unauthorized: "Check your phone"
        case .offline: "Phone went offline"
        case .ready: "Connected"
        }
    }

    private var detail: String {
        switch model.status {
        case .starting:
            "Starting the adb server."
        case .adbMissing:
            "FileFerry uses Android's adb to talk to your phone over USB. Install it with Homebrew, then try again."
        case .adbTooOld(let found, let required):
            "Found adb \(found), but FileFerry needs \(required) or newer. Upgrade it and try again."
        case .serverUnavailable(let reason):
            reason
        case .noDevice:
            "If the phone is already plugged in, check that the cable carries data — many charging cables don't — and that USB debugging is on."
        case .unauthorized(let serial):
            "Device \(serial) is connected but hasn't authorised this Mac. Unlock the phone and tap \"Allow\" on the USB debugging prompt, ticking \"Always allow from this computer\"."
        case .offline(let serial):
            "Device \(serial) stopped responding. Unplug the cable and plug it back in."
        case .ready:
            ""
        }
    }

    private var command: String? {
        switch model.status {
        case .adbMissing, .adbTooOld:
            "brew install --cask android-platform-tools"
        default:
            nil
        }
    }
}
