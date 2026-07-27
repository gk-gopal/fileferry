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

FileFerry is not notarized — Apple charges $99/yr for that and this project
doesn't take your money — so anything you *download* gets quarantined by macOS
and blocked on first launch.

**From source (no Gatekeeper prompt at all).** Quarantine is applied by the
downloader, not at launch, so a locally built app is never flagged:

    git clone https://github.com/gk-gopal/fileferry
    cd fileferry
    Scripts/make-app.sh release      # -> dist/FileFerry.app

**Homebrew.** Convenient, but you still have to allow the app once:

    brew tap gk-gopal/tap
    brew install --cask fileferry

**From a release DMG.** Same as Homebrew — allow it once.

To allow a blocked app on **macOS 15 or later**: System Settings → Privacy &
Security → scroll to "FileFerry was blocked" → **Open Anyway** → password. On
**macOS 14**: right-click → Open → confirm.

> Homebrew's `--no-quarantine` flag used to skip this. It has been removed
> with no replacement, and Homebrew is
> [dropping casks that fail Gatekeeper checks on 1 September 2026](https://github.com/Homebrew/brew/issues/20755).

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
