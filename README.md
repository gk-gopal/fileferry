# FileFerry

Copy and move files between a Mac and an Android phone over USB, at USB speed.

FileFerry talks to Android over ADB rather than MTP, which makes it dramatically
faster on folders with many files — the case where Android File Transfer and
other MTP-based tools slow to a crawl.

**Status:** in development. Not yet released. The protocol layer works and is
verified against real hardware — a 5 GiB file round-trips byte-identical at
33–42 MB/s, and an 871-entry camera folder lists in 414 ms. See
[`docs/ADB_PROTOCOL.md`](docs/ADB_PROTOCOL.md) for the full measurements.

## Installing

**Homebrew (recommended).** Nothing to click past — Homebrew skips the
quarantine flag, so Gatekeeper never gets involved:

    brew tap gk-gopal/tap
    brew install --cask --no-quarantine fileferry

**From source.** Locally built apps are never quarantined either:

    git clone https://github.com/gk-gopal/fileferry
    cd fileferry
    Scripts/make-app.sh release      # -> dist/FileFerry.app

**From a release DMG.** Works, but FileFerry is not notarized — Apple charges
$99/yr for that and this project doesn't take your money — so macOS blocks it
on first launch. On macOS 15 and later you'll need System Settings > Privacy &
Security > **Open Anyway**. The two options above avoid this.

## Requirements

- macOS 14 or later
- `adb` — install with `brew install --cask android-platform-tools`
- USB debugging enabled on the phone

## Building

    swift build
    swift test

The test suite needs neither `adb` nor a connected phone — every protocol test
runs against an in-memory fake.

If `swift test` fails with `no such module 'Testing'`, your command line tools
are selected instead of Xcode. The Command Line Tools toolchain does not ship
Swift Testing. Fix it once with:

    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

or set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for a single
command.

## Design

- [Design spec](docs/superpowers/specs/2026-07-26-fileferry-design.md) — what it does and why
- [Plan 1: Foundation & ADBKit](docs/superpowers/plans/2026-07-26-foundation-and-adbkit.md)
- [UI mockups](docs/mockups/) — open the HTML files in a browser

## Licence

MIT
