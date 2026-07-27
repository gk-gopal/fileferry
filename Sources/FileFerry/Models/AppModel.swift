import Foundation
import Observation
import Quartz
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

    /// Pending destructive action, awaiting confirmation.
    var deleteRequest: (pane: PaneModel, entries: [DeviceEntry])?

    init() {
        let preferences = Preferences.shared
        let start = preferences.restoreLastFolder
            ? (preferences.macLastPath ?? NSHomeDirectory() + "/Downloads")
            : NSHomeDirectory() + "/Downloads"
        macPane = PaneModel(
            title: "Mac",
            transport: LocalTransport(),
            path: FileManager.default.fileExists(atPath: start) ? start : NSHomeDirectory(),
            favorites: AppModel.macFavorites,
            isPhone: false,
            treeRoot: NSHomeDirectory()
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
            binary = try ADBBinary.resolve(configuredPath: Preferences.shared.resolvedADBPath)
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
            let preferences = Preferences.shared
            let start = preferences.restoreLastFolder
                ? (preferences.phoneLastPath ?? "/sdcard")
                : "/sdcard"
            let pane = PaneModel(
                title: ready.serial,
                transport: transport,
                path: start,
                favorites: AppModel.phoneFavorites,
                isPhone: true,
                treeRoot: "/sdcard"
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
        transfer(
            paths: source.selectedEntries.map(\.path),
            from: source, to: destination, mode: mode)
    }

    /// The general form, also used by drag-and-drop, where the destination
    /// directory may be a sidebar favourite rather than the pane's own path.
    func transfer(
        paths: [String],
        from source: PaneModel,
        to destination: PaneModel,
        into directory: String? = nil,
        mode: TransferMode = .copy
    ) {
        guard !isBusy, !paths.isEmpty else { return }

        let job = TransferJob(
            sources: paths,
            destinationDirectory: directory ?? destination.path,
            mode: mode,
            conflictPolicy: Preferences.shared.conflictPolicy
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
            let engine = TransferEngine(concurrency: Preferences.shared.concurrency)
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

    // MARK: - Drag and drop

    /// Files dragged from the Mac pane or from Finder arrive as URLs, which is
    /// what makes dragging out to Finder work as a real file drag rather than
    /// a text clipping.
    func dropFiles(_ urls: [URL], onto destination: PaneModel, directory: String? = nil) {
        guard destination.isPhone, !urls.isEmpty else { return }
        transfer(
            paths: urls.map(\.path),
            from: macPane,
            to: destination,
            into: directory,
            mode: .copy
        )
    }

    /// Phone paths have no URL representation on this machine, so they travel
    /// as strings behind a scheme prefix.
    func dropPhonePaths(_ payloads: [String], onto destination: PaneModel, directory: String? = nil) {
        guard !destination.isPhone, let phonePane else { return }
        let paths = payloads
            .filter { $0.hasPrefix(PaneModel.phoneDragPrefix) }
            .map { String($0.dropFirst(PaneModel.phoneDragPrefix.count)) }
        guard !paths.isEmpty else { return }
        transfer(
            paths: paths,
            from: phonePane,
            to: destination,
            into: directory,
            mode: .copy
        )
    }

    // MARK: - Preview

    var isPreparingPreview = false
    var previewURLs: [URL] = []
    var previewIndex = 0
    var isShowingPreview = false

    var currentPreviewURL: URL? {
        previewURLs.indices.contains(previewIndex) ? previewURLs[previewIndex] : nil
    }

    var previewTitle: String {
        currentPreviewURL.map { $0.lastPathComponent } ?? "Preview"
    }

    func previewNext() {
        guard previewIndex < previewURLs.count - 1 else { return }
        previewIndex += 1
    }

    func previewPrevious() {
        guard previewIndex > 0 else { return }
        previewIndex -= 1
    }

    func closePreview() {
        isShowingPreview = false
        previewURLs = []
        previewIndex = 0
    }

    /// Called when a selection changes. Only re-previews if the sheet is
    /// already open — otherwise merely clicking a file would yank a phone file
    /// across the wire unasked.
    func previewIfPanelOpen(_ pane: PaneModel) {
        guard isShowingPreview else { return }
        preview(pane)
    }

    /// Quick Look needs a real file, so phone items are fetched to a cache
    /// first. Local files open straight away.
    func preview(_ pane: PaneModel) {
        let targets = pane.selectedEntries.filter { !$0.isDirectory }
        guard !targets.isEmpty, !isPreparingPreview else { return }

        guard pane.isPhone else {
            show(urls: targets.map { URL(fileURLWithPath: $0.path) })
            return
        }

        isPreparingPreview = true
        let transport = pane.transport
        Task { @MainActor [self] in
            defer { isPreparingPreview = false }
            var urls: [URL] = []
            let local = LocalTransport()
            // Cap it: previewing a 40-file selection would mean pulling all of
            // them before showing anything.
            for entry in targets.prefix(8) {
                let cached = PreviewCache.url(
                    forRemote: entry.path, size: entry.size, mtime: entry.mtime)
                if !FileManager.default.fileExists(atPath: cached.path) {
                    do {
                        try await local.write(cached.path, from: transport.read(entry.path))
                    } catch {
                        alertMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                        continue
                    }
                }
                urls.append(cached)
            }
            show(urls: urls)
        }
    }

    private func show(urls: [URL]) {
        guard !urls.isEmpty else { return }
        previewURLs = urls
        previewIndex = 0
        isShowingPreview = true
    }

    // MARK: - New folder

    func createFolder(named name: String, in pane: PaneModel) {
        Task { @MainActor [self] in
            do {
                try await pane.createFolder(named: name)
            } catch {
                alertMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    // MARK: - Destructive actions

    /// Deleting is irreversible on both sides — there is no trash on the phone
    /// — so it always goes through a confirmation.
    func requestDelete(in pane: PaneModel) {
        let targets = pane.selectedEntries
        guard !targets.isEmpty, !isBusy else { return }
        deleteRequest = (pane, targets)
    }

    func confirmDelete() {
        guard let request = deleteRequest else { return }
        deleteRequest = nil
        performDelete(request.entries, in: request.pane)
    }

    private func performDelete(_ targets: [DeviceEntry], in pane: PaneModel) {
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
