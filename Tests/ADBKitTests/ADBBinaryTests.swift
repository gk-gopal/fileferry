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
