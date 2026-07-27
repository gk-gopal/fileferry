import Foundation
import Observation
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
