import Foundation
import Testing
@testable import ADBKit

@Test("a sync packet is a 4-byte opcode plus a little-endian UInt32")
func encodesPacket() {
    let encoded = SyncPacket(opcode: "DATA", value: 5).encoded()
    #expect(Array(encoded) == [0x44, 0x41, 0x54, 0x41, 0x05, 0x00, 0x00, 0x00])
}

@Test("packets round-trip through decode")
func decodesPacket() throws {
    let packet = try SyncPacket.decode(Data([0x44, 0x4F, 0x4E, 0x45, 0x00, 0x00, 0x00, 0x00]))
    #expect(packet.opcode == "DONE")
    #expect(packet.value == 0)
}

@Test("decoding rejects anything that is not exactly eight bytes")
func rejectsShortPacket() {
    #expect(throws: ADBError.self) { try SyncPacket.decode(Data([0x44, 0x41])) }
}

@Test("a path request is the opcode, the path length, then the path bytes")
func encodesPathRequest() {
    let request = SyncPacket.request(.lis2, path: "/sdcard")
    #expect(Array(request.prefix(4)) == Array("LIS2".utf8))
    #expect(Array(request[4..<8]) == [0x07, 0x00, 0x00, 0x00])
    #expect(String(decoding: request.dropFirst(8), as: UTF8.self) == "/sdcard")
}

@Test("path length counts UTF-8 bytes, not characters")
func encodesMultibytePathRequest() {
    let request = SyncPacket.request(.lis2, path: "/sdcard/日本")  // 8 + 6 = 14 bytes
    #expect(Array(request[4..<8]) == [0x0E, 0x00, 0x00, 0x00])
}

@Test("a DNT2 header yields a 64-bit size and a real mtime")
func parsesDirectoryEntry() {
    var header = Data(repeating: 0, count: 68)
    header.replaceSubrange(20..<24, with: withUnsafeBytes(of: UInt32(0o100644).littleEndian, Array.init))
    header.replaceSubrange(36..<44, with: withUnsafeBytes(of: Int64(5_000_000_000).littleEndian, Array.init))
    header.replaceSubrange(52..<60, with: withUnsafeBytes(of: Int64(1_700_000_000).littleEndian, Array.init))

    let entry = SyncEntry.parseDNT2(header: header, name: "big.mp4")
    #expect(entry.name == "big.mp4")
    #expect(entry.size == 5_000_000_000)          // the whole point of v2: > 4 GB
    #expect(entry.mtime == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(!entry.isDirectory)
}

@Test("the directory bit is read out of the mode field")
func detectsDirectory() {
    var header = Data(repeating: 0, count: 68)
    header.replaceSubrange(20..<24, with: withUnsafeBytes(of: UInt32(0o040755).littleEndian, Array.init))
    let entry = SyncEntry.parseDNT2(header: header, name: "DCIM")
    #expect(entry.isDirectory)
}
