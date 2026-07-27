import Foundation
import Testing
@testable import TransportKit

private func makePair() -> (FakeTransport, FakeTransport) {
    (FakeTransport(), FakeTransport())
}

// MARK: - Copying

@Test("copies a single file and leaves the original in place")
func copiesOneFile() async throws {
    let (source, destination) = makePair()
    source.addFile("/a/hello.txt", Data("hello world".utf8))
    destination.addDirectory("/b")

    let report = try await TransferEngine().run(
        TransferJob(sources: ["/a/hello.txt"], destinationDirectory: "/b"),
        from: source, to: destination)

    #expect(report.succeeded)
    #expect(report.transferred.count == 1)
    #expect(destination.contents(of: "/b/hello.txt") == Data("hello world".utf8))
    #expect(source.hasFile("/a/hello.txt"), "copy must not remove the original")
}

@Test("expands a nested directory depth-first")
func copiesNestedDirectory() async throws {
    let (source, destination) = makePair()
    source.addFile("/a/one.txt", size: 10)
    source.addFile("/a/sub/two.txt", size: 20)
    source.addFile("/a/sub/deeper/three.txt", size: 30)
    destination.addDirectory("/b")

    let report = try await TransferEngine().run(
        TransferJob(sources: ["/a"], destinationDirectory: "/b"),
        from: source, to: destination)

    #expect(report.transferred.count == 3)
    #expect(destination.allPaths == ["/b/a/one.txt", "/b/a/sub/deeper/three.txt", "/b/a/sub/two.txt"])
    #expect(report.bytesTransferred == 60)
}

@Test("a zero-byte file transfers without special casing")
func copiesEmptyFile() async throws {
    let (source, destination) = makePair()
    source.addFile("/a/empty.bin", Data())
    destination.addDirectory("/b")

    let report = try await TransferEngine().run(
        TransferJob(sources: ["/a/empty.bin"], destinationDirectory: "/b"),
        from: source, to: destination)

    #expect(report.succeeded)
    #expect(destination.contents(of: "/b/empty.bin") == Data())
}

@Test("filenames with spaces, quotes and emoji survive")
func copiesAwkwardNames() async throws {
    let (source, destination) = makePair()
    let awkward = #"my "photo" 🎉 file.jpg"#
    source.addFile("/a/\(awkward)", size: 5)
    destination.addDirectory("/b")

    _ = try await TransferEngine().run(
        TransferJob(sources: ["/a/\(awkward)"], destinationDirectory: "/b"),
        from: source, to: destination)

    #expect(destination.hasFile("/b/\(awkward)"))
}

// MARK: - Moving and verification

@Test("move deletes the original only after the destination verifies")
func moveDeletesOriginal() async throws {
    let (source, destination) = makePair()
    source.addFile("/a/doc.pdf", size: 2048)
    destination.addDirectory("/b")

    let report = try await TransferEngine().run(
        TransferJob(sources: ["/a/doc.pdf"], destinationDirectory: "/b", mode: .move),
        from: source, to: destination)

    #expect(report.succeeded)
    #expect(destination.hasFile("/b/doc.pdf"))
    #expect(!source.hasFile("/a/doc.pdf"))
}

@Test("a truncated write fails the move and preserves the original")
func moveKeepsOriginalOnVerificationFailure() async throws {
    let (source, destination) = makePair()
    source.addFile("/a/precious.raw", size: 4096)
    destination.addDirectory("/b")
    destination.truncateWrite(at: "/b/precious.raw")   // one byte short

    let report = try await TransferEngine().run(
        TransferJob(sources: ["/a/precious.raw"], destinationDirectory: "/b", mode: .move),
        from: source, to: destination)

    #expect(!report.succeeded)
    #expect(report.failed.count == 1)
    #expect(report.failed[0].reason.contains("original was left alone"))
    #expect(source.hasFile("/a/precious.raw"),
            "a failed verification must never cost the user their file")
}

@Test("a failed write during a move also preserves the original")
func moveKeepsOriginalOnWriteFailure() async throws {
    let (source, destination) = makePair()
    source.addFile("/a/precious.raw", size: 100)
    destination.addDirectory("/b")
    destination.failWrite(at: "/b/precious.raw")

    let report = try await TransferEngine().run(
        TransferJob(sources: ["/a/precious.raw"], destinationDirectory: "/b", mode: .move),
        from: source, to: destination)

    #expect(!report.succeeded)
    #expect(source.hasFile("/a/precious.raw"))
}

// MARK: - Failure isolation

@Test("one failing file does not abort the rest of the batch")
func perItemFailureDoesNotAbortBatch() async throws {
    let (source, destination) = makePair()
    for index in 1...5 {
        source.addFile("/a/file\(index).bin", size: 100)
    }
    destination.addDirectory("/b")
    destination.failWrite(at: "/b/a/file3.bin")

    let report = try await TransferEngine().run(
        TransferJob(sources: ["/a"], destinationDirectory: "/b"),
        from: source, to: destination)

    #expect(report.transferred.count == 4)
    #expect(report.failed.count == 1)
    #expect(report.failed[0].item.destination == "/b/a/file3.bin")
}

// MARK: - Preflight

@Test("insufficient space fails before any byte moves")
func preflightRejectsOversizedJob() async throws {
    let (source, destination) = makePair()
    source.addFile("/a/big.bin", size: 5000)
    destination.addDirectory("/b")
    destination.capacity = 1000

    await #expect(throws: TransportError.self) {
        _ = try await TransferEngine().run(
            TransferJob(sources: ["/a/big.bin"], destinationDirectory: "/b"),
            from: source, to: destination)
    }
    #expect(!destination.hasFile("/b/big.bin"), "nothing should have been written")
}

// MARK: - Conflicts

@Test("skip leaves the existing file untouched")
func conflictSkip() async throws {
    let (source, destination) = makePair()
    source.addFile("/a/dup.txt", Data("new".utf8))
    destination.addFile("/b/dup.txt", Data("old".utf8))

    let report = try await TransferEngine().run(
        TransferJob(sources: ["/a/dup.txt"], destinationDirectory: "/b", conflictPolicy: .skip),
        from: source, to: destination)

    #expect(report.skipped.count == 1)
    #expect(report.transferred.isEmpty)
    #expect(destination.contents(of: "/b/dup.txt") == Data("old".utf8))
}

@Test("overwrite replaces the existing file")
func conflictOverwrite() async throws {
    let (source, destination) = makePair()
    source.addFile("/a/dup.txt", Data("new".utf8))
    destination.addFile("/b/dup.txt", Data("old".utf8))

    _ = try await TransferEngine().run(
        TransferJob(sources: ["/a/dup.txt"], destinationDirectory: "/b", conflictPolicy: .overwrite),
        from: source, to: destination)

    #expect(destination.contents(of: "/b/dup.txt") == Data("new".utf8))
}

@Test("rename appends a Finder-style suffix before the extension")
func conflictRename() async throws {
    let (source, destination) = makePair()
    source.addFile("/a/photo.jpg", Data("new".utf8))
    destination.addFile("/b/photo.jpg", Data("old".utf8))

    let report = try await TransferEngine().run(
        TransferJob(sources: ["/a/photo.jpg"], destinationDirectory: "/b", conflictPolicy: .rename),
        from: source, to: destination)

    #expect(report.transferred[0].destination == "/b/photo 2.jpg")
    #expect(destination.contents(of: "/b/photo.jpg") == Data("old".utf8))
    #expect(destination.contents(of: "/b/photo 2.jpg") == Data("new".utf8))
}

@Test("rename keeps counting past the first collision")
func conflictRenameTwice() async throws {
    let (source, destination) = makePair()
    source.addFile("/a/photo.jpg", Data("new".utf8))
    destination.addFile("/b/photo.jpg", Data("old".utf8))
    destination.addFile("/b/photo 2.jpg", Data("older".utf8))

    let report = try await TransferEngine().run(
        TransferJob(sources: ["/a/photo.jpg"], destinationDirectory: "/b", conflictPolicy: .rename),
        from: source, to: destination)

    #expect(report.transferred[0].destination == "/b/photo 3.jpg")
}

@Test("an extensionless file renames without a stray dot")
func conflictRenameNoExtension() async throws {
    let engine = TransferEngine()
    #expect(await engine.disambiguate("/b/README", 2) == "/b/README 2")
    #expect(await engine.disambiguate("/b/photo.jpg", 4) == "/b/photo 4.jpg")
}

// MARK: - Progress

@Test("progress is cumulative and ends at the total")
func reportsProgress() async throws {
    let (source, destination) = makePair()
    source.addFile("/a/one.bin", size: 4096)
    source.addFile("/a/two.bin", size: 4096)
    destination.addDirectory("/b")

    let samples = Box<[TransferProgress]>([])
    let report = try await TransferEngine(concurrency: 1).run(
        TransferJob(sources: ["/a"], destinationDirectory: "/b"),
        from: source, to: destination,
        onProgress: { progress in samples.withLock { $0.append(progress) } })

    #expect(report.transferred.count == 2)
    let seen = samples.withLock { $0 }
    #expect(!seen.isEmpty)
    #expect(seen.last?.completedFiles == 2)
    #expect(seen.last?.completedBytes == 8192)
    #expect(seen.last?.totalBytes == 8192)
    // Cumulative, never decreasing.
    let byteCounts = seen.map(\.completedBytes)
    #expect(byteCounts == byteCounts.sorted())
}

// MARK: - Helpers

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}
