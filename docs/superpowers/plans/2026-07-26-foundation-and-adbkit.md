# FileFerry Plan 1 — Foundation & ADBKit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `ADBKit` — a headless Swift library that speaks the ADB wire protocol directly to the adb server on `127.0.0.1:5037` — and prove it with a CLI that lists a directory on a real Android phone, pulls a file, and pushes it back with byte-accurate progress.

**Architecture:** A `ByteStream` protocol abstracts the socket so every parser is testable in memory with zero networking. `TCPByteStream` wraps `NWConnection` for production; `FakeADBServer` vends a scripted in-memory stream for tests. Above that sit two framing layers — the host protocol (`%04x`-length-prefixed ASCII, `OKAY`/`FAIL`) and the sync protocol (4-byte opcode + little-endian `UInt32`) — and above those, the services: `DeviceTracker`, `SyncSession`, `ShellSession`.

**Tech Stack:** Swift 6.3, Swift Package Manager, Network.framework (`NWConnection`), Swift Testing (`@Test`/`#expect`), GitHub Actions on `macos-15`. No third-party dependencies.

## Global Constraints

- **Swift tools version 6.0**, `swift-tools-version:6.0` in `Package.swift`.
- **Platform floor: macOS 14** (`.macOS(.v14)`). Do not use API newer than macOS 14 in `ADBKit`.
- **Strict concurrency: complete.** Every target sets `.enableUpcomingFeature("StrictConcurrency")` via `swiftSettings`. Warnings here are errors in review — do not silence them with `@unchecked Sendable`.
- **Zero third-party dependencies.** `Package.swift` has an empty `dependencies:` array and it stays empty.
- **Minimum adb version: platform-tools 34.** `ADBBinary` rejects anything older.
- **`adb` is never bundled.** The app locates a system binary. Never add `adb` to the repo or to `Resources/`.
- **Sync chunk size is exactly 65536 bytes** (`SyncSession.maxChunk`). This is the sync protocol's maximum payload; larger values are a protocol violation.
- **Always use the v2 sync opcodes** (`LIS2`, `STA2`, `DNT2`) when the device advertises `ls_v2`/`stat_v2`. The v1 opcodes encode size as `UInt32` and silently misreport files ≥ 4 GB.
- **Licence: MIT.** Every new source file starts with no licence header; the root `LICENSE` covers the repo.
- **Commit style:** Conventional Commits (`feat:`, `test:`, `chore:`, `docs:`, `fix:`).

---

## Prerequisites — run these before Task 1

None of the tests in this plan need a phone or an `adb` binary; they run entirely against in-memory fakes. But **Task 12 (the real-device smoke test) needs both**, and the development machine currently has neither Homebrew nor `adb`.

These are interactive and need your password, so run them yourself in this session by prefixing with `!`:

```
! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
! brew install --cask android-platform-tools
! brew install gh          # only needed to create the GitHub repo
```

Then on the phone: Settings → About phone → tap **Build number** seven times → back → System → Developer options → enable **USB debugging** → connect the cable → tap **Allow** on the RSA prompt, ticking "Always allow from this computer".

Verify with `adb devices -l`, which should print your device with state `device` (not `unauthorized`).

**Tasks 1–11 can be completed with none of this done.** Only Task 12 blocks on it.

---

## File Structure

```
Package.swift                          SPM manifest, 3 targets, no dependencies
Sources/ADBKit/
  ADBError.swift                       one typed error enum, user-facing recovery text
  ByteStream.swift                     protocol: read(exactly:) / write / close
  TCPByteStream.swift                  NWConnection implementation
  HostProtocol.swift                   %04x framing, OKAY/FAIL, hex payloads
  ADBBinary.swift                      locate adb on disk, parse its version
  ADBServer.swift                      actor: ensure a server is listening on 5037
  ADBDevice.swift                      value type: serial, state, model
  DeviceTracker.swift                  host:track-devices → AsyncStream<[ADBDevice]>
  SyncPacket.swift                     4-byte opcode + UInt32 LE framing
  SyncEntry.swift                      value type: name, size, mode, mtime
  SyncSession.swift                    LIS2 / STA2 / RECV / SEND
  ShellSession.swift                   shell,v2: with a real exit code
Sources/fileferry-cli/
  main.swift                           the Task 12 harness
Tests/ADBKitTests/
  FakeADBServer.swift                  scripted in-memory ByteStream
  HostProtocolTests.swift
  ADBBinaryTests.swift
  DeviceTrackerTests.swift
  SyncPacketTests.swift
  SyncSessionTests.swift
  TCPByteStreamTests.swift             the only test that opens a real socket
.github/workflows/ci.yml               build + test on macos-15
```

**Responsibility split:** framing files (`HostProtocol`, `SyncPacket`) are pure functions over `Data` with no I/O, which is why they are cheap to test exhaustively. Service files (`DeviceTracker`, `SyncSession`, `ShellSession`) own protocol *conversations* and take a `ByteStream` by injection. Nothing in `ADBKit` imports SwiftUI or knows what a transfer queue is.

---

## Task 1: Repository scaffold and CI

**Files:**
- Create: `Package.swift`, `Sources/ADBKit/ADBError.swift`, `Tests/ADBKitTests/SmokeTests.swift`, `.github/workflows/ci.yml`, `LICENSE`, `README.md`
- Note: `.gitignore` already exists and needs no change.

**Interfaces:**
- Consumes: nothing.
- Produces: `ADBError` — the error enum every later task throws. Cases used later: `.requestTooLong`, `.malformedResponse(String)`, `.malformedLength(String)`, `.remote(String)`, `.connectionClosed`, `.binaryNotFound`, `.binaryTooOld(found: String, required: String)`, `.serverUnavailable(String)`, `.deviceNotFound(String)`, `.unsupportedFeature(String)`, `.transferFailed(path: String, reason: String)`.

- [ ] **Step 1: Create the package manifest**

```swift
// swift-tools-version:6.0
import PackageDescription

let strict: [SwiftSetting] = [.enableUpcomingFeature("StrictConcurrency")]

let package = Package(
    name: "FileFerry",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ADBKit", targets: ["ADBKit"]),
        .executable(name: "fileferry-cli", targets: ["fileferry-cli"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "ADBKit", swiftSettings: strict),
        .executableTarget(name: "fileferry-cli", dependencies: ["ADBKit"], swiftSettings: strict),
        .testTarget(name: "ADBKitTests", dependencies: ["ADBKit"], swiftSettings: strict),
    ]
)
```

- [ ] **Step 2: Create the error type**

`Sources/ADBKit/ADBError.swift`:

```swift
import Foundation

public enum ADBError: Error, Equatable, Sendable {
    case requestTooLong
    case malformedResponse(String)
    case malformedLength(String)
    case remote(String)
    case connectionClosed
    case binaryNotFound
    case binaryTooOld(found: String, required: String)
    case serverUnavailable(String)
    case deviceNotFound(String)
    case unsupportedFeature(String)
    case transferFailed(path: String, reason: String)
}

extension ADBError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .requestTooLong:
            "The request was too long for the adb protocol."
        case .malformedResponse(let got):
            "Unexpected reply from the adb server: \(got)"
        case .malformedLength(let got):
            "The adb server sent a length field that isn't hexadecimal: \(got)"
        case .remote(let message):
            message
        case .connectionClosed:
            "The connection to the adb server closed unexpectedly."
        case .binaryNotFound:
            "Couldn't find adb. Install it with: brew install --cask android-platform-tools"
        case .binaryTooOld(let found, let required):
            "adb \(found) is too old — FileFerry needs \(required) or newer."
        case .serverUnavailable(let detail):
            "Couldn't reach the adb server. \(detail)"
        case .deviceNotFound(let serial):
            "Device \(serial) isn't connected."
        case .unsupportedFeature(let feature):
            "This device doesn't support \(feature)."
        case .transferFailed(let path, let reason):
            "Couldn't transfer \(path): \(reason)"
        }
    }
}
```

- [ ] **Step 3: Write a smoke test**

`Tests/ADBKitTests/SmokeTests.swift`:

```swift
import Testing
@testable import ADBKit

@Test("ADBError carries a user-facing message")
func errorHasDescription() {
    let error = ADBError.binaryTooOld(found: "33.0.0", required: "34.0.0")
    #expect(error.errorDescription?.contains("33.0.0") == true)
    #expect(error.errorDescription?.contains("34.0.0") == true)
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test`
Expected: PASS, 1 test. If the build fails on `swift-tools-version:6.0`, confirm `swift --version` reports 6.0 or newer.

- [ ] **Step 5: Add LICENSE and README**

`LICENSE` — the standard MIT text, copyright `2026 Gopal Kannan`.

`README.md`:

```markdown
# FileFerry

Copy and move files between a Mac and an Android phone over USB, at USB speed.

FileFerry talks to Android over ADB rather than MTP, which makes it dramatically
faster on folders with many files — the case where Android File Transfer and
MTP-based tools slow to a crawl.

**Status:** in development. Not yet released.

## Requirements

- macOS 14 or later
- `adb` — install with `brew install --cask android-platform-tools`
- USB debugging enabled on the phone

## Building

    swift build
    swift test

## Design

See [`docs/superpowers/specs/2026-07-26-fileferry-design.md`](docs/superpowers/specs/2026-07-26-fileferry-design.md).

## Licence

MIT
```

- [ ] **Step 6: Add CI**

`.github/workflows/ci.yml`:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.app
      - name: Build
        run: swift build -v
      - name: Test
        run: swift test -v
```

Note: no Android device is attached to CI runners. Every test in this plan is designed to run without one.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources Tests .github LICENSE README.md
git commit -m "chore: scaffold SPM package, error type, and CI"
```

---

## Task 2: Host protocol framing

The adb host protocol prefixes every request with its length as four lowercase hex digits. Replies begin `OKAY` or `FAIL`; `FAIL` is followed by a hex-length-prefixed message. These are pure functions over `Data`, so they get tested exhaustively here and are trusted everywhere after.

**Files:**
- Create: `Sources/ADBKit/ByteStream.swift`, `Sources/ADBKit/HostProtocol.swift`, `Tests/ADBKitTests/FakeADBServer.swift`, `Tests/ADBKitTests/HostProtocolTests.swift`

**Interfaces:**
- Consumes: `ADBError` from Task 1.
- Produces:
  - `protocol ByteStream: Sendable` with `func read(exactly: Int) async throws -> Data`, `func write(_: Data) async throws`, `func close() async`
  - `enum HostProtocol` with `static func encode(_ request: String) throws -> Data`
  - `func readStatus(from: any ByteStream) async throws` — returns normally on `OKAY`, throws `.remote` on `FAIL`
  - `func readHexPayload(from: any ByteStream) async throws -> Data`
  - `final class FakeADBServer: ByteStream` (test-only) with `init(script: [Data])` and `var written: [Data]`

- [ ] **Step 1: Write the failing tests**

`Tests/ADBKitTests/HostProtocolTests.swift`:

```swift
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
        Data("FAIL".utf8), Data("0011".utf8), Data("device not found".utf8),
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
```

- [ ] **Step 2: Write the test double**

`Tests/ADBKitTests/FakeADBServer.swift`:

```swift
import Foundation
@testable import ADBKit

/// An in-memory ByteStream that replays a scripted sequence of server bytes
/// and records everything the client wrote. No sockets, so it is deterministic
/// and safe to run on CI, where no Android device exists.
final class FakeADBServer: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: Data
    private(set) var written: [Data] = []
    private(set) var isClosed = false

    /// - Parameter script: concatenated in order to form the server's byte stream.
    init(script: [Data]) {
        self.inbox = script.reduce(into: Data()) { $0.append($1) }
    }

    func read(exactly count: Int) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard inbox.count >= count else { throw ADBError.connectionClosed }
        defer { inbox.removeFirst(count) }
        return inbox.prefix(count)
    }

    func write(_ data: Data) async throws {
        lock.lock(); defer { lock.unlock() }
        written.append(data)
    }

    func close() async {
        lock.lock(); defer { lock.unlock() }
        isClosed = true
    }

    /// Everything the client wrote, concatenated — convenient for assertions.
    var writtenBytes: Data {
        lock.lock(); defer { lock.unlock() }
        return written.reduce(into: Data()) { $0.append($1) }
    }
}
```

`@unchecked Sendable` is acceptable *here only*, because the lock genuinely guards every stored property and this type never ships. Do not copy the pattern into `Sources/`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter HostProtocolTests`
Expected: FAIL — `cannot find 'HostProtocol' in scope`, `cannot find type 'ByteStream' in scope`.

- [ ] **Step 4: Write the implementation**

`Sources/ADBKit/ByteStream.swift`:

```swift
import Foundation

/// A bidirectional byte pipe. Abstracting this is what lets every parser in
/// ADBKit be tested in memory, with no socket and no phone.
public protocol ByteStream: Sendable {
    /// Reads exactly `count` bytes, or throws `.connectionClosed` if the peer
    /// hangs up first. Never returns a short read.
    func read(exactly count: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}
```

`Sources/ADBKit/HostProtocol.swift`:

```swift
import Foundation

/// Framing for the adb *host* protocol: requests are prefixed with their byte
/// length as four lowercase hex digits; replies start OKAY or FAIL.
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter HostProtocolTests`
Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/ADBKit/ByteStream.swift Sources/ADBKit/HostProtocol.swift Tests/ADBKitTests
git commit -m "feat: add host protocol framing and an in-memory test server"
```

---

## Task 3: TCP byte stream

The one place that touches the network. Kept deliberately thin so that almost nothing needs a socket to be tested.

**Files:**
- Create: `Sources/ADBKit/TCPByteStream.swift`, `Tests/ADBKitTests/TCPByteStreamTests.swift`

**Interfaces:**
- Consumes: `ByteStream`, `ADBError`.
- Produces: `actor TCPByteStream: ByteStream` with `static func connect(host: String, port: UInt16) async throws -> TCPByteStream`.

- [ ] **Step 1: Write the failing test**

This test starts a throwaway `NWListener` on a random port, echoes bytes back, and checks the round trip. It is the only socket test in the suite.

`Tests/ADBKitTests/TCPByteStreamTests.swift`:

```swift
import Foundation
import Network
import Testing
@testable import ADBKit

@Test("TCPByteStream round-trips bytes against a local listener")
func roundTripsOverLoopback() async throws {
    let listener = try NWListener(using: .tcp, on: .any)
    let ready = AsyncStream<UInt16>.makeStream()
    listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port {
            ready.continuation.yield(port.rawValue)
            ready.continuation.finish()
        }
    }
    listener.newConnectionHandler = { connection in
        connection.start(queue: .global())
        // Echo the first 5 bytes straight back.
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { data, _, _, _ in
            if let data { connection.send(content: data, completion: .idempotent) }
        }
    }
    listener.start(queue: .global())
    defer { listener.cancel() }

    var iterator = ready.stream.makeAsyncIterator()
    guard let port = await iterator.next() else {
        Issue.record("listener never became ready"); return
    }

    let stream = try await TCPByteStream.connect(host: "127.0.0.1", port: port)
    try await stream.write(Data("hello".utf8))
    let echoed = try await stream.read(exactly: 5)
    #expect(String(decoding: echoed, as: UTF8.self) == "hello")
    await stream.close()
}

@Test("connecting to a closed port throws serverUnavailable")
func failsOnClosedPort() async {
    // Port 1 is reserved and never listening.
    await #expect(throws: ADBError.self) {
        _ = try await TCPByteStream.connect(host: "127.0.0.1", port: 1)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TCPByteStreamTests`
Expected: FAIL — `cannot find 'TCPByteStream' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/ADBKit/TCPByteStream.swift`:

```swift
import Foundation
import Network

/// A ByteStream backed by NWConnection. An actor because `buffer` is mutable
/// state shared across concurrent reads.
public actor TCPByteStream: ByteStream {
    private let connection: NWConnection
    private var buffer = Data()

    private init(connection: NWConnection) {
        self.connection = connection
    }

    public static func connect(host: String, port: UInt16) async throws -> TCPByteStream {
        let endpoint = NWEndpoint.hostPort(
            host: .init(host),
            port: .init(rawValue: port) ?? .any
        )
        let connection = NWConnection(to: endpoint, using: .tcp)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func finish(_ result: Result<Void, Error>) {
                let alreadyResumed = resumed.withLock { was -> Bool in
                    defer { was = true }
                    return was
                }
                guard !alreadyResumed else { return }
                cont.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error), .waiting(let error):
                    finish(.failure(ADBError.serverUnavailable(error.localizedDescription)))
                case .cancelled:
                    finish(.failure(ADBError.connectionClosed))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        connection.stateUpdateHandler = nil
        return TCPByteStream(connection: connection)
    }

    public func read(exactly count: Int) async throws -> Data {
        while buffer.count < count {
            let chunk = try await receiveChunk(max: max(count - buffer.count, 8192))
            guard !chunk.isEmpty else { throw ADBError.connectionClosed }
            buffer.append(chunk)
        }
        let result = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(result)
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: ADBError.serverUnavailable(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    public func close() {
        connection.cancel()
    }

    private func receiveChunk(max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: ADBError.serverUnavailable(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: Data())
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }
}
```

Note the `resumed` guard in `connect`: `NWConnection` can report `.waiting` and then `.failed`, and resuming a continuation twice is a crash, not a warning.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter TCPByteStreamTests`
Expected: PASS, 2 tests. If `failsOnClosedPort` hangs rather than throwing, `NWConnection` is sitting in `.waiting` — confirm the `.waiting` case in `stateUpdateHandler` is being treated as a failure.

- [ ] **Step 5: Commit**

```bash
git add Sources/ADBKit/TCPByteStream.swift Tests/ADBKitTests/TCPByteStreamTests.swift
git commit -m "feat: add NWConnection-backed byte stream"
```

---

## Task 4: Locating and version-checking the adb binary

**Files:**
- Create: `Sources/ADBKit/ADBBinary.swift`, `Tests/ADBKitTests/ADBBinaryTests.swift`

**Interfaces:**
- Consumes: `ADBError`.
- Produces: `struct ADBBinary: Sendable` with `let url: URL`, `static let minimumVersion = "34.0.0"`, `static func parseVersion(_ output: String) -> String?`, `static func locate(configuredPath: String?, environment: [String: String], fileExists: (String) -> Bool) -> URL?`

`locate` takes its filesystem and environment by injection so it is testable without touching the real disk.

- [ ] **Step 1: Write the failing tests**

`Tests/ADBKitTests/ADBBinaryTests.swift`:

```swift
import Foundation
import Testing
@testable import ADBKit

@Test("parses the version out of adb's banner")
func parsesVersion() {
    let output = """
    Android Debug Bridge version 1.0.41
    Version 35.0.2-12147458
    Installed as /opt/homebrew/bin/adb
    """
    #expect(ADBBinary.parseVersion(output) == "35.0.2")
}

@Test("returns nil when the banner has no Version line")
func parsesMissingVersion() {
    #expect(ADBBinary.parseVersion("command not found") == nil)
}

@Test("a configured path wins over every other candidate")
func prefersConfiguredPath() {
    let found = ADBBinary.locate(
        configuredPath: "/custom/adb",
        environment: ["ANDROID_HOME": "/sdk"],
        fileExists: { _ in true }
    )
    #expect(found?.path == "/custom/adb")
}

@Test("falls back to ANDROID_HOME when no path is configured")
func fallsBackToAndroidHome() {
    let found = ADBBinary.locate(
        configuredPath: nil,
        environment: ["ANDROID_HOME": "/sdk"],
        fileExists: { $0 == "/sdk/platform-tools/adb" }
    )
    #expect(found?.path == "/sdk/platform-tools/adb")
}

@Test("falls back to the Homebrew location on Apple Silicon")
func fallsBackToHomebrew() {
    let found = ADBBinary.locate(
        configuredPath: nil,
        environment: [:],
        fileExists: { $0 == "/opt/homebrew/bin/adb" }
    )
    #expect(found?.path == "/opt/homebrew/bin/adb")
}

@Test("returns nil when adb is nowhere to be found")
func findsNothing() {
    let found = ADBBinary.locate(configuredPath: nil, environment: [:], fileExists: { _ in false })
    #expect(found == nil)
}

@Test("version comparison is numeric, not lexicographic")
func comparesVersionsNumerically() {
    // The bug this guards: "9.0.0" > "34.0.0" as strings.
    #expect(ADBBinary.isVersion("34.0.0", atLeast: "34.0.0"))
    #expect(ADBBinary.isVersion("35.0.2", atLeast: "34.0.0"))
    #expect(ADBBinary.isVersion("34.1.0", atLeast: "34.0.0"))
    #expect(!ADBBinary.isVersion("33.0.3", atLeast: "34.0.0"))
    #expect(!ADBBinary.isVersion("9.0.0", atLeast: "34.0.0"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ADBBinaryTests`
Expected: FAIL — `cannot find 'ADBBinary' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/ADBKit/ADBBinary.swift`:

```swift
import Foundation

/// Locates the system adb binary and checks it is new enough.
/// FileFerry deliberately does not bundle adb — Google's prebuilt platform-tools
/// may not be redistributed under the Android SDK terms.
public struct ADBBinary: Sendable {
    public static let minimumVersion = "34.0.0"

    public let url: URL
    public let version: String

    public init(url: URL, version: String) {
        self.url = url
        self.version = version
    }

    /// Search order: configured path, ANDROID_HOME, Homebrew (both prefixes),
    /// then the conventional /usr/local location.
    public static func locate(
        configuredPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        var candidates: [String] = []
        if let configuredPath { candidates.append(configuredPath) }
        if let sdk = environment["ANDROID_HOME"] ?? environment["ANDROID_SDK_ROOT"] {
            candidates.append("\(sdk)/platform-tools/adb")
        }
        candidates.append("/opt/homebrew/bin/adb")
        candidates.append("/usr/local/bin/adb")
        return candidates.first(where: fileExists).map(URL.init(fileURLWithPath:))
    }

    /// Pulls "35.0.2" out of a "Version 35.0.2-12147458" line.
    public static func parseVersion(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Version ") else { continue }
            let value = trimmed.dropFirst("Version ".count)
            return String(value.split(separator: "-").first ?? value)
        }
        return nil
    }

    /// Component-wise numeric comparison. String comparison would rank
    /// "9.0.0" above "34.0.0".
    public static func isVersion(_ found: String, atLeast required: String) -> Bool {
        let lhs = found.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = required.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    /// Runs `adb version` and validates the result.
    public static func resolve(configuredPath: String? = nil) throws -> ADBBinary {
        guard let url = locate(configuredPath: configuredPath) else {
            throw ADBError.binaryNotFound
        }
        let process = Process()
        process.executableURL = url
        process.arguments = ["version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        guard let version = parseVersion(output) else {
            throw ADBError.malformedResponse("adb version printed no Version line")
        }
        guard isVersion(version, atLeast: minimumVersion) else {
            throw ADBError.binaryTooOld(found: version, required: minimumVersion)
        }
        return ADBBinary(url: url, version: version)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ADBBinaryTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ADBKit/ADBBinary.swift Tests/ADBKitTests/ADBBinaryTests.swift
git commit -m "feat: locate and version-check the adb binary"
```

---

## Task 5: Server lifecycle

The adb server owns the USB connection. We adopt one if it is already running and only start our own if not — **never** killing an existing server, which would break a user's Android Studio session mid-debug.

**Files:**
- Create: `Sources/ADBKit/ADBServer.swift`
- Modify: `Tests/ADBKitTests/SmokeTests.swift` (add server tests, rename file to `ADBServerTests.swift`)

**Interfaces:**
- Consumes: `ADBBinary`, `TCPByteStream`, `HostProtocol`, `readStatus`, `readHexPayload`.
- Produces: `actor ADBServer` with `init(binary: ADBBinary, port: UInt16 = 5037)`, `func ensureRunning() async throws`, `func connect() async throws -> any ByteStream`, `func request(_ service: String) async throws -> any ByteStream`, `static func parseVersionReply(_ payload: Data) -> Int?`

- [ ] **Step 1: Write the failing test**

Add to `Tests/ADBKitTests/ADBServerTests.swift`:

```swift
import Foundation
import Testing
@testable import ADBKit

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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ADBServerTests`
Expected: FAIL — `cannot find 'ADBServer' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/ADBKit/ADBServer.swift`:

```swift
import Foundation

/// Owns the relationship with the adb server process on 127.0.0.1:5037.
///
/// An existing server is adopted rather than replaced. Killing a server the
/// user started would drop their Android Studio debugging session, so this
/// type never calls `adb kill-server`.
public actor ADBServer {
    public static let defaultPort: UInt16 = 5037

    private let binary: ADBBinary
    private let port: UInt16
    private var didVerify = false

    public init(binary: ADBBinary, port: UInt16 = ADBServer.defaultPort) {
        self.binary = binary
        self.port = port
    }

    /// Connects if a server is already listening, otherwise runs
    /// `adb start-server` once and retries.
    public func ensureRunning() async throws {
        if didVerify { return }
        if await isListening() {
            didVerify = true
            return
        }
        try startServer()
        // adb start-server returns before the socket is accepting; poll briefly.
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(250))
            if await isListening() {
                didVerify = true
                return
            }
        }
        throw ADBError.serverUnavailable(
            "adb start-server ran but nothing is listening on port \(port). "
            + "Another process may be holding that port."
        )
    }

    /// Opens a connection and sends one service request, leaving the stream
    /// positioned for that service's own protocol.
    public func request(_ service: String) async throws -> any ByteStream {
        try await ensureRunning()
        let stream = try await TCPByteStream.connect(host: "127.0.0.1", port: port)
        do {
            try await ADBServer.send(service: service, over: stream)
            return stream
        } catch {
            await stream.close()
            throw error
        }
    }

    /// Sends a service request and consumes the OKAY.
    public static func send(service: String, over stream: any ByteStream) async throws {
        try await stream.write(try HostProtocol.encode(service))
        try await readStatus(from: stream)
    }

    public static func parseVersionReply(_ payload: Data) -> Int? {
        Int(String(decoding: payload, as: UTF8.self), radix: 16)
    }

    private func isListening() async -> Bool {
        do {
            let stream = try await TCPByteStream.connect(host: "127.0.0.1", port: port)
            defer { Task { await stream.close() } }
            try await ADBServer.send(service: "host:version", over: stream)
            _ = try await readHexPayload(from: stream)
            return true
        } catch {
            return false
        }
    }

    private func startServer() throws {
        let process = Process()
        process.executableURL = binary.url
        process.arguments = ["start-server"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ADBServerTests`
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ADBKit/ADBServer.swift Tests/ADBKitTests/ADBServerTests.swift
git rm -f Tests/ADBKitTests/SmokeTests.swift 2>/dev/null || true
git commit -m "feat: adopt or start the adb server without killing an existing one"
```

---

## Task 6: Device model and tracking

`host:track-devices` keeps the connection open and pushes a fresh device list on every change. This is what makes the sidebar update the instant a cable is plugged in, with no polling.

**Files:**
- Create: `Sources/ADBKit/ADBDevice.swift`, `Sources/ADBKit/DeviceTracker.swift`, `Tests/ADBKitTests/DeviceTrackerTests.swift`

**Interfaces:**
- Consumes: `ADBServer`, `ByteStream`, `readHexPayload`.
- Produces:
  - `struct ADBDevice: Sendable, Equatable, Identifiable` with `let serial: String`, `let state: DeviceState`, `var id: String { serial }`
  - `enum DeviceState: String, Sendable { case device, unauthorized, offline, unknown }`
  - `static func ADBDevice.parseList(_ payload: Data) -> [ADBDevice]`
  - `struct DeviceTracker` with `func devices() -> AsyncThrowingStream<[ADBDevice], Error>`

- [ ] **Step 1: Write the failing tests**

`Tests/ADBKitTests/DeviceTrackerTests.swift`:

```swift
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
```

Note the length field in the last test: `"AAA\tdevice\n"` is 11 bytes, so the prefix is `000b`. Hex length fields count **bytes**, and getting one wrong desynchronises the stream for every frame that follows — which presents as a mysterious hang rather than a clean error.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DeviceTrackerTests`
Expected: FAIL — `cannot find 'ADBDevice' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/ADBKit/ADBDevice.swift`:

```swift
import Foundation

public enum DeviceState: String, Sendable, Equatable {
    case device
    case unauthorized
    case offline
    case unknown

    init(raw: String) {
        self = DeviceState(rawValue: raw) ?? .unknown
    }
}

public struct ADBDevice: Sendable, Equatable, Identifiable {
    public let serial: String
    public let state: DeviceState
    public var id: String { serial }

    public init(serial: String, state: DeviceState) {
        self.serial = serial
        self.state = state
    }

    /// Each line is "<serial>\t<state>". Malformed lines are skipped rather
    /// than failing the whole list — one odd entry should not blank the sidebar.
    public static func parseList(_ payload: Data) -> [ADBDevice] {
        String(decoding: payload, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return ADBDevice(
                    serial: String(parts[0]).trimmingCharacters(in: .whitespaces),
                    state: DeviceState(raw: String(parts[1]).trimmingCharacters(in: .whitespaces))
                )
            }
    }
}
```

`Sources/ADBKit/DeviceTracker.swift`:

```swift
import Foundation

/// Streams the device list. The adb server pushes a new frame on every
/// connect or disconnect, so nothing here polls.
public struct DeviceTracker: Sendable {
    private let server: ADBServer

    public init(server: ADBServer) {
        self.server = server
    }

    public func devices() -> AsyncThrowingStream<[ADBDevice], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = try await server.request("host:track-devices")
                    continuation.onTermination = { _ in Task { await stream.close() } }
                    while !Task.isCancelled {
                        let payload = try await readHexPayload(from: stream)
                        continuation.yield(ADBDevice.parseList(payload))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DeviceTrackerTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ADBKit/ADBDevice.swift Sources/ADBKit/DeviceTracker.swift Tests/ADBKitTests/DeviceTrackerTests.swift
git commit -m "feat: stream device connect/disconnect via host:track-devices"
```

---

## Task 7: Sync protocol framing

The sync protocol is binary, not ASCII: a 4-byte opcode followed by a little-endian `UInt32`. Different from the host protocol, and mixing the two up is the most common way to get this wrong.

**Files:**
- Create: `Sources/ADBKit/SyncPacket.swift`, `Sources/ADBKit/SyncEntry.swift`, `Tests/ADBKitTests/SyncPacketTests.swift`

**Interfaces:**
- Consumes: `ADBError`, `ByteStream`.
- Produces:
  - `enum SyncOpcode: String` — `.lis2 = "LIS2"`, `.dnt2 = "DNT2"`, `.sta2 = "STA2"`, `.send = "SEND"`, `.recv = "RECV"`, `.data = "DATA"`, `.done = "DONE"`, `.okay = "OKAY"`, `.fail = "FAIL"`, `.quit = "QUIT"`
  - `struct SyncPacket` with `let opcode: String`, `let value: UInt32`, `func encoded() -> Data`, `static func decode(_ data: Data) throws -> SyncPacket`
  - `static func SyncPacket.request(_ opcode: SyncOpcode, path: String) -> Data`
  - `struct SyncEntry: Sendable, Equatable` with `let name: String`, `let size: Int64`, `let mode: UInt32`, `let mtime: Date`, `var isDirectory: Bool`
  - `static func SyncEntry.parseDNT2(header: Data, name: String) -> SyncEntry`

- [ ] **Step 1: Write the failing tests**

`Tests/ADBKitTests/SyncPacketTests.swift`:

```swift
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
    var header = Data()
    header.append(contentsOf: [0x00, 0x00, 0x00, 0x00])                  // error
    header.append(Data(repeating: 0, count: 16))                          // dev, ino
    header.append(contentsOf: withUnsafeBytes(of: UInt32(0o100644).littleEndian, Array.init))  // mode
    header.append(Data(repeating: 0, count: 12))                          // nlink, uid, gid
    header.append(contentsOf: withUnsafeBytes(of: UInt64(5_000_000_000).littleEndian, Array.init)) // size
    header.append(Data(repeating: 0, count: 8))                           // atime
    header.append(contentsOf: withUnsafeBytes(of: Int64(1_700_000_000).littleEndian, Array.init)) // mtime
    header.append(Data(repeating: 0, count: 8))                           // ctime

    let entry = SyncEntry.parseDNT2(header: header, name: "big.mp4")
    #expect(entry.name == "big.mp4")
    #expect(entry.size == 5_000_000_000)          // the whole point of v2: > 4 GB
    #expect(entry.mtime == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(!entry.isDirectory)
}

@Test("the directory bit is read out of the mode field")
func detectsDirectory() {
    var header = Data(repeating: 0, count: 72 - 4)
    header.replaceSubrange(20..<24, with: withUnsafeBytes(of: UInt32(0o040755).littleEndian, Array.init))
    let entry = SyncEntry.parseDNT2(header: header, name: "DCIM")
    #expect(entry.isDirectory)
}
```

The `header` passed to `parseDNT2` is the 68 bytes **after** the 4-byte opcode and **before** the name — that is, `error` through `ctime`, with `namelen` consumed by the caller.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SyncPacketTests`
Expected: FAIL — `cannot find 'SyncPacket' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/ADBKit/SyncPacket.swift`:

```swift
import Foundation

public enum SyncOpcode: String, Sendable {
    case lis2 = "LIS2"
    case dnt2 = "DNT2"
    case sta2 = "STA2"
    case send = "SEND"
    case recv = "RECV"
    case data = "DATA"
    case done = "DONE"
    case okay = "OKAY"
    case fail = "FAIL"
    case quit = "QUIT"
}

/// The sync protocol's unit: a 4-byte ASCII opcode followed by a
/// little-endian UInt32. Note this is *binary* — unlike the host protocol,
/// whose lengths are ASCII hex.
public struct SyncPacket: Sendable, Equatable {
    public let opcode: String
    public let value: UInt32

    public init(opcode: String, value: UInt32) {
        self.opcode = opcode
        self.value = value
    }

    public init(_ opcode: SyncOpcode, value: UInt32) {
        self.init(opcode: opcode.rawValue, value: value)
    }

    public func encoded() -> Data {
        var data = Data(opcode.utf8.prefix(4))
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    public static func decode(_ data: Data) throws -> SyncPacket {
        guard data.count == 8 else {
            throw ADBError.malformedResponse("sync packet was \(data.count) bytes, expected 8")
        }
        let bytes = Array(data)
        return SyncPacket(
            opcode: String(decoding: bytes[0..<4], as: UTF8.self),
            value: UInt32(littleEndian: bytes[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        )
    }

    /// An opcode carrying a path: opcode, byte length, then the path itself.
    public static func request(_ opcode: SyncOpcode, path: String) -> Data {
        let pathBytes = Data(path.utf8)
        return SyncPacket(opcode, value: UInt32(pathBytes.count)).encoded() + pathBytes
    }
}
```

`Sources/ADBKit/SyncEntry.swift`:

```swift
import Foundation

public struct SyncEntry: Sendable, Equatable {
    public let name: String
    public let size: Int64
    public let mode: UInt32
    public let mtime: Date

    public init(name: String, size: Int64, mode: UInt32, mtime: Date) {
        self.name = name
        self.size = size
        self.mode = mode
        self.mtime = mtime
    }

    /// S_IFMT / S_IFDIR from stat(2).
    public var isDirectory: Bool { (mode & 0o170000) == 0o040000 }
    public var isSymlink: Bool { (mode & 0o170000) == 0o120000 }

    /// Byte layout of sync_dent_v2 after the opcode, per AOSP
    /// `file_sync_service.h`:
    ///   error u32 | dev u64 | ino u64 | mode u32 | nlink u32 |
    ///   uid u32 | gid u32 | size u64 | atime i64 | mtime i64 | ctime i64
    /// = 68 bytes, then a u32 namelen the caller has already consumed.
    public static func parseDNT2(header: Data, name: String) -> SyncEntry {
        let bytes = [UInt8](header)
        func u32(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        func i64(_ offset: Int) -> Int64 {
            bytes[offset..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
        }
        return SyncEntry(
            name: name,
            size: i64(36),
            mode: u32(20),
            mtime: Date(timeIntervalSince1970: TimeInterval(i64(52)))
        )
    }
}
```

Offsets, counting from zero after the opcode: `error` 0, `dev` 4, `ino` 12, `mode` 20, `nlink` 24, `uid` 28, `gid` 32, `size` 36, `atime` 44, `mtime` 52, `ctime` 60. Total 68.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SyncPacketTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Verify the layout against AOSP**

Open <https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/file_sync_service.h> and confirm `sync_dent_v2` and `sync_stat_v2` match the offsets above. If they differ, the tests and the offsets both change — the real header wins. Record what you found in `docs/ADB_PROTOCOL.md`.

- [ ] **Step 6: Commit**

```bash
git add Sources/ADBKit/SyncPacket.swift Sources/ADBKit/SyncEntry.swift Tests/ADBKitTests/SyncPacketTests.swift docs/ADB_PROTOCOL.md
git commit -m "feat: add sync protocol framing and 64-bit directory entries"
```

---

## Task 8: Sync session — listing and stat

**Files:**
- Create: `Sources/ADBKit/SyncSession.swift`, `Tests/ADBKitTests/SyncSessionTests.swift`

**Interfaces:**
- Consumes: `ADBServer`, `ByteStream`, `SyncPacket`, `SyncEntry`, `ADBError`.
- Produces: `final class SyncSession: Sendable` with
  - `static let maxChunk = 65536`
  - `static func open(server: ADBServer, serial: String) async throws -> SyncSession`
  - `init(stream: any ByteStream)` — used directly by tests
  - `func list(_ path: String) async throws -> [SyncEntry]`
  - `func stat(_ path: String) async throws -> SyncEntry`
  - `func close() async`

- [ ] **Step 1: Write the failing tests**

`Tests/ADBKitTests/SyncSessionTests.swift`:

```swift
import Foundation
import Testing
@testable import ADBKit

/// Builds a DNT2 frame: opcode, 68-byte header, namelen, name.
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
    #expect(try await SyncSession(stream: stream).list("/sdcard/empty").isEmpty)
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
    var frame = Data("FAIL".utf8)
    let message = Data("Permission denied".utf8)
    frame.append(contentsOf: withUnsafeBytes(of: UInt32(message.count).littleEndian, Array.init))
    frame.append(message)
    let stream = FakeADBServer(script: [frame])
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SyncSessionTests`
Expected: FAIL — `cannot find 'SyncSession' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/ADBKit/SyncSession.swift`:

```swift
import Foundation

/// One `sync:` conversation with a device.
///
/// A session is deliberately long-lived: the sync service accepts many
/// requests on a single connection, and reopening it per file is what makes
/// naive implementations crawl on folders with thousands of entries.
public final class SyncSession: Sendable {
    public static let maxChunk = 65536

    private let stream: any ByteStream

    public init(stream: any ByteStream) {
        self.stream = stream
    }

    /// Switches a fresh connection to the device, then into sync mode.
    public static func open(server: ADBServer, serial: String) async throws -> SyncSession {
        let stream = try await server.request("host:transport:\(serial)")
        try await ADBServer.send(service: "sync:", over: stream)
        return SyncSession(stream: stream)
    }

    public func close() async {
        try? await stream.write(SyncPacket(.quit, value: 0).encoded())
        await stream.close()
    }

    public func list(_ path: String) async throws -> [SyncEntry] {
        try await stream.write(SyncPacket.request(.lis2, path: path))
        var entries: [SyncEntry] = []
        while true {
            let opcode = String(decoding: try await stream.read(exactly: 4), as: UTF8.self)
            switch opcode {
            case SyncOpcode.dnt2.rawValue:
                let header = try await stream.read(exactly: 68)
                let namelen = try await readUInt32()
                let name = String(decoding: try await stream.read(exactly: Int(namelen)), as: UTF8.self)
                entries.append(SyncEntry.parseDNT2(header: header, name: name))
            case SyncOpcode.done.rawValue:
                // DONE in a list stream is dent-sized, not 8 bytes: adb writes
                // sizeof(sync_dent_v2) with the id swapped for DONE.
                _ = try await stream.read(exactly: 72)
                return entries
            case SyncOpcode.fail.rawValue:
                throw ADBError.remote(try await readSyncMessage())
            default:
                throw ADBError.malformedResponse("unexpected sync opcode \(opcode)")
            }
        }
    }

    public func stat(_ path: String) async throws -> SyncEntry {
        try await stream.write(SyncPacket.request(.sta2, path: path))
        let opcode = String(decoding: try await stream.read(exactly: 4), as: UTF8.self)
        switch opcode {
        case SyncOpcode.sta2.rawValue:
            let header = try await stream.read(exactly: 68)
            return SyncEntry.parseDNT2(header: header, name: path)
        case SyncOpcode.fail.rawValue:
            throw ADBError.remote(try await readSyncMessage())
        default:
            throw ADBError.malformedResponse("unexpected sync opcode \(opcode)")
        }
    }

    // MARK: - Internals

    func readUInt32() async throws -> UInt32 {
        let bytes = try await stream.read(exactly: 4)
        return UInt32(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    }

    /// A FAIL body: a UInt32 length then the message. The opcode is already consumed.
    func readSyncMessage() async throws -> String {
        let length = try await readUInt32()
        guard length > 0 else { return "unknown error" }
        return String(decoding: try await stream.read(exactly: Int(length)), as: UTF8.self)
    }

    var underlyingStream: any ByteStream { stream }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SyncSessionTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ADBKit/SyncSession.swift Tests/ADBKitTests/SyncSessionTests.swift
git commit -m "feat: list directories and stat paths over the sync protocol"
```

---

## Task 9: Pulling files with progress

**Files:**
- Modify: `Sources/ADBKit/SyncSession.swift` (add `pull`), `Tests/ADBKitTests/SyncSessionTests.swift` (add pull tests)

**Interfaces:**
- Consumes: everything from Task 8.
- Produces: `func pull(_ remotePath: String, to destination: URL, onProgress: @Sendable (Int64) -> Void) async throws -> Int64` — returns total bytes written; `onProgress` receives a cumulative byte count.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ADBKitTests/SyncSessionTests.swift`:

```swift
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

@Test("pull writes every chunk to disk in order")
func pullsFile() async throws {
    let destination = URL.temporaryDirectory.appending(path: "pull-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: destination) }

    let stream = FakeADBServer(script: [
        dataFrame(Data("hello ".utf8)),
        dataFrame(Data("world".utf8)),
        recvDone(),
    ])
    let written = try await SyncSession(stream: stream).pull("/sdcard/a.txt", to: destination) { _ in }

    #expect(written == 11)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "hello world")
}

@Test("pull reports cumulative progress, not per-chunk deltas")
func pullReportsProgress() async throws {
    let destination = URL.temporaryDirectory.appending(path: "pull-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: destination) }

    let stream = FakeADBServer(script: [
        dataFrame(Data(repeating: 0x41, count: 100)),
        dataFrame(Data(repeating: 0x42, count: 50)),
        recvDone(),
    ])
    let counts = Mutex<[Int64]>([])
    _ = try await SyncSession(stream: stream).pull("/sdcard/a.bin", to: destination) { total in
        counts.withLock { $0.append(total) }
    }
    #expect(counts.withLock { $0 } == [100, 150])
}

@Test("a zero-byte file pulls successfully")
func pullsEmptyFile() async throws {
    let destination = URL.temporaryDirectory.appending(path: "pull-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: destination) }

    let stream = FakeADBServer(script: [recvDone()])
    let written = try await SyncSession(stream: stream).pull("/sdcard/empty", to: destination) { _ in }
    #expect(written == 0)
    #expect(FileManager.default.fileExists(atPath: destination.path))
}

@Test("a FAIL mid-pull deletes the partial file rather than leaving it truncated")
func pullCleansUpPartialFile() async throws {
    let destination = URL.temporaryDirectory.appending(path: "pull-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: destination) }

    var failure = Data("FAIL".utf8)
    let message = Data("Permission denied".utf8)
    failure.append(contentsOf: withUnsafeBytes(of: UInt32(message.count).littleEndian, Array.init))
    failure.append(message)

    let stream = FakeADBServer(script: [dataFrame(Data(repeating: 0x41, count: 64)), failure])
    await #expect(throws: ADBError.self) {
        _ = try await SyncSession(stream: stream).pull("/sdcard/a.bin", to: destination) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path),
            "a partial file must never survive a failed pull")
}
```

`Mutex` is `Synchronization.Mutex` — add `import Synchronization` at the top of the test file.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SyncSessionTests`
Expected: FAIL — `value of type 'SyncSession' has no member 'pull'`.

- [ ] **Step 3: Write the implementation**

Add to `Sources/ADBKit/SyncSession.swift`:

```swift
extension SyncSession {
    /// Streams a remote file to disk.
    ///
    /// - Parameter onProgress: called with the *cumulative* byte count after
    ///   each chunk. Callers coalesce this before touching the UI — a fast
    ///   transfer produces thousands of calls per second.
    /// - Returns: total bytes written.
    @discardableResult
    public func pull(
        _ remotePath: String,
        to destination: URL,
        onProgress: @Sendable (Int64) -> Void = { _ in }
    ) async throws -> Int64 {
        try await underlyingStream.write(SyncPacket.request(.recv, path: remotePath))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        var total: Int64 = 0
        var succeeded = false
        defer {
            try? handle.close()
            // Rule 3 of the spec's error handling: no truncated files survive.
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }

        while true {
            let opcode = String(decoding: try await underlyingStream.read(exactly: 4), as: UTF8.self)
            switch opcode {
            case SyncOpcode.data.rawValue:
                let length = Int(try await readUInt32())
                guard length <= SyncSession.maxChunk else {
                    throw ADBError.malformedResponse("chunk of \(length) bytes exceeds the 64 KB maximum")
                }
                let chunk = try await underlyingStream.read(exactly: length)
                try handle.write(contentsOf: chunk)
                total += Int64(length)
                onProgress(total)
            case SyncOpcode.done.rawValue:
                _ = try await readUInt32()          // RECV's DONE is 8 bytes total
                succeeded = true
                return total
            case SyncOpcode.fail.rawValue:
                throw ADBError.transferFailed(path: remotePath, reason: try await readSyncMessage())
            default:
                throw ADBError.malformedResponse("unexpected sync opcode \(opcode) during pull")
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SyncSessionTests`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ADBKit/SyncSession.swift Tests/ADBKitTests/SyncSessionTests.swift
git commit -m "feat: pull files with byte-accurate progress and partial-file cleanup"
```

---

## Task 10: Pushing files with progress

**Files:**
- Modify: `Sources/ADBKit/SyncSession.swift` (add `push`), `Tests/ADBKitTests/SyncSessionTests.swift` (add push tests)

**Interfaces:**
- Consumes: everything from Task 9.
- Produces: `func push(_ source: URL, to remotePath: String, mode: UInt32 = 0o644, onProgress: @Sendable (Int64) -> Void) async throws -> Int64`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ADBKitTests/SyncSessionTests.swift`:

```swift
/// A sync_status reply: opcode plus a UInt32.
private func syncOkay() -> Data { Data("OKAY".utf8) + Data([0, 0, 0, 0]) }

@Test("push sends the path with its mode, then the file in DATA chunks")
func pushesFile() async throws {
    let source = URL.temporaryDirectory.appending(path: "push-\(UUID().uuidString).txt")
    try Data("hello world".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let stream = FakeADBServer(script: [syncOkay()])
    let sent = try await SyncSession(stream: stream)
        .push(source, to: "/sdcard/a.txt", mode: 0o644) { _ in }

    #expect(sent == 11)

    let written = stream.writtenBytes
    #expect(String(decoding: written.prefix(4), as: UTF8.self) == "SEND")
    // The path is sent as "<path>,<octal mode>".
    #expect(String(decoding: written, as: UTF8.self).contains("/sdcard/a.txt,644"))
    #expect(String(decoding: written, as: UTF8.self).contains("hello world"))
}

@Test("push splits a file larger than the 64 KB maximum into several chunks")
func pushesLargeFileInChunks() async throws {
    let source = URL.temporaryDirectory.appending(path: "push-\(UUID().uuidString).bin")
    try Data(repeating: 0x41, count: 70_000).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let stream = FakeADBServer(script: [syncOkay()])
    let sent = try await SyncSession(stream: stream).push(source, to: "/sdcard/big.bin") { _ in }

    #expect(sent == 70_000)

    // Count DATA opcodes: 70,000 bytes is 65,536 + 4,464, so exactly two.
    let written = stream.writtenBytes
    var dataFrames = 0
    for index in 0..<(written.count - 3) where written[written.startIndex + index] == 0x44 {
        if written[(written.startIndex + index)..<(written.startIndex + index + 4)]
            .elementsEqual(Data("DATA".utf8)) { dataFrames += 1 }
    }
    #expect(dataFrames == 2)
}

@Test("push reports a FAIL from the device")
func pushReportsFailure() async throws {
    let source = URL.temporaryDirectory.appending(path: "push-\(UUID().uuidString).txt")
    try Data("x".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    var failure = Data("FAIL".utf8)
    let message = Data("No space left on device".utf8)
    failure.append(contentsOf: withUnsafeBytes(of: UInt32(message.count).littleEndian, Array.init))
    failure.append(message)

    let stream = FakeADBServer(script: [failure])
    await #expect(throws: ADBError.self) {
        _ = try await SyncSession(stream: stream).push(source, to: "/sdcard/x.txt") { _ in }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SyncSessionTests`
Expected: FAIL — `value of type 'SyncSession' has no member 'push'`.

- [ ] **Step 3: Write the implementation**

Add to `Sources/ADBKit/SyncSession.swift`:

```swift
extension SyncSession {
    /// Streams a local file to the device.
    ///
    /// The SEND request carries "<path>,<octal mode>" as a single string —
    /// a quirk of the sync protocol worth remembering when debugging.
    @discardableResult
    public func push(
        _ source: URL,
        to remotePath: String,
        mode: UInt32 = 0o644,
        onProgress: @Sendable (Int64) -> Void = { _ in }
    ) async throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }

        let target = "\(remotePath),\(String(mode, radix: 8))"
        try await underlyingStream.write(SyncPacket.request(.send, path: target))

        var total: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: SyncSession.maxChunk) ?? Data()
            guard !chunk.isEmpty else { break }
            try await underlyingStream.write(
                SyncPacket(.data, value: UInt32(chunk.count)).encoded() + chunk
            )
            total += Int64(chunk.count)
            onProgress(total)
        }

        let mtime = (try? source.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date()
        try await underlyingStream.write(
            SyncPacket(.done, value: UInt32(mtime.timeIntervalSince1970)).encoded()
        )

        let opcode = String(decoding: try await underlyingStream.read(exactly: 4), as: UTF8.self)
        switch opcode {
        case SyncOpcode.okay.rawValue:
            _ = try await readUInt32()
            return total
        case SyncOpcode.fail.rawValue:
            throw ADBError.transferFailed(path: remotePath, reason: try await readSyncMessage())
        default:
            throw ADBError.malformedResponse("unexpected sync opcode \(opcode) after push")
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SyncSessionTests`
Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ADBKit/SyncSession.swift Tests/ADBKitTests/SyncSessionTests.swift
git commit -m "feat: push files in 64 KB chunks with progress reporting"
```

---

## Task 11: Shell session

Needed for `df` (free space), `mkdir`, `rm`, and `getprop ro.product.model` to give the device a human name.

**Files:**
- Create: `Sources/ADBKit/ShellSession.swift`, `Tests/ADBKitTests/ShellSessionTests.swift`

**Interfaces:**
- Consumes: `ADBServer`, `ByteStream`, `ADBError`.
- Produces:
  - `struct ShellResult: Sendable, Equatable` with `let stdout: String`, `let stderr: String`, `let exitCode: Int32`
  - `struct ShellSession: Sendable` with `init(server: ADBServer, serial: String)`, `func run(_ command: String) async throws -> ShellResult`
  - `static func ShellSession.parseFreeSpace(_ dfOutput: String) -> Int64?`

- [ ] **Step 1: Write the failing tests**

`Tests/ADBKitTests/ShellSessionTests.swift`:

```swift
import Foundation
import Testing
@testable import ADBKit

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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ShellSessionTests`
Expected: FAIL — `cannot find 'ShellSession' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/ADBKit/ShellSession.swift`:

```swift
import Foundation

public struct ShellResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// Runs commands through `shell,v2:`, which — unlike the v1 shell service —
/// separates stdout from stderr and returns a real exit code.
public struct ShellSession: Sendable {
    private let server: ADBServer
    private let serial: String

    public init(server: ADBServer, serial: String) {
        self.server = server
        self.serial = serial
    }

    public func run(_ command: String) async throws -> ShellResult {
        let stream = try await server.request("host:transport:\(serial)")
        defer { Task { await stream.close() } }
        try await ADBServer.send(service: "shell,v2:\(command)", over: stream)

        var stdout = Data(), stderr = Data()
        var exitCode: Int32 = 0

        // shell,v2 frames: 1-byte id, 4-byte little-endian length, payload.
        // ids: 1 = stdout, 2 = stderr, 3 = exit code.
        loop: while true {
            let header: Data
            do {
                header = try await stream.read(exactly: 5)
            } catch ADBError.connectionClosed {
                break loop
            }
            let id = header[header.startIndex]
            let length = Int(UInt32(littleEndian: header.dropFirst()
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            let payload = length > 0 ? try await stream.read(exactly: length) : Data()
            switch id {
            case 1: stdout.append(payload)
            case 2: stderr.append(payload)
            case 3:
                exitCode = Int32(payload.first ?? 0)
                break loop
            default: break
            }
        }

        return ShellResult(
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            exitCode: exitCode
        )
    }

    /// Reads the Available column from `df -k <path>`, in bytes.
    /// Returns nil rather than guessing — a wrong free-space number would
    /// let a transfer start that cannot finish.
    public static func parseFreeSpace(_ dfOutput: String) -> Int64? {
        for line in dfOutput.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 4, let kibibytes = Int64(columns[3]) else { continue }
            return kibibytes * 1024
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ShellSessionTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS, 38 tests, no concurrency warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/ADBKit/ShellSession.swift Tests/ADBKitTests/ShellSessionTests.swift
git commit -m "feat: run shell commands with separated streams and exit codes"
```

---

## Task 12: CLI harness and real-device verification

The exit criterion for this plan. Everything so far has been tested against fakes; this proves it against actual hardware.

**Requires the prerequisites at the top of this document.**

**Files:**
- Create: `Sources/fileferry-cli/main.swift`, `docs/ADB_PROTOCOL.md`

**Interfaces:**
- Consumes: every public type in `ADBKit`.
- Produces: a `fileferry-cli` executable with subcommands `devices`, `ls <path>`, `pull <remote> <local>`, `push <local> <remote>`.

- [ ] **Step 1: Write the CLI**

`Sources/fileferry-cli/main.swift`:

```swift
import Foundation
import ADBKit

func usage() -> Never {
    print("""
    fileferry-cli — ADBKit harness

      devices
      ls    <remote-path>
      pull  <remote-path> <local-path>
      push  <local-path>  <remote-path>
    """)
    exit(2)
}

func humanBytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

/// Reprints a single progress line; total may be 0 when the size is unknown.
func showProgress(_ done: Int64, _ total: Int64, since start: Date) {
    let elapsed = max(Date().timeIntervalSince(start), 0.001)
    let rate = Double(done) / elapsed
    let percent = total > 0 ? " \(Int(Double(done) / Double(total) * 100))%" : ""
    let line = "\r\(humanBytes(done))\(percent) · \(humanBytes(Int64(rate)))/s    "
    FileHandle.standardError.write(Data(line.utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

let binary = try ADBBinary.resolve()
FileHandle.standardError.write(Data("using adb \(binary.version) at \(binary.url.path)\n".utf8))

let server = ADBServer(binary: binary)
try await server.ensureRunning()

/// Picks the single connected, authorized device, or explains what is wrong.
func firstReadyDevice() async throws -> String {
    var iterator = DeviceTracker(server: server).devices().makeAsyncIterator()
    guard let devices = try await iterator.next() else {
        throw ADBError.deviceNotFound("none")
    }
    if let ready = devices.first(where: { $0.state == .device }) {
        return ready.serial
    }
    if let unauthorized = devices.first(where: { $0.state == .unauthorized }) {
        FileHandle.standardError.write(Data("""
        Device \(unauthorized.serial) is connected but not authorized.
        Unlock the phone and tap "Allow" on the USB debugging prompt.

        """.utf8))
    }
    throw ADBError.deviceNotFound("no authorized device")
}

switch command {
case "devices":
    var iterator = DeviceTracker(server: server).devices().makeAsyncIterator()
    let devices = try await iterator.next() ?? []
    if devices.isEmpty {
        print("no devices — check the cable, and that it is a data cable rather than charge-only")
    }
    for device in devices { print("\(device.serial)\t\(device.state.rawValue)") }

case "ls":
    guard arguments.count == 2 else { usage() }
    let session = try await SyncSession.open(server: server, serial: try await firstReadyDevice())
    defer { Task { await session.close() } }
    let started = Date()
    let entries = try await session.list(arguments[1])
    let elapsed = Date().timeIntervalSince(started)
    for entry in entries.sorted(by: { $0.name < $1.name }) {
        let kind = entry.isDirectory ? "d" : "-"
        print("\(kind) \(humanBytes(entry.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(entry.name)")
    }
    print("\(entries.count) entries in \(String(format: "%.0f", elapsed * 1000)) ms")

case "pull":
    guard arguments.count == 3 else { usage() }
    let session = try await SyncSession.open(server: server, serial: try await firstReadyDevice())
    defer { Task { await session.close() } }
    let size = (try? await session.stat(arguments[1]).size) ?? 0
    let started = Date()
    let written = try await session.pull(arguments[1], to: URL(fileURLWithPath: arguments[2])) {
        showProgress($0, size, since: started)
    }
    print("\npulled \(humanBytes(written)) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

case "push":
    guard arguments.count == 3 else { usage() }
    let source = URL(fileURLWithPath: arguments[1])
    let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
    let session = try await SyncSession.open(server: server, serial: try await firstReadyDevice())
    defer { Task { await session.close() } }
    let started = Date()
    let sent = try await session.push(source, to: arguments[2]) {
        showProgress($0, size ?? 0, since: started)
    }
    print("\npushed \(humanBytes(sent)) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

default:
    usage()
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds clean, no concurrency warnings.

- [ ] **Step 3: Verify against a real device — device detection**

Run: `swift run fileferry-cli devices`
Expected: your phone's serial and `device`. If it prints `unauthorized`, unlock the phone and accept the prompt. If it prints nothing, the cable may be charge-only.

- [ ] **Step 4: Verify listing, including a large directory**

```bash
swift run fileferry-cli ls /sdcard
swift run fileferry-cli ls /sdcard/DCIM/Camera
```

Expected: correct entries with plausible sizes and directory flags. Note the reported millisecond timing on the camera folder — **this is the number that justifies choosing ADB over MTP**, and it belongs in `docs/ADB_PROTOCOL.md`.

- [ ] **Step 5: Verify a round trip, including a file over 4 GB**

```bash
# A small round trip first.
echo "fileferry round trip" > /tmp/fileferry-test.txt
swift run fileferry-cli push /tmp/fileferry-test.txt /sdcard/Download/fileferry-test.txt
swift run fileferry-cli pull /sdcard/Download/fileferry-test.txt /tmp/fileferry-back.txt
diff /tmp/fileferry-test.txt /tmp/fileferry-back.txt && echo "round trip OK"

# Then the 4 GB boundary that v1 opcodes get wrong.
mkfile -n 5g /tmp/fileferry-big.bin
swift run fileferry-cli push /tmp/fileferry-big.bin /sdcard/Download/fileferry-big.bin
swift run fileferry-cli ls /sdcard/Download   # must report ~5 GB, not a wrapped value
swift run fileferry-cli pull /sdcard/Download/fileferry-big.bin /tmp/fileferry-big-back.bin
shasum -a 256 /tmp/fileferry-big.bin /tmp/fileferry-big-back.bin   # hashes must match
```

Expected: `diff` silent, both hashes equal, and the 5 GB file reported at its true size. A size near 705 MB instead of 5 GB means a v1 opcode leaked in — `5,000,000,000 mod 2^32`.

- [ ] **Step 6: Clean up the device**

```bash
adb shell rm /sdcard/Download/fileferry-test.txt /sdcard/Download/fileferry-big.bin
rm -f /tmp/fileferry-test.txt /tmp/fileferry-back.txt /tmp/fileferry-big.bin /tmp/fileferry-big-back.bin
```

- [ ] **Step 7: Record what you learned**

Write `docs/ADB_PROTOCOL.md` covering: the two framing layers and how they differ, the exact `sync_dent_v2` and `sync_stat_v2` offsets you confirmed against AOSP, the context-dependent size of `DONE` (72 bytes after a list, 8 after a RECV), the `"<path>,<octal mode>"` quirk in SEND, and the measured listing time and throughput from Steps 4 and 5.

- [ ] **Step 8: Commit**

```bash
git add Sources/fileferry-cli docs/ADB_PROTOCOL.md
git commit -m "feat: add CLI harness and document the adb wire protocol"
```

---

## Definition of done

- [ ] `swift test` passes with 38 tests and no strict-concurrency warnings
- [ ] CI is green on `macos-15`
- [ ] `fileferry-cli devices` detects a real phone and distinguishes `unauthorized` from `device`
- [ ] `fileferry-cli ls /sdcard/DCIM/Camera` returns a large directory in under a second
- [ ] A 5 GB file round-trips with matching SHA-256 and a correctly reported size
- [ ] A failed pull leaves no partial file on disk
- [ ] `docs/ADB_PROTOCOL.md` records the offsets and the measured numbers

---

## Self-review notes

Checked against the spec:

- **§2 wire protocol** — Tasks 2, 5, 7–11 cover `host:version`, `host:track-devices`, `host:transport:`, `sync:` (`LIS2`/`STA2`/`RECV`/`SEND`) and `shell,v2:`. ✅
- **§2 v2 opcodes and the 4 GB trap** — enforced by tests in Tasks 7 and 8, verified on hardware in Task 12 Step 5. ✅
- **§2 adb not bundled** — Task 4 locates a system binary; a global constraint forbids vendoring. ✅
- **§4 concurrency** — `ADBServer` and `TCPByteStream` are actors; strict concurrency is a global constraint. ✅
- **§7 no truncated files survive** — Task 9's `pullCleansUpPartialFile` test. ✅
- **§8 testable with no phone** — every test through Task 11 runs against `FakeADBServer`; only `TCPByteStreamTests` opens a socket, and it starts its own listener. ✅

**Deliberate deviation from the spec:** §8 describes `FakeADBServer` as replaying fixtures over a *local socket*. Here it vends an in-memory `ByteStream` instead. The parsing and framing coverage is identical, it removes socket flakiness from CI, and `TCPByteStreamTests` covers the `NWConnection` glue separately. Recorded here so the difference is a decision rather than a drift.

**Not in this plan, by design:** `host-serial:<s>:features` negotiation and the v1 opcode fallback. The v2 opcodes have been standard since Android 8, and adding the fallback now would mean writing a second untested code path. It belongs in Plan 2, gated on a real device that needs it.

**Deferred to Plan 2:** `DeviceTransport`, `TransferEngine`, `LocalTransport`, `FakeTransport`, conflict policy, and move verification. `ADBKit` deliberately knows nothing about any of them.
