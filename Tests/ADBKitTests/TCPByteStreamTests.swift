import Foundation
import Network
import Testing
@testable import ADBKit

@Test("TCPByteStream round-trips bytes against a local listener")
func roundTripsOverLoopback() async throws {
    let listener = try NWListener(using: .tcp, on: .any)
    let ready = AsyncStream<UInt16>.makeStream()

    listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port {
            ready.continuation.yield(port.rawValue)
            ready.continuation.finish()
        }
    }
    // Hold the accepted connection until the test finishes, so it is not
    // deallocated mid-echo.
    let accepted = Box<NWConnection?>(nil)
    listener.newConnectionHandler = { connection in
        accepted.withLock { $0 = connection }
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { data, _, _, _ in
            if let data { connection.send(content: data, completion: .idempotent) }
        }
    }
    listener.start(queue: .global())
    defer { listener.cancel() }

    var iterator = ready.stream.makeAsyncIterator()
    guard let port = await iterator.next() else {
        Issue.record("listener never became ready")
        return
    }

    let stream = try await TCPByteStream.connect(host: "127.0.0.1", port: port)
    try await stream.write(Data("hello".utf8))
    let echoed = try await stream.read(exactly: 5)
    #expect(String(decoding: echoed, as: UTF8.self) == "hello")
    await stream.close()
}

@Test("connecting to a closed port fails rather than hanging")
func failsOnClosedPort() async {
    // Port 1 is reserved and never listening.
    await #expect(throws: ADBError.self) {
        _ = try await TCPByteStream.connect(host: "127.0.0.1", port: 1)
    }
}
