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

// MARK: - Pull

/// A DATA frame: opcode, length, payload.
private func dataFrame(_ payload: Data) -> Data {
    Data("DATA".utf8)
        + Data(withUnsafeBytes(of: UInt32(payload.count).littleEndian, Array.init))
        + payload
}

/// The DONE that ends a RECV stream is 8 bytes — sync_data sized, unlike a list DONE.
private func recvDone() -> Data {
    Data("DONE".utf8) + Data([0, 0, 0, 0])
}

private func scratchURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fileferry-test-\(UUID().uuidString).bin")
}

@Test("pull writes every chunk to disk in order")
func pullsFile() async throws {
    let destination = scratchURL()
    defer { try? FileManager.default.removeItem(at: destination) }

    let stream = FakeADBServer(script: [
        dataFrame(Data("hello ".utf8)),
        dataFrame(Data("world".utf8)),
        recvDone(),
    ])
    let written = try await SyncSession(stream: stream).pull("/sdcard/a.txt", to: destination)

    #expect(written == 11)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "hello world")
}

@Test("pull reports cumulative progress, not per-chunk deltas")
func pullReportsProgress() async throws {
    let destination = scratchURL()
    defer { try? FileManager.default.removeItem(at: destination) }

    let stream = FakeADBServer(script: [
        dataFrame(Data(repeating: 0x41, count: 100)),
        dataFrame(Data(repeating: 0x42, count: 50)),
        recvDone(),
    ])
    let counts = Box<[Int64]>([])
    _ = try await SyncSession(stream: stream).pull("/sdcard/a.bin", to: destination) { total in
        counts.withLock { $0.append(total) }
    }
    #expect(counts.withLock { $0 } == [100, 150])
}

@Test("a zero-byte file pulls successfully")
func pullsEmptyFile() async throws {
    let destination = scratchURL()
    defer { try? FileManager.default.removeItem(at: destination) }

    let stream = FakeADBServer(script: [recvDone()])
    let written = try await SyncSession(stream: stream).pull("/sdcard/empty", to: destination)
    #expect(written == 0)
    #expect(FileManager.default.fileExists(atPath: destination.path))
}

@Test("a FAIL mid-pull deletes the partial file rather than leaving it truncated")
func pullCleansUpPartialFile() async throws {
    let destination = scratchURL()
    defer { try? FileManager.default.removeItem(at: destination) }

    let stream = FakeADBServer(script: [
        dataFrame(Data(repeating: 0x41, count: 64)),
        syncFail("Permission denied"),
    ])
    await #expect(throws: ADBError.self) {
        _ = try await SyncSession(stream: stream).pull("/sdcard/a.bin", to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path),
            "a partial file must never survive a failed pull")
}

// MARK: - Push

/// A sync_status reply: opcode plus a UInt32.
private func syncOkay() -> Data { Data("OKAY".utf8) + Data([0, 0, 0, 0]) }

@Test("push sends the path with its mode, then the file in DATA chunks")
func pushesFile() async throws {
    let source = scratchURL()
    try Data("hello world".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let stream = FakeADBServer(script: [syncOkay()])
    let sent = try await SyncSession(stream: stream).push(source, to: "/sdcard/a.txt", mode: 0o644)

    #expect(sent == 11)

    let written = String(decoding: stream.writtenBytes, as: UTF8.self)
    #expect(written.hasPrefix("SEND"))
    #expect(written.contains("/sdcard/a.txt,644"))
    #expect(written.contains("hello world"))
}

@Test("push splits a file larger than the 64 KB maximum into several chunks")
func pushesLargeFileInChunks() async throws {
    let source = scratchURL()
    try Data(repeating: 0x41, count: 70_000).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let stream = FakeADBServer(script: [syncOkay()])
    let sent = try await SyncSession(stream: stream).push(source, to: "/sdcard/big.bin")

    #expect(sent == 70_000)

    // 70,000 bytes is 65,536 + 4,464, so exactly two DATA writes plus the
    // SEND request and the trailing DONE.
    let dataWrites = stream.written.filter { $0.prefix(4) == Data("DATA".utf8) }
    #expect(dataWrites.count == 2)
    #expect(dataWrites[0].count == 4 + 4 + 65_536)
    #expect(dataWrites[1].count == 4 + 4 + 4_464)
}

@Test("push reports a FAIL from the device")
func pushReportsFailure() async throws {
    let source = scratchURL()
    try Data("x".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let stream = FakeADBServer(script: [syncFail("No space left on device")])
    await #expect(throws: ADBError.self) {
        _ = try await SyncSession(stream: stream).push(source, to: "/sdcard/x.txt")
    }
}
