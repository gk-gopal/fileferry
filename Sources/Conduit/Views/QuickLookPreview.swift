import AppKit
import Quartz

/// Drives the system Quick Look panel.
///
/// Phone files have to be fetched before they can be previewed — Quick Look
/// needs a real file on disk — so they are pulled to a cache directory keyed
/// by path, size and mtime, and reused on a second look.
@MainActor
final class QuickLookPreview: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookPreview()

    private var items: [URL] = []

    static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.gopalkannan.conduit/preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        items = urls
        panel.dataSource = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    /// Where a remote file should be cached. Including size and mtime means a
    /// changed file is re-fetched rather than served stale.
    static func cacheURL(forRemote path: String, size: Int64, mtime: Date) -> URL {
        let stamp = Int(mtime.timeIntervalSince1970)
        let key = "\(abs(path.hashValue))-\(size)-\(stamp)"
        let ext = (path as NSString).pathExtension
        let name = ext.isEmpty ? key : "\(key).\(ext)"
        return cacheDirectory.appendingPathComponent(name)
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items[index] as NSURL
    }
}
