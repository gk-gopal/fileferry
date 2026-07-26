// swift-tools-version:6.0
import PackageDescription

let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "Conduit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ADBKit", targets: ["ADBKit"]),
        .executable(name: "conduit-cli", targets: ["conduit-cli"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "ADBKit", swiftSettings: strict),
        .executableTarget(name: "conduit-cli", dependencies: ["ADBKit"], swiftSettings: strict),
        .testTarget(name: "ADBKitTests", dependencies: ["ADBKit"], swiftSettings: strict),
    ]
)
