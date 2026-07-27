import AppKit
import Foundation
import Observation
import LocalTransport
import TransportKit

struct Favorite: Identifiable, Hashable, Sendable {
    let symbol: String
    let name: String
    let path: String
    var id: String { path }
}

/// One side of the window. Both panes are the same type — the Mac and the
/// phone differ only by which transport they hold.
@MainActor
@Observable
final class PaneModel {
    let title: String
    let transport: any DeviceTransport
    let favorites: [Favorite]
    let isPhone: Bool

    var path: String
    var entries: [DeviceEntry] = []
    var selection: Set<String> = []
    var isLoading = false
    var errorMessage: String?
    var freeSpace: Int64?
    var totalSpace: Int64?
    var sortOrder: [KeyPathComparator<DeviceEntry>] = [
        KeyPathComparator(\DeviceEntry.name, order: .forward)
    ]

    /// Drag payloads for phone paths are carried as plain strings behind this
    /// scheme. Using a custom UTType would mean declaring an exported type in
    /// Info.plist; this needs no registration and is just as unambiguous.
    static let phoneDragPrefix = "conduit-phone://"

    /// Auto-preview fetches the file, so it is capped. Clicking through a
    /// camera roll should not quietly pull a 1.8 GB video over USB; past this
    /// size the strip offers a button instead.
    static let autoPreviewLimit: Int64 = 50 * 1024 * 1024

    // MARK: - Inline preview

    var showPreviewStrip = true
    var previewURL: URL?
    var isPreviewLoading = false
    var previewTooLarge: DeviceEntry?
    var previewError: String?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    /// The single selected file, if the selection is exactly one non-folder.
    var singleSelectedFile: DeviceEntry? {
        guard selection.count == 1,
              let entry = entries.first(where: { selection.contains($0.path) }),
              !entry.isDirectory
        else { return nil }
        return entry
    }

    /// Called whenever the selection changes. Debounced, because holding an
    /// arrow key would otherwise queue a fetch per row.
    func refreshPreview() {
        previewTask?.cancel()
        previewError = nil
        previewTooLarge = nil

        guard showPreviewStrip, let entry = singleSelectedFile else {
            previewURL = nil
            isPreviewLoading = false
            return
        }

        guard isPhone else {
            previewURL = URL(fileURLWithPath: entry.path)
            isPreviewLoading = false
            return
        }

        let cached = PreviewCache.url(forRemote: entry.path, size: entry.size, mtime: entry.mtime)
        if FileManager.default.fileExists(atPath: cached.path) {
            previewURL = cached
            isPreviewLoading = false
            return
        }

        previewURL = nil
        guard entry.size <= PaneModel.autoPreviewLimit else {
            previewTooLarge = entry
            isPreviewLoading = false
            return
        }

        previewTask = Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await fetchPreview(entry, to: cached)
        }
    }

    /// Fetches regardless of size — used by the "Preview anyway" button.
    func forcePreview(_ entry: DeviceEntry) {
        previewTask?.cancel()
        previewTooLarge = nil
        let cached = PreviewCache.url(forRemote: entry.path, size: entry.size, mtime: entry.mtime)
        previewTask = Task { @MainActor [self] in
            await fetchPreview(entry, to: cached)
        }
    }

    private func fetchPreview(_ entry: DeviceEntry, to cached: URL) async {
        isPreviewLoading = true
        defer { isPreviewLoading = false }
        do {
            try await LocalTransport().write(cached.path, from: transport.read(entry.path))
            guard !Task.isCancelled, singleSelectedFile?.path == entry.path else { return }
            previewURL = cached
        } catch {
            previewError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Space, Return, or double-click: enter a folder, or open a file in
    /// whichever app owns it. Phone files are fetched first.
    func activate(_ entry: DeviceEntry) async {
        if entry.isDirectory {
            await open(entry)
            return
        }
        guard isPhone else {
            NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
            return
        }
        let cached = PreviewCache.url(forRemote: entry.path, size: entry.size, mtime: entry.mtime)
        if !FileManager.default.fileExists(atPath: cached.path) {
            isPreviewLoading = true
            defer { isPreviewLoading = false }
            do {
                try await LocalTransport().write(cached.path, from: transport.read(entry.path))
            } catch {
                previewError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                return
            }
        }
        NSWorkspace.shared.open(cached)
    }

    private var backStack: [String] = []
    private var forwardStack: [String] = []

    init(
        title: String,
        transport: any DeviceTransport,
        path: String,
        favorites: [Favorite],
        isPhone: Bool
    ) {
        self.title = title
        self.transport = transport
        self.path = path
        self.favorites = favorites
        self.isPhone = isPhone
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { path != "/" && !parentPath.isEmpty }

    var parentPath: String { (path as NSString).deletingLastPathComponent }

    /// Path split into (label, absolute path) pairs for the breadcrumb bar.
    var breadcrumbs: [(name: String, path: String)] {
        var crumbs: [(String, String)] = []
        var accumulated = ""
        for component in path.split(separator: "/") {
            accumulated += "/" + component
            crumbs.append((String(component), accumulated))
        }
        return crumbs.isEmpty ? [("/", "/")] : crumbs
    }

    var selectedEntries: [DeviceEntry] {
        entries.filter { selection.contains($0.path) }
    }

    /// Folders first, then the user's chosen column — the convention every
    /// file manager follows, and sorting purely by name would bury them.
    var sortedEntries: [DeviceEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            for comparator in sortOrder {
                switch comparator.compare(lhs, rhs) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return false
        }
    }

    /// Wraps a path for dragging out of this pane.
    func dragPayload(for entry: DeviceEntry) -> String {
        isPhone ? PaneModel.phoneDragPrefix + entry.path : entry.path
    }

    func createFolder(named name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw TransportError.io("\"\(name)\" isn't a usable folder name.")
        }
        let target = path.hasSuffix("/") ? path + trimmed : path + "/" + trimmed
        if await transport.exists(target) {
            throw TransportError.io("\"\(trimmed)\" already exists here.")
        }
        try await transport.mkdir(target)
        await refresh()
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            entries = try await transport.list(path)
            selection = []
        } catch {
            entries = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        freeSpace = try? await transport.freeSpace(at: path)
    }

    func go(to newPath: String, recordHistory: Bool = true) async {
        guard newPath != path else { return }
        if recordHistory {
            backStack.append(path)
            forwardStack.removeAll()
        }
        path = newPath
        await load()
    }

    func open(_ entry: DeviceEntry) async {
        guard entry.isDirectory else { return }
        await go(to: entry.path)
    }

    func goUp() async {
        guard canGoUp else { return }
        await go(to: parentPath)
    }

    func goBack() async {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        path = previous
        await load()
    }

    func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        path = next
        await load()
    }

    func refresh() async {
        await load()
    }
}
