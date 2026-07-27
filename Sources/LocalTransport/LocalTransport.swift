import Foundation
import TransportKit

/// The Mac side of a transfer, backed by FileManager.
public struct LocalTransport: DeviceTransport {
    public static let chunkSize = 65536

    public init() {}

    public func list(_ path: String) async throws -> [DeviceEntry] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [])
        } catch {
            throw TransportError.notFound(path)
        }
        return contents.map { child in
            let values = try? child.resourceValues(forKeys: Set(keys))
            return DeviceEntry(
                path: child.path,
                size: Int64(values?.fileSize ?? 0),
                isDirectory: values?.isDirectory ?? false,
                mtime: values?.contentModificationDate ?? Date()
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func stat(_ path: String) async throws -> DeviceEntry {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw TransportError.notFound(path)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return DeviceEntry(
            path: path,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            isDirectory: isDirectory.boolValue,
            mtime: attributes[.modificationDate] as? Date ?? Date()
        )
    }

    public func read(_ path: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: TransportError.io("Couldn't read \(path): \(error.localizedDescription)"))
            }
        }
    }

    public func write(_ path: String, from chunks: AsyncThrowingStream<Data, Error>) async throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)

        let handle = try FileHandle(forWritingTo: url)
        var succeeded = false
        defer {
            try? handle.close()
            // No truncated files survive an interrupted write.
            if !succeeded { try? FileManager.default.removeItem(at: url) }
        }
        for try await chunk in chunks {
            try handle.write(contentsOf: chunk)
        }
        succeeded = true
    }

    public func mkdir(_ path: String) async throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
    }

    public func delete(_ path: String) async throws {
        try FileManager.default.removeItem(atPath: path)
    }

    /// Free space is a property of the volume, not of one path, so a
    /// destination directory that does not exist yet must not fail preflight.
    /// Walks up to the nearest existing ancestor.
    public func freeSpace(at path: String) async throws -> Int64 {
        var candidate = path
        while true {
            if FileManager.default.fileExists(atPath: candidate) {
                let values = try URL(fileURLWithPath: candidate)
                    .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                return values.volumeAvailableCapacityForImportantUsage ?? Int64.max
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            guard parent != candidate, !parent.isEmpty else {
                throw TransportError.notFound(path)
            }
            candidate = parent
        }
    }
}
