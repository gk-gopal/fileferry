import Foundation

/// One `sync:` conversation with a device.
///
/// A session is deliberately long-lived: the sync service accepts many
/// requests on a single connection, and reopening it per file is what makes
/// naive implementations crawl on folders with thousands of entries.
public final class SyncSession: Sendable {
    public static let maxChunk = 65536

    let stream: any ByteStream

    public init(stream: any ByteStream) {
        self.stream = stream
    }

    /// Switches a fresh connection to the device, then into sync mode.
    public static func open(server: ADBServer, serial: String) async throws -> SyncSession {
        let stream = try await server.request("host:transport:\(serial)")
        try await ADBServer.send(service: "sync:", over: stream)
        return SyncSession(stream: stream)
    }

    public func close() async {
        try? await stream.write(SyncPacket(.quit, value: 0).encoded())
        await stream.close()
    }

    public func list(_ path: String) async throws -> [SyncEntry] {
        try await stream.write(SyncPacket.request(.lis2, path: path))
        var entries: [SyncEntry] = []
        while true {
            let opcode = String(decoding: try await stream.read(exactly: 4), as: UTF8.self)
            switch opcode {
            case SyncOpcode.dnt2.rawValue:
                let header = try await stream.read(exactly: 68)
                let namelen = try await readUInt32()
                let name = String(decoding: try await stream.read(exactly: Int(namelen)), as: UTF8.self)
                entries.append(SyncEntry.parseDNT2(header: header, name: name))
            case SyncOpcode.done.rawValue:
                // DONE in a list stream is dent-sized, not 8 bytes: adb writes
                // sizeof(sync_dent_v2) with the id swapped for DONE. That is
                // 4 + 68 + 4 = 76, of which the opcode is already consumed.
                _ = try await stream.read(exactly: 72)
                return entries
            case SyncOpcode.fail.rawValue:
                throw ADBError.remote(try await readSyncMessage())
            default:
                throw ADBError.malformedResponse("unexpected sync opcode \(opcode)")
            }
        }
    }

    public func stat(_ path: String) async throws -> SyncEntry {
        try await stream.write(SyncPacket.request(.sta2, path: path))
        let opcode = String(decoding: try await stream.read(exactly: 4), as: UTF8.self)
        switch opcode {
        case SyncOpcode.sta2.rawValue:
            let header = try await stream.read(exactly: 68)
            return SyncEntry.parseDNT2(header: header, name: path)
        case SyncOpcode.fail.rawValue:
            throw ADBError.remote(try await readSyncMessage())
        default:
            throw ADBError.malformedResponse("unexpected sync opcode \(opcode)")
        }
    }

    // MARK: - Internals

    func readUInt32() async throws -> UInt32 {
        let bytes = try await stream.read(exactly: 4)
        return bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    /// A FAIL body: a UInt32 length then the message. The opcode is already consumed.
    func readSyncMessage() async throws -> String {
        let length = try await readUInt32()
        guard length > 0 else { return "unknown error" }
        return String(decoding: try await stream.read(exactly: Int(length)), as: UTF8.self)
    }
}
