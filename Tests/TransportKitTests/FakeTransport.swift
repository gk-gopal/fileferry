import Foundation
import TransportKit

/// An in-memory filesystem conforming to DeviceTransport.
///
/// This is what makes the whole transfer engine testable with no phone and no
/// adb — the only way CI can verify anything meaningful.
public final class FakeTransport: DeviceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var directories: Set<String> = ["/"]

    /// Set to fail writes for a given path, to exercise error handling.
    private var failWrites: Set<String> = []
    /// Set to corrupt writes for a path — writes fewer bytes than were sent,
    /// which is exactly what move verification must catch.
    private var truncateWrites: Set<String> = []

    public var capacity: Int64

    public init(capacity: Int64 = .max) {
        self.capacity = capacity
    }

    // MARK: - Seeding

    public func addFile(_ path: String, _ contents: Data) {
        lock.withLock {
            files[path] = contents
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, parent != "/" {
                directories.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
            directories.insert("/")
        }
    }

    public func addFile(_ path: String, size: Int) {
        addFile(path, Data(repeating: 0x41, count: size))
    }

    public func addDirectory(_ path: String) {
        lock.withLock { _ = directories.insert(path) }
    }

    public func contents(of path: String) -> Data? {
        lock.withLock { files[path] }
    }

    public func hasFile(_ path: String) -> Bool {
        lock.withLock { files[path] != nil }
    }

    public func failWrite(at path: String) {
        lock.withLock { _ = failWrites.insert(path) }
    }

    public func truncateWrite(at path: String) {
        lock.withLock { _ = truncateWrites.insert(path) }
    }

    public var allPaths: [String] {
        lock.withLock { files.keys.sorted() }
    }

    // MARK: - DeviceTransport

    public func list(_ path: String) async throws -> [DeviceEntry] {
        try lock.withLock {
            guard directories.contains(path) else { throw TransportError.notFound(path) }
            let prefix = path.hasSuffix("/") ? path : path + "/"

            var entries: [DeviceEntry] = []
            for (filePath, data) in files where filePath.hasPrefix(prefix) {
                let remainder = String(filePath.dropFirst(prefix.count))
                guard !remainder.contains("/") else { continue }
                entries.append(DeviceEntry(path: filePath, size: Int64(data.count), isDirectory: false))
            }
            for directory in directories where directory.hasPrefix(prefix) {
                let remainder = String(directory.dropFirst(prefix.count))
                guard !remainder.isEmpty, !remainder.contains("/") else { continue }
                entries.append(DeviceEntry(path: directory, size: 0, isDirectory: true))
            }
            return entries.sorted { $0.path < $1.path }
        }
    }

    public func stat(_ path: String) async throws -> DeviceEntry {
        try lock.withLock {
            if let data = files[path] {
                return DeviceEntry(path: path, size: Int64(data.count), isDirectory: false)
            }
            if directories.contains(path) {
                return DeviceEntry(path: path, size: 0, isDirectory: true)
            }
            throw TransportError.notFound(path)
        }
    }

    public func read(_ path: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            guard let data = lock.withLock({ files[path] }) else {
                continuation.finish(throwing: TransportError.notFound(path))
                return
            }
            // Deliberately chunked, so progress accounting is exercised.
            var offset = 0
            while offset < data.count {
                let end = min(offset + 1024, data.count)
                continuation.yield(data.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
    }

    public func write(_ path: String, from chunks: AsyncThrowingStream<Data, Error>) async throws {
        if lock.withLock({ failWrites.contains(path) }) {
            throw TransportError.io("write refused at \(path)")
        }
        var accumulated = Data()
        for try await chunk in chunks {
            accumulated.append(chunk)
        }
        if lock.withLock({ truncateWrites.contains(path) }), !accumulated.isEmpty {
            accumulated = accumulated.dropLast(1)
        }
        addFile(path, accumulated)
    }

    public func mkdir(_ path: String) async throws {
        lock.withLock {
            var parent = path
            while !parent.isEmpty, parent != "/" {
                directories.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }

    public func delete(_ path: String) async throws {
        try lock.withLock {
            guard files.removeValue(forKey: path) != nil || directories.remove(path) != nil else {
                throw TransportError.notFound(path)
            }
        }
    }

    public func freeSpace(at path: String) async throws -> Int64 {
        let used = lock.withLock { files.values.reduce(0) { $0 + Int64($1.count) } }
        return capacity == .max ? .max : max(0, capacity - used)
    }
}
