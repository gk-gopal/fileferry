import Foundation
import Testing
@testable import ADBKit

// MARK: - Frame builders

/// A DNT2 frame: opcode, 68-byte header, namelen, name.
private func dnt2(name: String, size: Int64, mode: UInt32, mtime: Int64) -> Data {
    var frame = Data("DNT2".utf8)
    var header = Data(repeating: 0, count: 68)
    header.replaceSubrange(20..<24, with: withUnsafeBytes(of: mode.littleEndian, Array.init))
    header.replaceSubrange(36..<44, with: withUnsafeBytes(of: size.littleEndian, Array.init))
    header.replaceSubrange(52..<60, with: withUnsafeBytes(of: mtime.littleEndian, Array.init))
    frame.append(header)
    let nameBytes = Data(name.utf8)
    frame.append(contentsOf: withUnsafeBytes(of: UInt32(nameBytes.count).littleEndian, Array.init))
    frame.append(nameBytes)
    return frame
}

/// The DONE that terminates a LIS2 stream is dent-sized, not 8 bytes.
private func listDone() -> Data {
    Data("DONE".utf8) + Data(repeating: 0, count: 72)
}

private func syncFail(_ message: String) -> Data {
    var frame = Data("FAIL".utf8)
    let bytes = Data(message.utf8)
    frame.append(contentsOf: withUnsafeBytes(of: UInt32(bytes.count).littleEndian, Array.init))
    frame.append(bytes)
    return frame
}

// MARK: - Listing

@Test("list decodes every entry until DONE")
func listsDirectory() async throws {
    let stream = FakeADBServer(script: [
        dnt2(name: "DCIM", size: 0, mode: 0o040755, mtime: 1_700_000_000),
        dnt2(name: "big.mp4", size: 5_000_000_000, mode: 0o100644, mtime: 1_700_000_100),
        listDone(),
    ])
    let entries = try await SyncSession(stream: stream).list("/sdcard")
    #expect(entries.count == 2)
    #expect(entries[0].name == "DCIM")
    #expect(entries[0].isDirectory)
    #expect(entries[1].size == 5_000_000_000)
}

@Test("list sends a correctly framed LIS2 request")
func sendsListRequest() async throws {
    let stream = FakeADBServer(script: [listDone()])
    _ = try await SyncSession(stream: stream).list("/sdcard")
    let sent = stream.writtenBytes
    #expect(String(decoding: sent.prefix(4), as: UTF8.self) == "LIS2")
    #expect(String(decoding: sent.dropFirst(8), as: UTF8.self) == "/sdcard")
}

@Test("an empty directory returns an empty array, not an error")
func listsEmptyDirectory() async throws {
    let stream = FakeADBServer(script: [listDone()])
    let entries = try await SyncSession(stream: stream).list("/sdcard/empty")
    #expect(entries.isEmpty)
}

@Test("filenames with spaces, quotes and emoji survive the round trip")
func listsAwkwardFilenames() async throws {
    let awkward = #"my "photo" 🎉 file.jpg"#
    let stream = FakeADBServer(script: [
        dnt2(name: awkward, size: 10, mode: 0o100644, mtime: 0),
        listDone(),
    ])
    let entries = try await SyncSession(stream: stream).list("/sdcard")
    #expect(entries[0].name == awkward)
}

@Test("a FAIL during listing is surfaced as the server's message")
func listReportsFailure() async {
    let stream = FakeADBServer(script: [syncFail("Permission denied")])
    await #expect(throws: ADBError.remote("Permission denied")) {
        _ = try await SyncSession(stream: stream).list("/data")
    }
}

@Test("stat decodes a 64-bit size from an STA2 reply")
func statsFile() async throws {
    var frame = Data("STA2".utf8)
    var header = Data(repeating: 0, count: 68)
    header.replaceSubrange(20..<24, with: withUnsafeBytes(of: UInt32(0o100644).littleEndian, Array.init))
    header.replaceSubrange(36..<44, with: withUnsafeBytes(of: Int64(9_000_000_000).littleEndian, Array.init))
    frame.append(header)

    let stream = FakeADBServer(script: [frame])
    let entry = try await SyncSession(stream: stream).stat("/sdcard/huge.iso")
    #expect(entry.size == 9_000_000_000)
    #expect(entry.name == "/sdcard/huge.iso")
}
