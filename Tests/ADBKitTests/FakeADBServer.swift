import Foundation
@testable import ADBKit

/// An in-memory ByteStream that replays a scripted sequence of server bytes
/// and records everything the client wrote. No sockets, so it is deterministic
/// and safe to run on CI, where no Android device exists.
///
/// Uses the scoped `withLock` form throughout: bare `lock()`/`unlock()` are
/// unavailable from async contexts, since a suspension between them would
/// hold the lock across a thread hop.
final class FakeADBServer: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: Data
    private var _written: [Data] = []
    private var _isClosed = false

    /// - Parameter script: concatenated in order to form the server's byte stream.
    init(script: [Data]) {
        self.inbox = script.reduce(into: Data()) { $0.append($1) }
    }

    func read(exactly count: Int) async throws -> Data {
        try lock.withLock {
            guard count > 0 else { return Data() }
            guard inbox.count >= count else { throw ADBError.connectionClosed }
            defer { inbox.removeFirst(count) }
            return Data(inbox.prefix(count))
        }
    }

    func write(_ data: Data) async throws {
        lock.withLock { _written.append(data) }
    }

    func close() async {
        lock.withLock { _isClosed = true }
    }

    var written: [Data] {
        lock.withLock { _written }
    }

    var isClosed: Bool {
        lock.withLock { _isClosed }
    }

    /// Everything the client wrote, concatenated — convenient for assertions.
    var writtenBytes: Data {
        written.reduce(into: Data()) { $0.append($1) }
    }
}

/// A minimal lock-guarded box. Stands in for `Synchronization.Mutex`, which
/// needs macOS 15 while this package targets macOS 14.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}
