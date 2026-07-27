import Foundation
import Testing
import LocalTransport
@testable import TransportKit

private func scratchDirectory() throws -> String {
    let path = NSTemporaryDirectory() + "fileferry-local-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

@Test("free space resolves for a directory that does not exist yet")
func freeSpaceWalksUpToExistingAncestor() async throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }

    // The regression: preflight asks for free space at the destination before
    // the destination has been created, and must not fail because of it.
    let notYetCreated = root + "/does/not/exist/yet"
    let free = try await LocalTransport().freeSpace(at: notYetCreated)
    #expect(free > 0)
}

@Test("round-trips a file through read and write")
func readsAndWrites() async throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }

    let transport = LocalTransport()
    let source = root + "/in.bin"
    let payload = Data(repeating: 0x5A, count: 200_000)   // spans several chunks
    try payload.write(to: URL(fileURLWithPath: source))

    try await transport.write(root + "/nested/out.bin", from: transport.read(source))

    let landed = try Data(contentsOf: URL(fileURLWithPath: root + "/nested/out.bin"))
    #expect(landed == payload)
    #expect(try await transport.stat(root + "/nested/out.bin").size == 200_000)
}

@Test("listing reports directories and sorts naturally")
func listsDirectory() async throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }

    try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
    try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/file10.txt"))
    try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/file2.txt"))

    let entries = try await LocalTransport().list(root)
    #expect(entries.map(\.name) == ["file2.txt", "file10.txt", "sub"])
    #expect(entries.first(where: { $0.name == "sub" })?.isDirectory == true)
}

@Test("an interrupted write leaves no truncated file")
func failedWriteLeavesNothing() async throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }

    let failing = AsyncThrowingStream<Data, Error> { continuation in
        continuation.yield(Data(repeating: 0x41, count: 128))
        continuation.finish(throwing: TransportError.io("link dropped"))
    }
    let destination = root + "/partial.bin"

    await #expect(throws: Error.self) {
        try await LocalTransport().write(destination, from: failing)
    }
    #expect(!FileManager.default.fileExists(atPath: destination))
}

@Test("external volumes never include the boot volume")
func externalVolumesExcludeRoot() async {
    // The boot disk is reachable through Home already, so listing it as a
    // "location" would just be noise. Runs anywhere, including CI, since
    // every machine has exactly one root filesystem.
    let volumes = await LocalTransport().externalVolumes()
    #expect(!volumes.contains { $0.path == "/" })
    for volume in volumes {
        #expect(volume.path.hasPrefix("/Volumes/"), "unexpected volume path \(volume.path)")
        #expect(!volume.name.isEmpty)
    }
}

@Test("stat reports a missing path as not found")
func statMissingPath() async {
    await #expect(throws: TransportError.notFound("/no/such/path")) {
        _ = try await LocalTransport().stat("/no/such/path")
    }
}
