import Foundation

/// A bidirectional byte pipe. Abstracting this is what lets every parser in
/// ADBKit be tested in memory, with no socket and no phone.
public protocol ByteStream: Sendable {
    /// Reads exactly `count` bytes, or throws `.connectionClosed` if the peer
    /// hangs up first. Never returns a short read.
    func read(exactly count: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}
