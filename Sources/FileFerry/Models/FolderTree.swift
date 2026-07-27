import Foundation
import Observation
import TransportKit

/// A lazily-loaded folder hierarchy for the sidebar.
///
/// Held as a flat map rather than nested node objects: SwiftUI views that
/// contain themselves need type erasure to compile, and a flattened list of
/// visible rows with an indent level avoids that entirely while scrolling
/// better on a folder with hundreds of subdirectories.
@MainActor
@Observable
final class FolderTree {
    struct Row: Identifiable, Equatable {
        let path: String
        let name: String
        let depth: Int
        let isExpanded: Bool
        let isLoading: Bool
        /// Nil until loaded — the disclosure triangle shows optimistically,
        /// because finding out costs a round trip to the device.
        let hasChildren: Bool?

        var id: String { path }
    }

    private let transport: any DeviceTransport
    private(set) var rootPath: String

    private var children: [String: [DeviceEntry]] = [:]
    private var expanded: Set<String> = []
    private var loading: Set<String> = []

    init(transport: any DeviceTransport, rootPath: String) {
        self.transport = transport
        self.rootPath = rootPath
    }

    /// Depth-first walk of everything currently expanded.
    var rows: [Row] {
        var result: [Row] = []
        appendRows(for: rootPath, name: displayName(rootPath), depth: 0, into: &result)
        return result
    }

    private func appendRows(for path: String, name: String, depth: Int, into result: inout [Row]) {
        result.append(
            Row(
                path: path,
                name: name,
                depth: depth,
                isExpanded: expanded.contains(path),
                isLoading: loading.contains(path),
                hasChildren: children[path].map { !$0.isEmpty }
            )
        )
        guard expanded.contains(path), let kids = children[path] else { return }
        for child in kids {
            appendRows(for: child.path, name: child.name, depth: depth + 1, into: &result)
        }
    }

    func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    func toggle(_ path: String) async {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
            await load(path)
        }
    }

    /// Expands every ancestor of `path` so the sidebar follows the pane.
    func reveal(_ path: String) async {
        guard path.hasPrefix(rootPath) else { return }
        var current = rootPath
        let remainder = path.dropFirst(rootPath.count).split(separator: "/")
        expanded.insert(current)
        await load(current)
        for component in remainder {
            current = current.hasSuffix("/") ? current + component : current + "/" + component
            expanded.insert(current)
            await load(current)
        }
    }

    func refresh(_ path: String) async {
        children[path] = nil
        await load(path)
    }

    private func load(_ path: String) async {
        guard children[path] == nil, !loading.contains(path) else { return }
        loading.insert(path)
        defer { loading.remove(path) }
        // Directories only — a sidebar listing every file would be unusable,
        // and an inaccessible folder simply lists as empty over adb.
        let entries = (try? await transport.list(path)) ?? []
        children[path] = entries
            .filter(\.isDirectory)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func displayName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}
