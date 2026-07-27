import Foundation
import Testing
@testable import ADBKit

/// A shell,v2 frame: 1-byte id, 4-byte little-endian length, payload.
private func shellFrame(id: UInt8, _ payload: Data) -> Data {
    var frame = Data([id])
    frame.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).littleEndian, Array.init))
    frame.append(payload)
    return frame
}

@Test("parses available bytes from df -k output")
func parsesFreeSpace() {
    let output = """
    Filesystem     1K-blocks     Used Available Use% Mounted on
    /dev/fuse      122736640 81920000  40816640  67% /storage/emulated
    """
    // 40,816,640 KiB * 1024
    #expect(ShellSession.parseFreeSpace(output) == 41_796_239_360)
}

@Test("returns nil when df prints only a header")
func parsesFreeSpaceMissing() {
    #expect(ShellSession.parseFreeSpace("Filesystem 1K-blocks Used Available Use% Mounted on") == nil)
}

@Test("returns nil for unparseable output rather than guessing")
func parsesFreeSpaceGarbage() {
    #expect(ShellSession.parseFreeSpace("df: /nope: No such file or directory") == nil)
}

@Test("stdout and stderr are kept apart, and the exit code is real")
func separatesStreams() async throws {
    let stream = FakeADBServer(script: [
        shellFrame(id: 1, Data("hello\n".utf8)),
        shellFrame(id: 2, Data("warning\n".utf8)),
        shellFrame(id: 3, Data([7])),
    ])
    let result = try await ShellSession.readResult(from: stream)
    #expect(result.stdout == "hello\n")
    #expect(result.stderr == "warning\n")
    #expect(result.exitCode == 7)
    #expect(!result.succeeded)
}

@Test("output split across frames is reassembled in order")
func reassemblesChunkedOutput() async throws {
    let stream = FakeADBServer(script: [
        shellFrame(id: 1, Data("/sdcard".utf8)),
        shellFrame(id: 1, Data("/Download\n".utf8)),
        shellFrame(id: 3, Data([0])),
    ])
    let result = try await ShellSession.readResult(from: stream)
    #expect(result.stdout == "/sdcard/Download\n")
    #expect(result.succeeded)
}

@Test("a connection that closes without an exit frame still returns what it got")
func toleratesMissingExitFrame() async throws {
    let stream = FakeADBServer(script: [shellFrame(id: 1, Data("partial".utf8))])
    let result = try await ShellSession.readResult(from: stream)
    #expect(result.stdout == "partial")
    #expect(result.exitCode == 0)
}
