import Foundation

/// One entry in a directory, on either side of a transfer.
public struct DeviceEntry: Sendable, Equatable, Identifiable {
    public let path: String
    public let size: Int64
    public let isDirectory: Bool
    public let mtime: Date

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, size: Int64, isDirectory: Bool, mtime: Date = Date()) {
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.mtime = mtime
    }
}

/// Anything FileFerry can copy files to and from.
///
/// Both sides of a transfer conform: `LocalTransport` for the Mac and
/// `ADBTransport` for the phone. A transfer is therefore
/// `transfer(from:to:)` over two of these, with no notion of which is which —
/// one code path serves both directions, so there is no separate "upload" and
/// "download" implementation to keep in agreement.
/// A mounted volume that isn't part of the device's main storage — an SD card
/// or USB stick on the phone, an external drive or card reader on the Mac.
public struct VolumeInfo: Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public let isRemovable: Bool

    public var id: String { path }

    public init(name: String, path: String, isRemovable: Bool) {
        self.name = name
        self.path = path
        self.isRemovable = isRemovable
    }
}

public protocol DeviceTransport: Sendable {
    func list(_ path: String) async throws -> [DeviceEntry]
    func stat(_ path: String) async throws -> DeviceEntry
    func read(_ path: String) -> AsyncThrowingStream<Data, Error>
    func write(_ path: String, from chunks: AsyncThrowingStream<Data, Error>) async throws
    func mkdir(_ path: String) async throws
    func delete(_ path: String) async throws
    /// Renames or moves within the same device. Both paths are absolute.
    func rename(_ path: String, to newPath: String) async throws
    func freeSpace(at path: String) async throws -> Int64
    func exists(_ path: String) async -> Bool

    /// Volumes beyond the main storage. Empty by default so a transport that
    /// has no concept of them — the in-memory fake, for one — needs no change.
    func externalVolumes() async -> [VolumeInfo]
}

extension DeviceTransport {
    public func exists(_ path: String) async -> Bool {
        (try? await stat(path)) != nil
    }

    public func externalVolumes() async -> [VolumeInfo] { [] }
}

public enum TransportError: Error, Equatable, Sendable {
    case notFound(String)
    case notADirectory(String)
    case insufficientSpace(needed: Int64, available: Int64)
    case verificationFailed(path: String, expected: Int64, found: Int64)
    case cancelled
    case io(String)
}

extension TransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            "\(path) doesn't exist."
        case .notADirectory(let path):
            "\(path) isn't a folder."
        case .insufficientSpace(let needed, let available):
            "Not enough space: \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) "
                + "needed, \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free."
        case .verificationFailed(let path, let expected, let found):
            "\(path) arrived as \(found) bytes, expected \(expected). The original was left alone."
        case .cancelled:
            "Cancelled."
        case .io(let detail):
            detail
        }
    }
}
