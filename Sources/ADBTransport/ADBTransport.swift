import Foundation
import ADBKit
import TransportKit

/// Hands out sync sessions, reusing them across many files.
///
/// A `SyncSession` is a single conversation on one socket, so it cannot be
/// shared concurrently. But reopening one per file is what makes naive
/// implementations crawl on a 2,000-file folder, so sessions are pooled and
/// handed back rather than discarded.
actor SessionPool {
    private let server: ADBServer
    private let serial: String
    private let limit: Int
    private var idle: [SyncSession] = []
    private var checkedOut = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(server: ADBServer, serial: String, limit: Int) {
        self.server = server
        self.serial = serial
        self.limit = max(1, limit)
    }

    func acquire() async throws -> SyncSession {
        while idle.isEmpty && checkedOut >= limit {
            await withCheckedContinuation { waiters.append($0) }
        }
        checkedOut += 1
        if let reused = idle.popLast() { return reused }
        do {
            return try await SyncSession.open(server: server, serial: serial)
        } catch {
            release(nil)
            throw error
        }
    }

    /// Pass nil when the session is no longer usable — a protocol error leaves
    /// the stream desynchronised, so it must not go back in the pool.
    func release(_ session: SyncSession?) {
        checkedOut = max(0, checkedOut - 1)
        if let session { idle.append(session) }
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    func closeAll() async {
        for session in idle { await session.close() }
        idle.removeAll()
    }
}

/// The phone side of a transfer, backed by ADBKit.
public struct ADBTransport: DeviceTransport {
    private let pool: SessionPool
    private let shell: ShellSession

    public init(server: ADBServer, serial: String, maxSessions: Int = 2) {
        self.pool = SessionPool(server: server, serial: serial, limit: maxSessions)
        self.shell = ShellSession(server: server, serial: serial)
    }

    public func closeIdleSessions() async {
        await pool.closeAll()
    }

    private func withSession<T>(_ body: (SyncSession) async throws -> T) async throws -> T {
        let session = try await pool.acquire()
        do {
            let result = try await body(session)
            await pool.release(session)
            return result
        } catch {
            // Do not reuse a session whose stream may be mid-frame.
            await pool.release(nil)
            await session.close()
            throw error
        }
    }

    public func list(_ path: String) async throws -> [DeviceEntry] {
        try await withSession { session in
            try await session.list(path)
                .filter { $0.name != "." && $0.name != ".." }
                .map {
                    DeviceEntry(
                        path: join(path, $0.name),
                        size: $0.size,
                        isDirectory: $0.isDirectory,
                        mtime: $0.mtime)
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    public func stat(_ path: String) async throws -> DeviceEntry {
        try await withSession { session in
            let entry = try await session.stat(path)
            // STA2 reports mode 0 for a path that does not exist.
            guard entry.mode != 0 else { throw TransportError.notFound(path) }
            return DeviceEntry(
                path: path, size: entry.size,
                isDirectory: entry.isDirectory, mtime: entry.mtime)
        }
    }

    public func read(_ path: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = try await pool.acquire()
                    do {
                        for try await chunk in session.readChunks(path) {
                            continuation.yield(chunk)
                        }
                        await pool.release(session)
                        continuation.finish()
                    } catch {
                        await pool.release(nil)
                        await session.close()
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func write(_ path: String, from chunks: AsyncThrowingStream<Data, Error>) async throws {
        try await withSession { session in
            try await session.writeChunks(path, from: chunks)
        }
    }

    public func mkdir(_ path: String) async throws {
        let result = try await shell.run("mkdir -p '\(escaped(path))'")
        guard result.succeeded else {
            throw TransportError.io(result.stderr.isEmpty ? "mkdir failed" : result.stderr)
        }
    }

    public func delete(_ path: String) async throws {
        let result = try await shell.run("rm -rf '\(escaped(path))'")
        guard result.succeeded else {
            throw TransportError.io(result.stderr.isEmpty ? "rm failed" : result.stderr)
        }
    }

    /// Free space is a property of the volume, not of one path, so a
    /// destination directory that does not exist yet must not fail preflight.
    /// Walks up to the nearest ancestor `df` can answer for.
    public func freeSpace(at path: String) async throws -> Int64 {
        var candidate = path
        while true {
            let result = try await shell.run("df -k '\(escaped(candidate))'")
            if result.succeeded, let free = ShellSession.parseFreeSpace(result.stdout) {
                return free
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            guard parent != candidate, !parent.isEmpty, parent != "/" else {
                throw TransportError.io("Couldn't read free space at \(path)")
            }
            candidate = parent
        }
    }

    // MARK: - Paths

    private func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// Single-quoted shell arguments only need `'` escaped.
    private func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: #"'\''"#)
    }
}
