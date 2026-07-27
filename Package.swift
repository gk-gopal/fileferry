// swift-tools-version:6.0
import PackageDescription

// Declared package-wide rather than as a per-target SwiftSetting. The
// multi-architecture build path (`swift build --arch arm64 --arch x86_64`)
// rejects per-target .swiftLanguageMode on older toolchains, which broke the
// universal build on CI while working locally.
let strict: [SwiftSetting] = []

let package = Package(
    name: "FileFerry",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ADBKit", targets: ["ADBKit"]),
        .library(name: "TransportKit", targets: ["TransportKit"]),
        .library(name: "LocalTransport", targets: ["LocalTransport"]),
        .library(name: "ADBTransport", targets: ["ADBTransport"]),
        .executable(name: "fileferry-cli", targets: ["fileferry-cli"]),
        .executable(name: "FileFerry", targets: ["FileFerry"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "ADBKit", swiftSettings: strict),
        .target(name: "TransportKit", swiftSettings: strict),
        .target(name: "LocalTransport", dependencies: ["TransportKit"], swiftSettings: strict),
        .target(
            name: "ADBTransport",
            dependencies: ["TransportKit", "ADBKit"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "FileFerry",
            dependencies: ["ADBKit", "TransportKit", "LocalTransport", "ADBTransport"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "fileferry-cli",
            dependencies: ["ADBKit", "TransportKit", "LocalTransport", "ADBTransport"],
            swiftSettings: strict
        ),
        .testTarget(name: "ADBKitTests", dependencies: ["ADBKit"], swiftSettings: strict),
        .testTarget(
            name: "TransportKitTests",
            dependencies: ["TransportKit", "LocalTransport"],
            swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
