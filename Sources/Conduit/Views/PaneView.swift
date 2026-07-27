import SwiftUI
import TransportKit
import UniformTypeIdentifiers

/// One side of the window: sidebar, navigation header, file table.
/// Instantiated twice — the Mac and the phone differ only by transport.
struct PaneView: View {
    @Bindable var pane: PaneModel
    @Bindable var model: AppModel
    @Binding var sidebarVisible: Bool

    @State private var showingNewFolder = false
    @State private var newFolderName = ""

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(pane: pane, model: model)
                    .frame(width: 150)
                Divider()
            }
            VStack(spacing: 0) {
                PaneHeader(pane: pane, model: model, showingNewFolder: $showingNewFolder)
                Divider()
                FileTable(pane: pane, model: model)
            }
        }
        .sheet(isPresented: $showingNewFolder) {
            NewFolderSheet(
                location: pane.path,
                name: $newFolderName,
                create: {
                    model.createFolder(named: newFolderName, in: pane)
                    newFolderName = ""
                    showingNewFolder = false
                },
                cancel: {
                    newFolderName = ""
                    showingNewFolder = false
                }
            )
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Bindable var pane: PaneModel
    @Bindable var model: AppModel
    @State private var dropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pane.isPhone {
                Text(pane.title)
                    .font(.caption).bold()
                    .padding(.horizontal, 12).padding(.top, 10)
                if let free = pane.freeSpace {
                    Text("\(format(free)) free")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.bottom, 6)
                }
                Divider().padding(.vertical, 4)
            }

            Text("Favourites")
                .font(.caption2).bold().foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.vertical, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(pane.favorites) { favorite in
                        Button {
                            Task { await pane.go(to: favorite.path) }
                        } label: {
                            Label(favorite.name, systemImage: favorite.symbol)
                                .font(.callout)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(background(for: favorite), in: RoundedRectangle(cornerRadius: 5))
                                .overlay {
                                    if dropTarget == favorite.path {
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(Color.accentColor, style: .init(lineWidth: 2, dash: [4, 3]))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        // Dropping onto a favourite sends files straight there,
                        // without either pane having to navigate.
                        .dropDestination(for: String.self) { payloads, _ in
                            model.handleDrop(payloads, onto: pane, directory: favorite.path)
                            return true
                        } isTargeted: { targeted in
                            dropTarget = targeted ? favorite.path : nil
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.35))
    }

    private func background(for favorite: Favorite) -> Color {
        pane.path == favorite.path ? Color.accentColor.opacity(0.18) : .clear
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Header

private struct PaneHeader: View {
    @Bindable var pane: PaneModel
    @Bindable var model: AppModel
    @Binding var showingNewFolder: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { Task { await pane.goBack() } } label: { Image(systemName: "chevron.left") }
                .disabled(!pane.canGoBack)
            Button { Task { await pane.goForward() } } label: { Image(systemName: "chevron.right") }
                .disabled(!pane.canGoForward)
            Button { Task { await pane.goUp() } } label: { Image(systemName: "chevron.up") }
                .disabled(!pane.canGoUp)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(pane.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Text("›").foregroundStyle(.tertiary)
                        }
                        Button(crumb.name) { Task { await pane.go(to: crumb.path) } }
                            .buttonStyle(.plain)
                            .foregroundStyle(
                                index == pane.breadcrumbs.count - 1 ? .primary : Color.accentColor)
                    }
                }
                .font(.system(.caption, design: .monospaced))
            }

            Spacer(minLength: 4)

            if pane.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text("\(pane.entries.count) items")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }

            SortMenu(pane: pane)

            Button { showingNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .help("New folder in \(pane.path)")

            Button { Task { await pane.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.background.secondary)
    }
}

private struct SortMenu: View {
    @Bindable var pane: PaneModel

    private struct Option: Identifiable {
        let label: String
        let comparator: KeyPathComparator<DeviceEntry>
        var id: String { label }
    }

    var body: some View {
        Menu {
            Picker("Sort by", selection: sortKeyBinding) {
                Text("Name").tag("name")
                Text("Size").tag("size")
                Text("Date Modified").tag("mtime")
            }
            .pickerStyle(.inline)

            Divider()

            Picker("Order", selection: sortAscendingBinding) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort — folders always come first")
    }

    private var currentKey: String {
        guard let first = pane.sortOrder.first else { return "name" }
        if first.keyPath == \DeviceEntry.size { return "size" }
        if first.keyPath == \DeviceEntry.mtime { return "mtime" }
        return "name"
    }

    private var currentlyAscending: Bool {
        pane.sortOrder.first?.order == .forward
    }

    private var sortKeyBinding: Binding<String> {
        Binding(get: { currentKey }, set: { apply(key: $0, ascending: currentlyAscending) })
    }

    private var sortAscendingBinding: Binding<Bool> {
        Binding(get: { currentlyAscending }, set: { apply(key: currentKey, ascending: $0) })
    }

    private func apply(key: String, ascending: Bool) {
        let order: SortOrder = ascending ? .forward : .reverse
        pane.sortOrder = switch key {
        case "size": [KeyPathComparator(\DeviceEntry.size, order: order)]
        case "mtime": [KeyPathComparator(\DeviceEntry.mtime, order: order)]
        default: [KeyPathComparator(\DeviceEntry.name, order: order)]
        }
    }
}

// MARK: - Table

private struct FileTable: View {
    @Bindable var pane: PaneModel
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if let message = pane.errorMessage {
                ContentUnavailableView {
                    Label("Can't open this folder", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(message)
                }
            } else {
                table
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, style: .init(lineWidth: 3, dash: [7, 5]))
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: String.self) { payloads, _ in
            model.handleDrop(payloads, onto: pane)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var table: some View {
        Table(pane.sortedEntries, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                Label {
                    Text(entry.name).lineLimit(1)
                } icon: {
                    Image(systemName: entry.isDirectory ? "folder.fill" : icon(for: entry.name))
                        .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                }
                // Mac rows travel as file paths, so a drag into Finder or onto
                // the phone pane both work. Phone rows carry a scheme prefix.
                .draggable(payload(for: entry))
            }
            TableColumn("Size", value: \.size) { entry in
                Text(entry.isDirectory
                     ? "—"
                     : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 80)
            TableColumn("Modified", value: \.mtime) { entry in
                Text(entry.mtime, format: .dateTime.day().month().year())
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .width(min: 90, ideal: 110)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: String.self) { selected in
            if !selected.isEmpty {
                Button("Quick Look") { model.preview(pane) }
                Divider()
            }
            Button("Refresh") { Task { await pane.refresh() } }
        } primaryAction: { selected in
            // Double-click: enter a folder, or preview a file.
            guard let path = selected.first,
                  let entry = pane.entries.first(where: { $0.path == path })
            else { return }
            if entry.isDirectory {
                Task { await pane.open(entry) }
            } else {
                model.preview(pane)
            }
        }
        .onKeyPress(.space) {
            model.preview(pane)
            return .handled
        }
    }

    private func payload(for entry: DeviceEntry) -> String {
        pane.dragPayload(for: entry)
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": "photo"
        case "mp4", "mov", "mkv", "avi", "webm": "film"
        case "mp3", "m4a", "wav", "flac", "ogg": "music.note"
        case "pdf": "doc.richtext"
        case "zip", "gz", "tar", "7z", "rar": "doc.zipper"
        case "apk": "shippingbox"
        default: "doc"
        }
    }
}

// MARK: - New folder

private struct NewFolderSheet: View {
    let location: String
    @Binding var name: String
    let create: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Folder").font(.headline)
            Text("In \(location)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)

            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { if isValid { create() } }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
    }

    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("/")
    }
}
