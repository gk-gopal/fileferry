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

```bash
curl -fsSL https://raw.githubusercontent.com/gk-gopal/fileferry/main/Scripts/install.sh | bash
```

That's the whole thing. It downloads the latest release, installs it to
`/Applications`, and launches it — no Gatekeeper prompt to click past.

<details>
<summary>What that script does, and what you're trusting</summary>

FileFerry is not notarized. Apple charges $99/yr for that and this project
doesn't take your money, so macOS would normally quarantine the download and
block the first launch. The installer clears that quarantine flag, which is
what Homebrew's now-removed `--no-quarantine` did.

That means macOS stops checking with Apple, so you are trusting this build
instead. The installer prints the SHA-256 of what it installed; compare it
against `SHA256SUMS.txt` on the [releases
page](https://github.com/gk-gopal/fileferry/releases). The script itself is
[right here](Scripts/install.sh) — read it before piping it into your shell,
as you should with any such command.

It also checks your macOS version, warns if `adb` is missing, and prints the
phone setup steps.

</details>

### Other ways

**From source** — no quarantine at all, since it's applied to things you
*download*, not things you build. Needs Xcode:

```bash
git clone https://github.com/gk-gopal/fileferry
cd fileferry && Scripts/make-app.sh release      # -> dist/FileFerry.app
```

**Homebrew** — works, but it's three commands and *still* leaves you with the
Gatekeeper prompt, because Homebrew no longer has a way to skip quarantine:

```bash
brew tap gk-gopal/tap
brew trust gk-gopal/tap        # required for third-party taps
brew install --cask fileferry
```

You'll then need System Settings → Privacy & Security → **Open Anyway** on
first launch (macOS 15+), or right-click → Open (macOS 14).

> Homebrew removed `--no-quarantine` with no replacement, and is
> [dropping casks that fail Gatekeeper checks on 1 September 2026](https://github.com/Homebrew/brew/issues/20755),
> so this route may stop working unless FileFerry gets notarized.

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
