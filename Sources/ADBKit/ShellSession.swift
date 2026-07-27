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
        return try await ShellSession.readResult(from: stream)
    }

    /// shell,v2 frames are: 1-byte id, 4-byte little-endian length, payload.
    /// ids: 1 = stdout, 2 = stderr, 3 = exit code.
    static func readResult(from stream: any ByteStream) async throws -> ShellResult {
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32 = 0

        loop: while true {
            let header: Data
            do {
                header = try await stream.read(exactly: 5)
            } catch ADBError.connectionClosed {
                break loop
            }
            let id = header[header.startIndex]
            let length = header.dropFirst().withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
            }
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

    /// A name worth showing a person, rather than a serial number.
    ///
    /// Android has no single property for this. `ro.product.model` gives a
    /// part number on many phones — a OnePlus 12R reports "CPH2585" — so the
    /// vendor-specific marketing names are tried first. All of them are read
    /// in one round trip and resolved here.
    public func deviceName() async -> String? {
        let properties = [
            "ro.product.marketname",          // several OEMs
            "ro.vendor.oplus.market.name",    // OnePlus, Oppo, Realme
            "ro.config.marketing_name",       // Samsung
            "ro.product.vendor.marketname",
        ]
        let command = (properties + ["ro.product.brand", "ro.product.model"])
            .map { "getprop \($0)" }
            .joined(separator: "; ")

        guard let result = try? await run(command), result.succeeded else { return nil }
        let values = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // A marketing name, if any vendor supplied one.
        for value in values.prefix(properties.count) where !value.isEmpty {
            return value
        }

        // Otherwise "OnePlus CPH2585" beats a bare part number.
        let brand = values.count > properties.count ? values[properties.count] : ""
        let model = values.count > properties.count + 1 ? values[properties.count + 1] : ""
        guard !model.isEmpty else { return nil }
        guard !brand.isEmpty, !model.lowercased().hasPrefix(brand.lowercased()) else { return model }
        return "\(brand.capitalized) \(model)"
    }

    /// Reads the Available column from `df -k <path>`, in bytes.
    ///
    /// Returns nil rather than guessing — a wrong free-space number would let
    /// a transfer start that cannot possibly finish.
    public static func parseFreeSpace(_ dfOutput: String) -> Int64? {
        for line in dfOutput.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 4, let kibibytes = Int64(columns[3]) else { continue }
            return kibibytes * 1024
        }
        return nil
    }
}
