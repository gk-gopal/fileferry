import SwiftUI
import TransportKit

/// One side of the window: sidebar, navigation header, file table.
/// Instantiated twice — the Mac and the phone differ only by transport.
struct PaneView: View {
    @Bindable var pane: PaneModel
    @Binding var sidebarVisible: Bool

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(pane: pane)
                    .frame(width: 150)
                Divider()
            }
            VStack(spacing: 0) {
                PaneHeader(pane: pane)
                Divider()
                FileTable(pane: pane)
            }
        }
    }
}

private struct SidebarView: View {
    @Bindable var pane: PaneModel

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
                                .background(
                                    pane.path == favorite.path
                                        ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.35))
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct PaneHeader: View {
    @Bindable var pane: PaneModel

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
            Button { Task { await pane.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.background.secondary)
    }
}

private struct FileTable: View {
    @Bindable var pane: PaneModel

    var body: some View {
        Group {
            if let message = pane.errorMessage {
                ContentUnavailableView {
                    Label("Can't open this folder", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(message)
                }
            } else {
                Table(pane.entries, selection: $pane.selection) {
                    TableColumn("Name") { entry in
                        Label {
                            Text(entry.name).lineLimit(1)
                        } icon: {
                            Image(systemName: entry.isDirectory ? "folder.fill" : icon(for: entry.name))
                                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                        }
                    }
                    TableColumn("Size") { entry in
                        Text(entry.isDirectory
                             ? "—"
                             : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 70, ideal: 80)
                    TableColumn("Modified") { entry in
                        Text(entry.mtime, format: .dateTime.day().month().year())
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .width(min: 90, ideal: 110)
                }
                .tableStyle(.inset)
                .contextMenu(forSelectionType: String.self) { _ in
                    Button("Refresh") { Task { await pane.refresh() } }
                } primaryAction: { selected in
                    // Double-click: enter the folder.
                    guard let path = selected.first,
                          let entry = pane.entries.first(where: { $0.path == path })
                    else { return }
                    Task { await pane.open(entry) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
