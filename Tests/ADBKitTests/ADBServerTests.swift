import Foundation
import Testing
@testable import ADBKit

@Test("ADBError carries a user-facing message")
func errorHasDescription() {
    let error = ADBError.binaryTooOld(found: "33.0.0", required: "34.0.0")
    #expect(error.errorDescription?.contains("33.0.0") == true)
    #expect(error.errorDescription?.contains("34.0.0") == true)
}

@Test("the host:version reply is hexadecimal")
func parsesServerVersion() {
    #expect(ADBServer.parseVersionReply(Data("0029".utf8)) == 0x29)
    #expect(ADBServer.parseVersionReply(Data("nope".utf8)) == nil)
}

@Test("a service request is sent with a hex length prefix")
func sendsServiceRequest() async throws {
    let stream = FakeADBServer(script: [Data("OKAY".utf8)])
    try await ADBServer.send(service: "host:devices", over: stream)
    #expect(String(decoding: stream.writtenBytes, as: UTF8.self) == "000chost:devices")
}
