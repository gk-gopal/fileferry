import AppKit
import Quartz
import SwiftUI

/// Where previewed phone files are cached.
///
/// Quick Look needs a real file on disk, so phone files are fetched first and
/// keyed by path, size and mtime — a changed file is re-fetched rather than
/// served stale.
enum PreviewCache {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.gopalkannan.conduit/preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func url(forRemote path: String, size: Int64, mtime: Date) -> URL {
        let stamp = Int(mtime.timeIntervalSince1970)
        let key = "\(abs(path.hashValue))-\(size)-\(stamp)"
        let ext = (path as NSString).pathExtension
        return directory.appendingPathComponent(ext.isEmpty ? key : "\(key).\(ext)")
    }
}

/// `QLPreviewView` renders a file directly.
///
/// The system `QLPreviewPanel` was tried first and abandoned: it negotiates
/// through the responder chain via `acceptsPreviewPanelControl(_:)`, and
/// nothing in a SwiftUI hierarchy accepts control, so the panel opens empty.
/// This needs no negotiation.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url as NSURL
        view.refreshPreviewItem()
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// The preview sheet: one file at a time, with keyboard navigation through
/// the rest of the selection.
struct PreviewSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(model.previewTitle)
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                if model.previewURLs.count > 1 {
                    Text("\(model.previewIndex + 1) of \(model.previewURLs.count)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if model.previewURLs.count > 1 {
                    Button { model.previewPrevious() } label: { Image(systemName: "chevron.left") }
                        .disabled(model.previewIndex == 0)
                    Button { model.previewNext() } label: { Image(systemName: "chevron.right") }
                        .disabled(model.previewIndex >= model.previewURLs.count - 1)
                }
                Button("Done") { model.closePreview() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Divider()

            if let url = model.currentPreviewURL {
                QuickLookView(url: url)
                    .id(url)
            } else {
                ContentUnavailableView("Nothing to preview", systemImage: "eye.slash")
            }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 480, idealHeight: 620)
        .onKeyPress(.leftArrow) { model.previewPrevious(); return .handled }
        .onKeyPress(.rightArrow) { model.previewNext(); return .handled }
        .onKeyPress(.escape) { model.closePreview(); return .handled }
        .onKeyPress(.space) { model.closePreview(); return .handled }
    }
}
