# Conduit

Copy and move files between a Mac and an Android phone over USB, at USB speed.

Conduit talks to Android over ADB rather than MTP, which makes it dramatically
faster on folders with many files — the case where Android File Transfer and
other MTP-based tools slow to a crawl.

**Status:** in development. Not yet released.

## Requirements

- macOS 14 or later
- `adb` — install with `brew install --cask android-platform-tools`
- USB debugging enabled on the phone

## Building

    swift build
    swift test

The test suite needs neither `adb` nor a connected phone — every protocol test
runs against an in-memory fake.

## Design

- [Design spec](docs/superpowers/specs/2026-07-26-conduit-design.md) — what it does and why
- [Plan 1: Foundation & ADBKit](docs/superpowers/plans/2026-07-26-foundation-and-adbkit.md)
- [UI mockups](docs/mockups/) — open the HTML files in a browser

## Licence

MIT
