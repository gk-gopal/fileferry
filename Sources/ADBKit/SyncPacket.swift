import Foundation

public enum SyncOpcode: String, Sendable {
    case lis2 = "LIS2"
    case dnt2 = "DNT2"
    case sta2 = "STA2"
    case send = "SEND"
    case recv = "RECV"
    case data = "DATA"
    case done = "DONE"
    case okay = "OKAY"
    case fail = "FAIL"
    case quit = "QUIT"
}

/// The sync protocol's unit: a 4-byte ASCII opcode followed by a
/// little-endian UInt32.
///
/// Note this is *binary* framing — unlike the host protocol, whose lengths are
/// ASCII hex. Mixing the two up desynchronises the stream, which presents as a
/// hang rather than a clean error.
public struct SyncPacket: Sendable, Equatable {
    public let opcode: String
    public let value: UInt32

    public init(opcode: String, value: UInt32) {
        self.opcode = opcode
        self.value = value
    }

    public init(_ opcode: SyncOpcode, value: UInt32) {
        self.init(opcode: opcode.rawValue, value: value)
    }

    public func encoded() -> Data {
        var data = Data(opcode.utf8.prefix(4))
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    public static func decode(_ data: Data) throws -> SyncPacket {
        guard data.count == 8 else {
            throw ADBError.malformedResponse("sync packet was \(data.count) bytes, expected 8")
        }
        let bytes = [UInt8](data)
        return SyncPacket(
            opcode: String(decoding: bytes[0..<4], as: UTF8.self),
            value: bytes[4..<8].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        )
    }

    /// An opcode carrying a path: opcode, byte length, then the path itself.
    public static func request(_ opcode: SyncOpcode, path: String) -> Data {
        let pathBytes = Data(path.utf8)
        return SyncPacket(opcode, value: UInt32(pathBytes.count)).encoded() + pathBytes
    }
}
