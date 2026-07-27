import SwiftUI
import TransportKit

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var macSidebar = true
    @State private var phoneSidebar = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PaneView(pane: model.macPane, model: model, sidebarVisible: $macSidebar)
                    .frame(minWidth: 280)

                Divider()
                ActionColumn(model: model)
                Divider()

                Group {
                    if let phone = model.phonePane {
                        PaneView(pane: phone, model: model, sidebarVisible: $phoneSidebar)
                    } else {
                        ConnectionStateView(model: model)
                    }
                }
                .frame(minWidth: 280)
            }

            if let transfer = model.transfer {
                Divider()
                TransferBar(transfer: transfer) { model.cancelTransfer() }
            } else if let report = model.lastReport {
                Divider()
                ReportBar(report: report) { model.lastReport = nil }
            }
        }
        .frame(minWidth: 900, minHeight: 460)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    macSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("Hide or show the Mac sidebar")
                .keyboardShortcut("1", modifiers: .command)

                Button {
                    phoneSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help("Hide or show the phone sidebar")
                .keyboardShortcut("2", modifiers: .command)
            }
        }
        .sheet(isPresented: $model.isShowingPreview) {
            PreviewSheet(model: model)
        }
        .overlay {
            if model.isPreparingPreview {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Fetching from phone…").font(.callout)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert(
            "Delete \(model.deleteRequest?.entries.count ?? 0) item\(model.deleteRequest?.entries.count == 1 ? "" : "s")?",
            isPresented: Binding(
                get: { model.deleteRequest != nil },
                set: { if !$0 { model.deleteRequest = nil } }
            )
        ) {
            Button("Delete", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.deleteRequest = nil }
        } message: {
            Text(deleteMessage)
        }
        .alert(
            "Transfer problem",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .task { await model.start() }
        // A drive plugged in mid-session should appear without a relaunch.
        .task {
            let center = NSWorkspace.shared.notificationCenter
            for await _ in center.notifications(named: NSWorkspace.didMountNotification) {
                await model.macPane.refreshVolumes()
            }
        }
        .task {
            let center = NSWorkspace.shared.notificationCenter
            for await _ in center.notifications(named: NSWorkspace.didUnmountNotification) {
                await model.macPane.refreshVolumes()
            }
        }
    }

    /// Names the first few targets — "3 items" alone is how people delete the
    /// wrong thing. There is no trash on the phone, so this is irreversible.
    private var deleteMessage: String {
        guard let request = model.deleteRequest else { return "" }
        let names = request.entries.prefix(3).map(\.name).joined(separator: ", ")
        let more = request.entries.count > 3 ? " and \(request.entries.count - 3) more" : ""
        let location = request.pane.isPhone ? "the phone" : "this Mac"
        return "\(names)\(more) will be deleted from \(location). This can't be undone."
    }
}

/// The centre column. Every button names its own direction, so there is no
/// focused-pane rule to learn — which matters because move deletes the
/// original, and direction must never be inferred.
private struct ActionColumn: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            action("arrow.right", "Copy", .toPhone, .copy, prominent: true)
            action("arrow.right.to.line", "Move", .toPhone, .move, destructive: true)
            Divider().frame(width: 34)
            action("arrow.left", "Copy", .toMac, .copy)
            action("arrow.left.to.line", "Move", .toMac, .move, destructive: true)
            Spacer()
        }
        .frame(width: 74)
        .background(.background.secondary)
    }

    private func action(
        _ symbol: String,
        _ label: String,
        _ direction: AppModel.Direction,
        _ mode: TransferMode,
        prominent: Bool = false,
        destructive: Bool = false
    ) -> some View {
        Button {
            model.transfer(direction, mode: mode)
        } label: {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .semibold))
            }
            .frame(width: 54, height: 34)
        }
        .buttonStyle(.bordered)
        .tint(destructive ? .red : (prominent ? .accentColor : .secondary))
        .disabled(!model.canTransfer(direction))
        .help(helpText(direction, mode))
    }

    private func helpText(_ direction: AppModel.Direction, _ mode: TransferMode) -> String {
        let verb = mode == .move ? "Move" : "Copy"
        let target = direction == .toPhone ? "the phone" : "the Mac"
        let caveat = mode == .move ? " The original is deleted only after the copy is verified." : ""
        return "\(verb) the selection to \(target).\(caveat)"
    }
}

private struct TransferBar: View {
    let transfer: ActiveTransfer
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(transfer.label).font(.callout).bold().lineLimit(1)
            if let current = transfer.progress.currentFile {
                Text((current as NSString).lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            ProgressView(value: transfer.progress.fraction)
                .frame(minWidth: 120)
            Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button("Cancel", action: cancel)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.background.secondary)
    }

    private var detail: String {
        let done = ByteCountFormatter.string(
            fromByteCount: transfer.progress.completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(
            fromByteCount: transfer.progress.totalBytes, countStyle: .file)
        return "\(done) of \(total) · \(transfer.progress.completedFiles)/\(transfer.progress.totalFiles) files"
    }
}

private struct ReportBar: View {
    let report: TransferReport
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: report.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(report.succeeded ? .green : .orange)
            Text(summary).font(.callout)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.background.secondary)
    }

    private var summary: String {
        var parts = ["\(report.transferred.count) transferred"]
        if !report.skipped.isEmpty { parts.append("\(report.skipped.count) skipped") }
        if !report.failed.isEmpty { parts.append("\(report.failed.count) failed") }
        let bytes = ByteCountFormatter.string(fromByteCount: report.bytesTransferred, countStyle: .file)
        return parts.joined(separator: ", ") + " — " + bytes
    }
}
