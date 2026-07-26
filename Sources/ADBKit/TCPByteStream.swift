import Foundation
import Network
import os

/// A ByteStream backed by NWConnection. An actor because `buffer` is mutable
/// state that concurrent reads would otherwise race on.
///
/// This is the only type in ADBKit that touches the network, which is what
/// keeps every parser above it testable in memory.
public actor TCPByteStream: ByteStream {
    private let connection: NWConnection
    private var buffer = Data()

    private init(connection: NWConnection) {
        self.connection = connection
    }

    public static func connect(host: String, port: UInt16) async throws -> TCPByteStream {
        let endpoint = NWEndpoint.hostPort(
            host: .init(host),
            port: .init(rawValue: port) ?? .any
        )
        let connection = NWConnection(to: endpoint, using: .tcp)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // NWConnection can report .waiting and then .failed for the same
            // attempt. Resuming a continuation twice is a crash, not a warning.
            let hasResumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ result: Result<Void, Error>) {
                let alreadyResumed = hasResumed.withLock { flag -> Bool in
                    defer { flag = true }
                    return flag
                }
                guard !alreadyResumed else { return }
                cont.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error), .waiting(let error):
                    finish(.failure(ADBError.serverUnavailable(error.localizedDescription)))
                case .cancelled:
                    finish(.failure(ADBError.connectionClosed))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        connection.stateUpdateHandler = nil
        return TCPByteStream(connection: connection)
    }

    public func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        while buffer.count < count {
            let chunk = try await receiveChunk(max: max(count - buffer.count, 8192))
            guard !chunk.isEmpty else { throw ADBError.connectionClosed }
            buffer.append(chunk)
        }
        let result = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return result
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: ADBError.serverUnavailable(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    public func close() {
        connection.cancel()
    }

    private func receiveChunk(max limit: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: limit) { data, _, _, error in
                if let error {
                    cont.resume(throwing: ADBError.serverUnavailable(error.localizedDescription))
                } else {
                    // An empty result with no error means the peer closed;
                    // read(exactly:) turns that into .connectionClosed.
                    cont.resume(returning: data ?? Data())
                }
            }
        }
    }
}
