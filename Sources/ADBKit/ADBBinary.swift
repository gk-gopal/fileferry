import Foundation

/// Locates the system adb binary and checks it is new enough.
///
/// Conduit deliberately does not bundle adb: Google's prebuilt platform-tools
/// may not be redistributed under the Android SDK terms.
public struct ADBBinary: Sendable, Equatable {
    public static let minimumVersion = "34.0.0"

    public let url: URL
    public let version: String

    public init(url: URL, version: String) {
        self.url = url
        self.version = version
    }

    /// Search order: configured path, ANDROID_HOME, Homebrew, /usr/local.
    ///
    /// `fileExists` is injected so this is testable without touching disk.
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
        candidates.append("/opt/homebrew/bin/adb")   // Apple Silicon Homebrew
        candidates.append("/usr/local/bin/adb")      // Intel Homebrew, manual installs
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

    /// Component-wise numeric comparison. Plain string comparison would rank
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
