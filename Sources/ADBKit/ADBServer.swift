import Foundation

/// Owns the relationship with the adb server process on 127.0.0.1:5037.
///
/// An existing server is adopted rather than replaced. Killing a server the
/// user started would drop their Android Studio debugging session, so this
/// type never calls `adb kill-server`.
public actor ADBServer {
    public static let defaultPort: UInt16 = 5037

    private let binary: ADBBinary
    private let port: UInt16
    private var didVerify = false

    public init(binary: ADBBinary, port: UInt16 = ADBServer.defaultPort) {
        self.binary = binary
        self.port = port
    }

    /// Connects if a server is already listening, otherwise runs
    /// `adb start-server` once and polls until the socket accepts.
    public func ensureRunning() async throws {
        if didVerify { return }
        if await isListening() {
            didVerify = true
            return
        }
        try startServer()
        // adb start-server returns before the socket is accepting.
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(250))
            if await isListening() {
                didVerify = true
                return
            }
        }
        throw ADBError.serverUnavailable(
            "adb start-server ran but nothing is listening on port \(port). "
                + "Another process may be holding that port."
        )
    }

    /// Opens a connection and sends one service request, leaving the stream
    /// positioned for that service's own protocol.
    public func request(_ service: String) async throws -> any ByteStream {
        try await ensureRunning()
        let stream = try await TCPByteStream.connect(host: "127.0.0.1", port: port)
        do {
            try await ADBServer.send(service: service, over: stream)
            return stream
        } catch {
            await stream.close()
            throw error
        }
    }

    /// Sends a service request and consumes the OKAY.
    public static func send(service: String, over stream: any ByteStream) async throws {
        try await stream.write(try HostProtocol.encode(service))
        try await readStatus(from: stream)
    }

    public static func parseVersionReply(_ payload: Data) -> Int? {
        Int(String(decoding: payload, as: UTF8.self), radix: 16)
    }

    private func isListening() async -> Bool {
        do {
            let stream = try await TCPByteStream.connect(host: "127.0.0.1", port: port)
            defer { Task { await stream.close() } }
            try await ADBServer.send(service: "host:version", over: stream)
            _ = try await readHexPayload(from: stream)
            return true
        } catch {
            return false
        }
    }

    private func startServer() throws {
        let process = Process()
        process.executableURL = binary.url
        process.arguments = ["start-server"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }
}
