// swift-tools-version:6.0
import PackageDescription

let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]

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
    ]
)
