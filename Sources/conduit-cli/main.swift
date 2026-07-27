import Foundation
import ADBKit

// A thin harness over ADBKit, used to verify the protocol layer against real
// hardware before any UI exists. Not shipped with the app.

func usage() -> Never {
    print("""
    conduit-cli — ADBKit harness

      devices
      ls    <remote-path>
      pull  <remote-path> <local-path>
      push  <local-path>  <remote-path>
      df    <remote-path>
    """)
    exit(2)
}

func humanBytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Reprints a single progress line. `total` may be 0 when the size is unknown.
func showProgress(done: Int64, total: Int64, since start: Date) {
    let elapsed = max(Date().timeIntervalSince(start), 0.001)
    let rate = Double(done) / elapsed
    let percent = total > 0 ? " \(Int(Double(done) / Double(total) * 100))%" : ""
    let line = "\r\(humanBytes(done))\(percent) · \(humanBytes(Int64(rate)))/s    "
    FileHandle.standardError.write(Data(line.utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

let binary = try ADBBinary.resolve()
note("using adb \(binary.version) at \(binary.url.path)")

let server = ADBServer(binary: binary)
try await server.ensureRunning()

/// Returns the first connected, authorized device, explaining what is wrong
/// when there isn't one.
func firstReadyDevice() async throws -> String {
    var iterator = DeviceTracker(server: server).devices().makeAsyncIterator()
    let devices = try await iterator.next() ?? []

    if let ready = devices.first(where: { $0.state == .device }) {
        return ready.serial
    }
    if let pending = devices.first(where: { $0.state == .unauthorized }) {
        note("""

        Device \(pending.serial) is connected but not authorized.
        Unlock the phone and tap "Allow" on the USB debugging prompt,
        ticking "Always allow from this computer".
        """)
    } else if devices.isEmpty {
        note("""

        No devices. Check that USB debugging is on, and that the cable
        carries data — many charging cables do not.
        """)
    }
    throw ADBError.deviceNotFound("no authorized device")
}

switch command {
case "devices":
    var iterator = DeviceTracker(server: server).devices().makeAsyncIterator()
    let devices = try await iterator.next() ?? []
    if devices.isEmpty {
        print("no devices — check the cable, and that it carries data rather than only power")
    }
    for device in devices {
        print("\(device.serial)\t\(device.state.rawValue)")
    }

case "ls":
    guard arguments.count == 2 else { usage() }
    let session = try await SyncSession.open(server: server, serial: try await firstReadyDevice())
    let started = Date()
    let entries = try await session.list(arguments[1])
    let elapsed = Date().timeIntervalSince(started)
    await session.close()

    for entry in entries.sorted(by: { $0.name < $1.name }) {
        let kind = entry.isDirectory ? "d" : "-"
        let size = humanBytes(entry.size).padding(toLength: 10, withPad: " ", startingAt: 0)
        print("\(kind) \(size) \(entry.name)")
    }
    print("\(entries.count) entries in \(String(format: "%.0f", elapsed * 1000)) ms")

case "pull":
    guard arguments.count == 3 else { usage() }
    let session = try await SyncSession.open(server: server, serial: try await firstReadyDevice())
    let size = (try? await session.stat(arguments[1]).size) ?? 0
    let started = Date()
    let written = try await session.pull(arguments[1], to: URL(fileURLWithPath: arguments[2])) {
        showProgress(done: $0, total: size, since: started)
    }
    await session.close()
    print("\npulled \(humanBytes(written)) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

case "push":
    guard arguments.count == 3 else { usage() }
    let source = URL(fileURLWithPath: arguments[1])
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

    let session = try await SyncSession.open(server: server, serial: try await firstReadyDevice())
    let started = Date()
    let sent = try await session.push(source, to: arguments[2]) {
        showProgress(done: $0, total: size, since: started)
    }
    await session.close()
    print("\npushed \(humanBytes(sent)) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

case "df":
    guard arguments.count == 2 else { usage() }
    let shell = ShellSession(server: server, serial: try await firstReadyDevice())
    let result = try await shell.run("df -k \(arguments[1])")
    guard result.succeeded, let free = ShellSession.parseFreeSpace(result.stdout) else {
        note(result.stderr.isEmpty ? "df failed" : result.stderr)
        exit(1)
    }
    print("\(humanBytes(free)) free at \(arguments[1])")

default:
    usage()
}
