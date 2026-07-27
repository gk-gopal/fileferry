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
    @State private var showingGoToPath = false
    @State private var goToPathText = ""

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(pane: pane, model: model)
                    .frame(width: 200)
                Divider()
            }
            VStack(spacing: 0) {
                PaneHeader(
                    pane: pane, model: model,
                    showingNewFolder: $showingNewFolder,
                    showingGoToPath: $showingGoToPath,
                    goToPathText: $goToPathText)
                Divider()
                FileTable(pane: pane, model: model)
                if pane.showPreviewStrip, pane.singleSelectedFile != nil {
                    Divider()
                    PreviewStrip(pane: pane)
                }
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
        .sheet(isPresented: $showingGoToPath) {
            GoToPathSheet(
                title: pane.isPhone ? "On \(pane.title)" : "On this Mac",
                path: $goToPathText,
                go: {
                    let expanded = goToPathText.hasPrefix("~")
                        ? NSString(string: goToPathText).expandingTildeInPath
                        : goToPathText
                    showingGoToPath = false
                    Task { await pane.go(to: expanded) }
                },
                cancel: { showingGoToPath = false }
            )
        }
        .onAppear { goToPathText = pane.path }
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

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    sectionHeader("Favourites")
                    ForEach(pane.favorites) { favorite in
                        Button {
                            Task { await pane.go(to: favorite.path) }
                        } label: {
                            Label(favorite.name, systemImage: favorite.symbol)
                                .font(.callout)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(background(for: favorite.path), in: RoundedRectangle(cornerRadius: 5))
                                .overlay { dropOutline(favorite.path) }
                        }
                        .buttonStyle(.plain)
                        // Dropping onto a favourite sends files straight there,
                        // without either pane having to navigate.
                        .modifier(FavoriteDropModifier(
                            pane: pane, model: model, directory: favorite.path,
                            isTargeted: binding(for: favorite.path)))
                    }

                    if !pane.volumes.isEmpty {
                        sectionHeader(pane.isPhone ? "Storage" : "Locations")
                        ForEach(pane.volumes) { volume in
                            Button {
                                Task { await pane.go(to: volume.path) }
                            } label: {
                                Label(
                                    volume.name,
                                    systemImage: volume.isRemovable ? "sdcard" : "externaldrive"
                                )
                                .font(.callout).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(background(for: volume.path), in: RoundedRectangle(cornerRadius: 5))
                                .overlay { dropOutline(volume.path) }
                            }
                            .buttonStyle(.plain)
                            // Drop straight onto an external drive — no need to
                            // stage files through the Mac's internal disk.
                            .modifier(FavoriteDropModifier(
                                pane: pane, model: model, directory: volume.path,
                                isTargeted: binding(for: volume.path)))
                        }
                    }

                    if !pane.pinnedFavorites.isEmpty {
                        sectionHeader("Pinned")
                        ForEach(pane.pinnedFavorites) { pin in
                            Button {
                                Task { await pane.go(to: pin.path) }
                            } label: {
                                Label(pin.name, systemImage: pin.symbol)
                                    .font(.callout).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(background(for: pin.path), in: RoundedRectangle(cornerRadius: 5))
                                    .overlay { dropOutline(pin.path) }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Unpin") {
                                    Preferences.shared.togglePin(pin.path, isPhone: pane.isPhone)
                                }
                            }
                            .modifier(FavoriteDropModifier(
                                pane: pane, model: model, directory: pin.path,
                                isTargeted: binding(for: pin.path)))
                        }
                    }

                    sectionHeader("Folders")
                    FolderTreeView(pane: pane, model: model, dropTarget: $dropTarget)
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.35))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption2).bold().foregroundStyle(.tertiary)
            .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func background(for path: String) -> Color {
        pane.path == path ? Color.accentColor.opacity(0.18) : .clear
    }

    @ViewBuilder
    private func dropOutline(_ path: String) -> some View {
        if dropTarget == path {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor, style: .init(lineWidth: 2, dash: [4, 3]))
        }
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { dropTarget == path },
            set: { dropTarget = $0 ? path : nil }
        )
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The real folder hierarchy, lazily loaded.
///
/// Rendered from a flattened row list with an indent level rather than nested
/// views: a SwiftUI view containing itself needs type erasure to compile, and
/// flattening scrolls better on a folder with hundreds of subdirectories.
private struct FolderTreeView: View {
    @Bindable var pane: PaneModel
    @Bindable var model: AppModel
    @Binding var dropTarget: String?

    var body: some View {
        ForEach(pane.tree.rows) { row in
            HStack(spacing: 2) {
                Button {
                    Task { await pane.tree.toggle(row.path) }
                } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                        .opacity(row.hasChildren == false ? 0.15 : 1)
                }
                .buttonStyle(.plain)
                .disabled(row.hasChildren == false)

                Button {
                    Task { await pane.go(to: row.path) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: pane.path == row.path ? "folder.fill" : "folder")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                        Text(row.name).font(.caption).lineLimit(1).truncationMode(.middle)
                        if row.isLoading {
                            ProgressView().controlSize(.mini).scaleEffect(0.6)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4).padding(.vertical, 3)
                    .background(
                        pane.path == row.path ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 4)
                    )
                    .overlay {
                        if dropTarget == row.path {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.accentColor, style: .init(lineWidth: 2, dash: [4, 3]))
                        }
                    }
                }
                .buttonStyle(.plain)
                // Dropping onto any folder in the tree copies straight there.
                .modifier(FavoriteDropModifier(
                    pane: pane, model: model, directory: row.path,
                    isTargeted: Binding(
                        get: { dropTarget == row.path },
                        set: { dropTarget = $0 ? row.path : nil })))
            }
            .padding(.leading, CGFloat(row.depth) * 11)
        }
    }
}

/// A pane accepts whichever payload the *other* side produces: the phone takes
/// file URLs, the Mac takes prefixed phone paths.
private struct FavoriteDropModifier: ViewModifier {
    let pane: PaneModel
    let model: AppModel
    let directory: String?
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if pane.isPhone {
            content.dropDestination(for: URL.self) { urls, _ in
                model.dropFiles(urls, onto: pane, directory: directory)
                return true
            } isTargeted: { isTargeted = $0 }
        } else {
            content.dropDestination(for: String.self) { payloads, _ in
                model.dropPhonePaths(payloads, onto: pane, directory: directory)
                return true
            } isTargeted: { isTargeted = $0 }
        }
    }
}

// MARK: - Header

private struct PaneHeader: View {
    @Bindable var pane: PaneModel
    @Bindable var model: AppModel
    @Binding var showingNewFolder: Bool
    @Binding var showingGoToPath: Bool
    @Binding var goToPathText: String

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

            Button {
                pane.showPreviewStrip.toggle()
                pane.refreshPreview()
            } label: {
                Image(systemName: pane.showPreviewStrip ? "eye" : "eye.slash")
            }
            .help(pane.showPreviewStrip ? "Hide the preview" : "Show a preview when one file is selected")

            Button {
                pane.togglePinForCurrentFolder()
            } label: {
                Image(systemName: pane.isCurrentFolderPinned ? "pin.fill" : "pin")
            }
            .help(pane.isCurrentFolderPinned ? "Unpin this folder" : "Pin this folder to the sidebar")

            Button {
                goToPathText = pane.path
                showingGoToPath = true
            } label: {
                Image(systemName: "arrow.right.to.line")
            }
            .help("Go to a folder by path")

            Button { showingNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .help("New folder in \(pane.path)")

            Button { model.requestRename(in: pane) } label: { Image(systemName: "pencil") }
                .disabled(pane.selection.count != 1 || model.isBusy)
                .help("Rename the selected item")

            Button { model.requestDelete(in: pane) } label: { Image(systemName: "trash") }
                .disabled(pane.selection.isEmpty || model.isBusy)
                .help("Delete the selection")

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
        .modifier(FavoriteDropModifier(
            pane: pane, model: model, directory: nil, isTargeted: $isDropTargeted))
    }

    private var table: some View {
        Table(of: DeviceEntry.self, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                Label {
                    Text(entry.name).lineLimit(1)
                } icon: {
                    Image(systemName: entry.isDirectory ? "folder.fill" : icon(for: entry.name))
                        .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                }
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
        } rows: {
            ForEach(pane.sortedEntries) { entry in
                // Drag belongs on the row, not on cell content. A .draggable
                // inside a TableColumn swallows the mouse-down, which stops
                // rows from being selectable at all.
                TableRow(entry)
                    .itemProvider { itemProvider(for: entry) }
            }
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: String.self) { selected in
            if !selected.isEmpty {
                Button("Open") { activateSelection() }
                Button("Quick Look") { model.preview(pane) }
                Divider()
                Button("Rename…") { model.requestRename(in: pane) }
                    .disabled(selected.count != 1)
                Button("Delete…", role: .destructive) { model.requestDelete(in: pane) }
                Divider()
            }
            Button("Refresh") { Task { await pane.refresh() } }
        } primaryAction: { _ in
            activateSelection()
        }
        .onKeyPress(.space) { activateSelection(); return .handled }
        .onKeyPress(.return) { activateSelection(); return .handled }
        // Selecting one file previews it automatically; the fetch is debounced
        // so holding an arrow key does not queue one pull per row.
        .onChange(of: pane.selection) {
            pane.refreshPreview()
        }
    }

    /// Space, Return, or double-click: enter the folder, or open the file.
    private func activateSelection() {
        guard let path = pane.selection.first,
              let entry = pane.entries.first(where: { $0.path == path })
        else { return }
        Task { await pane.activate(entry) }
    }

    /// Mac rows vend a file URL, so dragging to Finder is a real file drag
    /// rather than a text clipping. Phone rows have no local URL, so they vend
    /// a prefixed string that only this app understands.
    private func itemProvider(for entry: DeviceEntry) -> NSItemProvider {
        if pane.isPhone {
            return NSItemProvider(object: pane.dragPayload(for: entry) as NSString)
        }
        return NSItemProvider(object: URL(fileURLWithPath: entry.path) as NSURL)
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

// MARK: - Inline preview

/// Appears automatically when exactly one file is selected.
private struct PreviewStrip: View {
    @Bindable var pane: PaneModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let entry = pane.singleSelectedFile {
                    Text(entry.name).font(.caption).bold().lineLimit(1).truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if pane.isPreviewLoading {
                    ProgressView().controlSize(.small)
                }
                Button { pane.showPreviewStrip = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide the preview")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)

            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 210)
        .background(.background.secondary)
    }

    @ViewBuilder
    private var content: some View {
        if let failure = pane.previewError {
            placeholder(failure, symbol: "exclamationmark.triangle")
        } else if let large = pane.previewTooLarge {
            VStack(spacing: 8) {
                Text("\(ByteCountFormatter.string(fromByteCount: large.size, countStyle: .file)) — too large to preview automatically")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Preview Anyway") { pane.forcePreview(large) }
                    .controlSize(.small)
            }
        } else if let url = pane.previewURL {
            QuickLookView(url: url).id(url)
        } else if pane.isPreviewLoading {
            placeholder("Fetching from phone…", symbol: "arrow.down.circle")
        } else {
            placeholder("No preview available", symbol: "eye.slash")
        }
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tertiary)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
