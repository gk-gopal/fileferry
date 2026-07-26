import Foundation
import Testing
@testable import ADBKit

@Test("encode prefixes the byte length as four lowercase hex digits")
func encodesLengthPrefix() throws {
    let encoded = try HostProtocol.encode("host:version")
    #expect(String(decoding: encoded, as: UTF8.self) == "000chost:version")
}

@Test("encode measures UTF-8 bytes, not characters")
func encodesMultibyteByLength() throws {
    let encoded = try HostProtocol.encode("é")           // 2 bytes in UTF-8
    #expect(String(decoding: encoded, as: UTF8.self) == "0002é")
}

@Test("encode rejects a request longer than the 16-bit length field")
func rejectsOverlongRequest() {
    let tooLong = String(repeating: "a", count: 0x10000)
    #expect(throws: ADBError.requestTooLong) { try HostProtocol.encode(tooLong) }
}

@Test("readStatus returns quietly on OKAY")
func readsOkay() async throws {
    let stream = FakeADBServer(script: [Data("OKAY".utf8)])
    try await readStatus(from: stream)
}

@Test("readStatus throws the server's message on FAIL")
func readsFail() async throws {
    let stream = FakeADBServer(script: [
        Data("FAIL".utf8), Data("0010".utf8), Data("device not found".utf8),  // 16 bytes
    ])
    await #expect(throws: ADBError.remote("device not found")) {
        try await readStatus(from: stream)
    }
}

@Test("readHexPayload reads exactly the advertised number of bytes")
func readsPayload() async throws {
    let stream = FakeADBServer(script: [Data("0005".utf8), Data("hello".utf8)])
    let payload = try await readHexPayload(from: stream)
    #expect(String(decoding: payload, as: UTF8.self) == "hello")
}

@Test("readHexPayload handles a zero-length payload without reading further")
func readsEmptyPayload() async throws {
    let stream = FakeADBServer(script: [Data("0000".utf8)])
    let payload = try await readHexPayload(from: stream)
    #expect(payload.isEmpty)
}

@Test("a non-hex length field is reported as malformed")
func rejectsNonHexLength() async {
    let stream = FakeADBServer(script: [Data("zzzz".utf8)])
    await #expect(throws: ADBError.malformedLength("zzzz")) {
        _ = try await readHexPayload(from: stream)
    }
}
