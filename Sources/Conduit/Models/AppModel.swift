import Foundation
import Observation
import ADBKit
import ADBTransport
import LocalTransport
import TransportKit

/// Every state the device connection can be in. Each gets its own screen with
/// the actual fix, rather than a generic "no device found".
enum DeviceStatus: Equatable {
    case starting
    case adbMissing
    case adbTooOld(found: String, required: String)
    case serverUnavailable(String)
    case noDevice
    case unauthorized(serial: String)
    case offline(serial: String)
    case ready(serial: String)
}

struct ActiveTransfer: Equatable {
    var progress: TransferProgress
    var label: String
}

@MainActor
@Observable
final class AppModel {
    var status: DeviceStatus = .starting
    var macPane: PaneModel
    var phonePane: PaneModel?
    var transfer: ActiveTransfer?
    var lastReport: TransferReport?
    var alertMessage: String?

    private var server: ADBServer?
    private var trackerTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?

    static let macFavorites: [Favorite] = [
        Favorite(symbol: "house", name: "Home", path: NSHomeDirectory()),
        Favorite(symbol: "arrow.down.circle", name: "Downloads", path: NSHomeDirectory() + "/Downloads"),
        Favorite(symbol: "menubar.dock.rectangle", name: "Desktop", path: NSHomeDirectory() + "/Desktop"),
        Favorite(symbol: "doc", name: "Documents", path: NSHomeDirectory() + "/Documents"),
        Favorite(symbol: "photo", name: "Pictures", path: NSHomeDirectory() + "/Pictures"),
        Favorite(symbol: "music.note", name: "Music", path: NSHomeDirectory() + "/Music"),
    ]

    static let phoneFavorites: [Favorite] = [
        Favorite(symbol: "arrow.down.circle", name: "Download", path: "/sdcard/Download"),
        Favorite(symbol: "camera", name: "Camera", path: "/sdcard/DCIM/Camera"),
        Favorite(symbol: "photo", name: "Pictures", path: "/sdcard/Pictures"),
        Favorite(symbol: "music.note", name: "Music", path: "/sdcard/Music"),
        Favorite(symbol: "film", name: "Movies", path: "/sdcard/Movies"),
        Favorite(symbol: "doc", name: "Documents", path: "/sdcard/Documents"),
    ]

    init() {
        macPane = PaneModel(
            title: "Mac",
            transport: LocalTransport(),
            path: NSHomeDirectory() + "/Downloads",
            favorites: AppModel.macFavorites,
            isPhone: false
        )
    }

    var isBusy: Bool { transfer != nil }

    // MARK: - Connection

    func start() async {
        await macPane.load()
        await connect()
    }

    func connect() async {
        trackerTask?.cancel()
        status = .starting

        let binary: ADBBinary
        do {
            binary = try ADBBinary.resolve()
        } catch ADBError.binaryNotFound {
            status = .adbMissing
            return
        } catch ADBError.binaryTooOld(let found, let required) {
            status = .adbTooOld(found: found, required: required)
            return
        } catch {
            status = .serverUnavailable((error as? LocalizedError)?.errorDescription ?? "\(error)")
            return
        }

        let server = ADBServer(binary: binary)
        self.server = server
        do {
            try await server.ensureRunning()
        } catch {
            status = .serverUnavailable((error as? LocalizedError)?.errorDescription ?? "\(error)")
            return
        }

        // host:track-devices pushes a frame on every connect or disconnect, so
        // nothing here polls.
        trackerTask = Task { @MainActor [weak self] in
            do {
                for try await devices in DeviceTracker(server: server).devices() {
                    guard !Task.isCancelled, let self else { return }
                    await self.apply(devices, server: server)
                }
            } catch {
                self?.status = .serverUnavailable(
                    (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    private func apply(_ devices: [ADBDevice], server: ADBServer) async {
        if let ready = devices.first(where: { $0.state == .device }) {
            guard status != .ready(serial: ready.serial) else { return }
            status = .ready(serial: ready.serial)
            let transport = ADBTransport(server: server, serial: ready.serial)
            let pane = PaneModel(
                title: ready.serial,
                transport: transport,
                path: "/sdcard",
                favorites: AppModel.phoneFavorites,
                isPhone: true
            )
            phonePane = pane
            await pane.load()
        } else if let pending = devices.first(where: { $0.state == .unauthorized }) {
            status = .unauthorized(serial: pending.serial)
            phonePane = nil
        } else if let stale = devices.first(where: { $0.state == .offline }) {
            status = .offline(serial: stale.serial)
            phonePane = nil
        } else {
            status = .noDevice
            phonePane = nil
        }
    }

    // MARK: - Transfers

    enum Direction { case toPhone, toMac }

    func canTransfer(_ direction: Direction) -> Bool {
        guard phonePane != nil, !isBusy else { return false }
        return direction == .toPhone
            ? !macPane.selection.isEmpty
            : !(phonePane?.selection.isEmpty ?? true)
    }

    func transfer(_ direction: Direction, mode: TransferMode) {
        guard let phonePane, !isBusy else { return }
        let source = direction == .toPhone ? macPane : phonePane
        let destination = direction == .toPhone ? phonePane : macPane
        let paths = source.selectedEntries.map(\.path)
        guard !paths.isEmpty else { return }

        let job = TransferJob(
            sources: paths,
            destinationDirectory: destination.path,
            mode: mode,
            conflictPolicy: .rename
        )
        let verb = mode == .move ? "Moving" : "Copying"
        transfer = ActiveTransfer(
            progress: TransferProgress(
                completedBytes: 0, totalBytes: 0,
                completedFiles: 0, totalFiles: paths.count, currentFile: nil),
            label: "\(verb) \(paths.count) item\(paths.count == 1 ? "" : "s")"
        )

        let sourceTransport = source.transport
        let destinationTransport = destination.transport

        transferTask = Task { @MainActor [self] in
            let engine = TransferEngine()
            do {
                let report = try await engine.run(
                    job,
                    from: sourceTransport,
                    to: destinationTransport,
                    // The engine already coalesces to ~10 Hz, so hopping to the
                    // main actor per callback is cheap.
                    onProgress: { progress in
                        Task { @MainActor in self.transfer?.progress = progress }
                    }
                )
                await finish(report: report, error: nil)
            } catch {
                await finish(report: nil, error: error)
            }
        }
    }

    private func finish(report: TransferReport?, error: Error?) async {
        transfer = nil
        lastReport = report
        if let error {
            alertMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        } else if let report, !report.succeeded {
            let first = report.failed.first?.reason ?? ""
            alertMessage = "\(report.failed.count) of \(report.failed.count + report.transferred.count) "
                + "items failed. \(first)"
        }
        await macPane.refresh()
        await phonePane?.refresh()
    }

    func cancelTransfer() {
        transferTask?.cancel()
        transferTask = nil
        transfer = nil
    }

    // MARK: - Destructive actions

    func delete(in pane: PaneModel) {
        let targets = pane.selectedEntries
        guard !targets.isEmpty, !isBusy else { return }
        Task {
            for entry in targets {
                do {
                    try await pane.transport.delete(entry.path)
                } catch {
                    alertMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
            await pane.refresh()
        }
    }
}
