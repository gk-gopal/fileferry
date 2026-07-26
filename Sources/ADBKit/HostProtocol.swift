import Foundation

/// Framing for the adb *host* protocol: requests are prefixed with their byte
/// length as four lowercase hex digits; replies start OKAY or FAIL.
///
/// Note this is ASCII framing. The sync protocol (see `SyncPacket`) uses
/// binary little-endian lengths instead, and confusing the two is the most
/// common way to desynchronise a stream.
public enum HostProtocol {
    public static func encode(_ request: String) throws -> Data {
        let payload = Data(request.utf8)
        guard payload.count <= 0xFFFF else { throw ADBError.requestTooLong }
        return Data(String(format: "%04x", payload.count).utf8) + payload
    }
}

/// Reads a 4-byte status word. Returns normally on OKAY; on FAIL, reads the
/// server's explanation and throws it.
public func readStatus(from stream: any ByteStream) async throws {
    let status = String(decoding: try await stream.read(exactly: 4), as: UTF8.self)
    switch status {
    case "OKAY":
        return
    case "FAIL":
        let message = try await readHexPayload(from: stream)
        throw ADBError.remote(String(decoding: message, as: UTF8.self))
    default:
        throw ADBError.malformedResponse(status)
    }
}

/// Reads a hex-length-prefixed payload.
public func readHexPayload(from stream: any ByteStream) async throws -> Data {
    let field = String(decoding: try await stream.read(exactly: 4), as: UTF8.self)
    guard let length = Int(field, radix: 16) else {
        throw ADBError.malformedLength(field)
    }
    guard length > 0 else { return Data() }
    return try await stream.read(exactly: length)
}
