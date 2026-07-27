// swift-tools-version:6.0
import PackageDescription

let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "Conduit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ADBKit", targets: ["ADBKit"]),
        .library(name: "TransportKit", targets: ["TransportKit"]),
        .library(name: "LocalTransport", targets: ["LocalTransport"]),
        .library(name: "ADBTransport", targets: ["ADBTransport"]),
        .executable(name: "conduit-cli", targets: ["conduit-cli"]),
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
            name: "conduit-cli",
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
