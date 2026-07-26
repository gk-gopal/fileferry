import Foundation
import Testing
@testable import ADBKit

@Test("parses a tab-separated device list")
func parsesDeviceList() {
    let payload = Data("1A2B3C\tdevice\nemulator-5554\toffline\n".utf8)
    let devices = ADBDevice.parseList(payload)
    #expect(devices.count == 2)
    #expect(devices[0] == ADBDevice(serial: "1A2B3C", state: .device))
    #expect(devices[1] == ADBDevice(serial: "emulator-5554", state: .offline))
}

@Test("an empty payload means no devices, not an error")
func parsesEmptyList() {
    #expect(ADBDevice.parseList(Data()).isEmpty)
}

@Test("an unauthorized device is distinguished from a connected one")
func parsesUnauthorized() {
    let devices = ADBDevice.parseList(Data("XYZ\tunauthorized\n".utf8))
    #expect(devices[0].state == .unauthorized)
}

@Test("an unrecognised state does not drop the device")
func parsesUnknownState() {
    let devices = ADBDevice.parseList(Data("XYZ\tbootloader\n".utf8))
    #expect(devices.count == 1)
    #expect(devices[0].state == .unknown)
}

@Test("blank and malformed lines are skipped")
func skipsMalformedLines() {
    let devices = ADBDevice.parseList(Data("\n\nGOOD\tdevice\ngarbage\n".utf8))
    #expect(devices.map(\.serial) == ["GOOD"])
}

@Test("consecutive tracking frames are each decoded")
func readsSuccessiveFrames() async throws {
    let stream = FakeADBServer(script: [
        Data("000b".utf8), Data("AAA\tdevice\n".utf8),      // 11 bytes = 0x0b
        Data("0000".utf8),                                  // all devices gone
    ])
    var frames: [[ADBDevice]] = []
    for _ in 0..<2 {
        frames.append(ADBDevice.parseList(try await readHexPayload(from: stream)))
    }
    #expect(frames[0].map(\.serial) == ["AAA"])
    #expect(frames[1].isEmpty)
}
