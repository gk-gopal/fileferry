# Conduit — Design Spec

**Date:** 2026-07-26
**Status:** Approved, ready for implementation planning

A native macOS app for copying and moving files between a Mac and an Android device over USB, using ADB as the transport.

> The name `Conduit` is provisional. It appears in the bundle identifier (`dev.gopalkannan.conduit`), the repo name, and the app name. Changing it is a find-and-replace; doing so after a tagged release is not. Check it against a trademark search before any public release.

---

## 1. Purpose

Move arbitrary files between a Mac folder and an Android folder, in either direction, as a deliberate act. The user's own framing: *"Any files. Not history maintained. Anything I decided to copy or move between Mac & Phone. Like copying or moving between 2 folders."*

That sentence sets the entire scope. Three consequences, all of which remove work:

- **Stateless.** No sync engine, no "new since last time", no transfer log, no dedupe. Every operation is explicit and initiated by the user.
- **Type-agnostic.** No photo-import wizard, no media library, no thumbnail pipeline. A file is a file.
- **Symmetric.** Two folders, side by side, equal standing. Neither side is "the app's" side.

### Audience

An open-source project. Users are technical enough to run one Homebrew command, and contributors are users too — so documentation, test coverage, and module boundaries are part of the product, not overhead.

### Success criteria

1. Copying a 2,000-file nested folder in either direction completes with accurate progress and no corrupted files.
2. A 5 GB file transfers without failure or size misreporting.
3. Pulling the cable mid-transfer leaves no truncated files and no lost originals.
4. Directory listings feel instant — a 10,000-entry camera folder opens in well under a second.
5. Someone who has never enabled USB debugging can go from download to first transfer without asking a question.

### Non-goals

Wireless transfer (LocalSend and KDE Connect already do this well, cross-platform). Mac App Store distribution — see §3. Background or scheduled sync. Access to `/data/data` on non-rooted devices. Screen mirroring. Media conversion.

---

## 2. Transport: ADB over USB

ADB was chosen over MTP on both speed and buildability.

| | ADB | MTP |
|---|---|---|
| One large file | ~40–120 MB/s on USB 3 | ~10–30 MB/s, unreliable past 4 GB |
| Thousands of small files | Near line rate | 1–3 MB/s effective — per-object overhead dominates |
| Listing a 10k-entry directory | One streamed response | Seconds to tens of seconds |
| Effort on macOS | Bundled binary, documented services | No native stack; vendor libmtp + libusb + a C bridge, then absorb per-vendor quirks |

The cost is one-time per-phone setup: enable Developer Options, turn on USB debugging, accept the RSA fingerprint prompt. Roughly 60 seconds, permanent for that Mac/phone pair. §7 makes that setup a first-class part of the UI rather than a README footnote.

### Driving ADB: the wire protocol, not the CLI

`adb` runs a server process that owns the USB connection; everything else is a client of it. We let the binary be the server and speak its protocol directly on `127.0.0.1:5037` rather than shelling out and parsing text. This is what Android Studio does.

Requests are `%04x`-length-prefixed strings answered by `OKAY` or `FAIL`. The services we use:

| Service | Purpose |
|---|---|
| `host:track-devices` | Persistent stream of device state changes — the sidebar updates on plug-in with no polling |
| `host-serial:<s>:features` | Feature negotiation, gates the v2 sync opcodes |
| `sync:` → `LIS2` | Directory listing, 64-bit sizes, real mtimes |
| `sync:` → `STA2` | Stat one path, 64-bit — the basis of move verification |
| `sync:` → `RECV` | Pull, 64 KB chunks — byte-accurate progress |
| `sync:` → `SEND` | Push, same |
| `shell,v2:` | Separated stdout/stderr and a real exit code, for `df`, `getprop`, `mkdir`, `rm` |

**Always use `LIS2`/`STA2`, never legacy `LIST`/`STAT`.** The original opcodes encode size as a 32-bit integer and silently misreport files ≥ 4 GB — precisely the 4K-video case. Gate on the `ls_v2`/`stat_v2` feature flags; fall back to legacy opcodes only on devices that lack them, and cap reported sizes honestly when doing so.

**Risk and escape hatch.** The protocol is not formally specified; it is described in AOSP's `SERVICES.TXT` and kept stable in practice because Android Studio depends on it. If it proves troublesome, CLI shelling implements the same `DeviceTransport` interface (§4) at the cost of coarse progress reporting. The UI is unaffected either way.

### `adb` is not bundled

The app requires `adb` on the system and does not ship a copy. Google's prebuilt `platform-tools` is covered by the Android SDK Terms, which prohibit redistribution; building `adb` from AOSP source (Apache 2.0) is legal but is a build-system project of its own. Since the audience is technical, the app detects a missing binary and offers the one-line fix:

```
brew install --cask android-platform-tools
```

Resolution order: user-configured path → `$ANDROID_HOME/platform-tools/adb` → `/opt/homebrew/bin/adb` → `/usr/local/bin/adb` → `PATH`. Minimum version: platform-tools 34.

---

## 3. Distribution

Direct download, plus a Homebrew cask. Not the Mac App Store.

App Store submissions must enable App Sandbox, and an ADB-based app needs raw USB access plus a persistent localhost daemon on port 5037 that outlives the app and conflicts with any `adb` the user already runs. No ADB-based Android transfer app exists on the Mac App Store; MacDroid, AnyDroid, and Google's own Android File Transfer all ship outside it. This is a settled constraint, not a deferred ambition.

Consequences: no Apple Developer Program membership is required to build or contribute. Developer ID signing and notarization are still wanted before a public release so the DMG opens without a Gatekeeper fight, but they gate only the release, not development.

---

## 4. Architecture

Four modules, dependencies pointing one direction.

```
Conduit (app, SwiftUI)
    │
    ▼
TransportKit ──────────┐   DeviceTransport, TransferEngine, ConflictPolicy
    ▲                  │
    │                  │
ADBTransport   LocalTransport   FakeTransport
    │                  │              │
    ▼                  ▼              ▼
 ADBKit          FileManager      in-memory
                  + FSEvents      (tests only)
```

`ADBKit` knows sockets and the adb protocol; it has no concept of a queue or a UI. `TransportKit` defines what a device is and how transfers are orchestrated; it has no concept of ADB. The app imports only `TransportKit`.

The abstraction earns its place through `FakeTransport`: the entire transfer engine and app logic become testable with no phone and no adb attached, which is the only way CI can verify anything meaningful. That it would also accommodate another transport later is a side benefit, not the motivation.

### The Mac is a transport too

```swift
protocol DeviceTransport: Sendable {
    func list(_ path: Path) async throws -> [Entry]
    func stat(_ path: Path) async throws -> Entry
    func read(_ path: Path) -> AsyncThrowingStream<Chunk, Error>
    func write(_ path: Path, from: AsyncThrowingStream<Chunk, Error>) async throws
    func mkdir(_ path: Path) async throws
    func delete(_ path: Path) async throws
    func freeSpace(at path: Path) async throws -> Int64
}
```

`LocalTransport` and `ADBTransport` both conform. A transfer is therefore `transfer(from: any DeviceTransport, to: any DeviceTransport)` with no notion of which side is which — one code path serves both directions, and there is no separate "upload" and "download" implementation to keep in agreement. The file pane is one view instantiated twice.

### Components

**ADBKit** — `ADBBinary` (locate, version-check), `ADBServer` (actor: start or adopt a running server), `ADBConnection` (socket, framing, timeouts, cancellation), `DeviceTracker` (`host:track-devices` → `AsyncStream<[Device]>`), `SyncSession` (`LIS2`/`STA2`/`RECV`/`SEND`), `ShellSession` (`shell,v2:`).

**TransportKit** — `DeviceTransport`, `TransferEngine` (actor: queue, progress, cancellation, move verification), `TransferItem`, `TransferJob`, `ConflictPolicy`, `DirectoryCache`.

**App** — `PaneModel` ×2 (current path, listing, selection, per-pane navigation history), `SidebarModel` (favourites and pins), plus the views in §6.

### Concurrency

Swift 6 strict concurrency checking, enabled from the first commit. `ADBServer` and `TransferEngine` are actors. UI state is `@MainActor @Observable`.

The engine runs a **global pool of two transfer workers**. Each worker owns its own socket and its own `SyncSession`, so the two are independent connections rather than contending writers. Jobs feed items into the shared pool; a worker holds its session open across many files.

### Performance decisions

- **One `SyncSession` per worker, not per file.** The sync service accepts many SEND/RECV round trips on a single connection, so a worker transfers file after file without reconnecting. Tearing down and rebuilding the connection per file is what makes naive implementations crawl on a 2,000-file folder. This is the single largest throughput decision in the app.
- **Two workers.** USB is the bottleneck for large files; additional streams reduce total throughput and make progress harder to read. Two is also the natural ceiling given each worker needs its own session.
- **64 KB chunks** — the sync protocol's maximum payload.
- **Progress coalesced to ~10 Hz** before reaching the UI. Publishing every chunk would pin the main thread during a fast transfer.
- **Directory listings cached** per path, invalidated on any write we perform.

---

## 5. Data flow

### Navigation

Sidebar click, breadcrumb click, or double-click on a folder row → `PaneModel` sets its path → `DirectoryCache` lookup → on miss, `transport.list(path)` → entries sorted and rendered. The Mac pane additionally registers an FSEvents watch on its current path.

### Transfer

1. The selection plus a direction button builds a `TransferJob { source, destination, paths, mode }` where mode is `.copy` or `.move`.
2. The engine expands directories depth-first into concrete `TransferItem`s, creating destination directories as needed.
3. **Preflight.** Sum the bytes, compare against `destination.freeSpace`. Insufficient space fails the job immediately with a clear message — before transferring anything, not 900 MB in.
4. **Conflict check.** `destination.stat` each item; apply `ConflictPolicy`.
5. Items are handed to the two-worker pool. `source.read(path)` streams into `destination.write(path,·)`, each worker reusing its own long-lived `SyncSession` across successive files.
6. Byte counts flow through a counting wrapper into an `AsyncStream`, coalesced to 10 Hz, then to the main actor.
7. **Move verification.** On item completion, if mode is `.move`: `destination.stat(path)` and compare size against the source entry. Equal → delete the original. Not equal → the item fails and the original is left untouched.
8. Invalidate the cache for both affected paths; refresh both panes.

### Conflict policy

`ask` (default), `skip`, `overwrite`, `rename`. The `ask` dialog offers "apply to all remaining" so a 500-file collision is one decision.

---

## 6. User interface

One window. Dual pane, sidebar in each pane, action column between them. This is layout **B1**, the first of the two variants mocked up in `docs/mockups/layout-b2.html`.

```
┌──────────┬─────────────────────┬──────┬─────────────────────┬──────────┐
│ FAVOURITES│ ← → ↑  ~/Downloads │ →Copy│ ← → ↑ /sdcard/Down… │ Pixel 8  │
│ 🏠 Home   │ Name        Size   │ ⇢Move│ Name          Size  │ ▓▓▓░ 41GB│
│ ⬇ Downloads│ 📁 invoices  —     │ ──── │ 📁 Telegram    —    │ ⬇ Download│
│ 🖥 Desktop │ 📄 contract  2.4MB │ ←Copy│ 🖼 IMG_2033  3.9MB  │ 📷 Camera │
│ 📄 Documents│ 🗜 backup   1.2GB │ ⇠Move│ 📄 boarding  210KB  │ 🎵 Music  │
├──────────┴─────────────────────┴──────┴─────────────────────┴──────────┤
│ photos-backup.zip  ▓▓▓▓▓▓▓░░░  62% · 78 MB/s · 4s left      [Cancel]   │
└────────────────────────────────────────────────────────────────────────┘
```

### Why the centre action column

Each of the four buttons names its own direction, so there is no focused-pane rule to learn. This is a safety property rather than a stylistic one: a move deletes the original, and "whichever pane you clicked last" is a poor rule to hang a deletion on. Move buttons are tinted to distinguish them from copy. Buttons disable when the source selection is empty.

### Sidebars

150px each, collapsible independently (⌘1 Mac, ⌘2 phone). Below a 900px window width, one auto-collapses rather than letting the lists become unusable.

The Mac sidebar mirrors Finder's favourites and locations. The phone sidebar leads with the device and a storage meter, then the standard Android folders: Download, DCIM/Camera, Pictures, Music, Movies, Documents.

**Dropping files onto a sidebar favourite transfers them there** without either pane navigating. This is the main reason sidebars exist rather than a dropdown menu, and it works in both directions.

### Navigation controls

Per-pane back/forward/up (⌘[ ⌘] ⌘↑) with in-memory history. Clickable breadcrumb segments. Double-click a row to enter a folder; ⏎ rename; Space Quick Look; ⌫ delete with confirmation. Selecting a folder and pressing Copy transfers it recursively.

The Mac pane offers **Choose Folder…** via `NSOpenPanel`, inheriting Finder's sidebar, tags, iCloud Drive and external volumes at no cost. Dragging a folder from Finder onto the pane navigates there. The phone pane has no system picker, so it offers **Go to Path…** (⇧⌘G) with tab completion, and **Pin This Folder** (⌘D).

### Refresh behaviour

The two sides are asymmetric because macOS pushes filesystem events and Android does not.

| Trigger | Mac pane | Phone pane |
|---|---|---|
| A file changes underneath | Instant, via FSEvents | Not detected |
| Navigating to the folder | Instant | Typically < 100 ms |
| An operation Conduit performed | Instant | Instant — we know what changed |
| Window regains focus | — | Re-listed |
| ⌘R | Instant | Re-listed |
| Background polling | Not needed | Opt-in, off by default |
| During an active transfer | Normal | Paused, to avoid competing for the USB link |

Background polling is off by default because it competes with in-flight transfers and the focus trigger already covers the realistic case of "I just took a photo." `adb shell inotifyd` was considered and rejected: `/sdcard` is a FUSE mount on Android 11+ where inotify events are unreliable, so it would work on some devices and mysteriously not on others.

### Persistence

Pinned favourites and each pane's last folder persist across launches, in a small plist under Application Support. Nothing records what was transferred, when, or to where — "no history" governs transfer history, not window state.

---

## 7. Error handling

Every error states what happened and offers an action. Four rules govern the design:

1. **A per-item failure never kills the batch.** Permission denied on one file skips it and reports in a summary at the end, rather than aborting 1,900 successful transfers.
2. **Moves never delete on doubt.** Verification mismatch, cancellation, or disconnect all leave the original intact. Deleting an original requires a passed size check.
3. **No truncated files survive.** A transfer interrupted for any reason deletes its partial destination file.
4. **Device problems are not generic failures.** Each state gets its own screen with the actual fix.

| State | What the user sees |
|---|---|
| `adb` not found | "Conduit needs Android platform-tools", with the `brew` command to copy and a "Locate adb…" chooser |
| `adb` older than 34 | Version shown, upgrade command offered |
| Port 5037 held by a foreign process | Diagnosis naming the process. We adopt an existing `adb` server rather than fighting it, and **never** silently `kill-server` — that would break a user's Android Studio session mid-debug |
| No device | Three-step USB debugging walkthrough, with a disclosure covering charge-only cables and USB hubs |
| USB device present, no adb device | Specifically distinguished: "cable or debugging", not "no phone". This one distinction removes most support traffic |
| `unauthorized` | "Check your phone", showing the RSA fingerprint to compare and calling out "Always allow" |
| `offline` | "Reconnect the cable", with a Restart ADB Server action |
| Multiple devices | Picker; remembers the last-used serial |
| Disconnected mid-transfer | Partial file deleted, queue preserved, resume offered when that serial returns |
| Destination full | Job fails at preflight with the shortfall stated |

On Apple Silicon, macOS 13+ prompts "Allow accessory to connect" for new USB devices. The app detects the un-approved state and explains it, rather than appearing to hang.

---

## 8. Testing

CI runners have no Android device attached, so the test strategy is built around that constraint rather than apologising for it.

**`FakeTransport`** — an in-memory file tree conforming to `DeviceTransport` — makes the entire transfer engine testable with no phone and no adb. It covers: recursive expansion, all four conflict policies, cancellation mid-stream, preflight space failure, per-item failure isolation, and every branch of move verification. The mismatch case has a dedicated test asserting **the original still exists**.

**`FakeADBServer`** — a local socket replaying wire-protocol fixtures recorded once from a real device — tests `ADBKit`'s framing, `OKAY`/`FAIL` handling, `LIS2` parsing, and the legacy-opcode fallback path.

**Edge cases with explicit tests**, since this is where naive implementations break: filenames containing spaces, quotes, newlines and emoji; zero-byte files; deeply nested trees; paths at and beyond 4 GB; symlinks; permission-denied directories.

UI testing stays minimal — XCUITest is slow and flaky, and the logic worth testing lives in the models.

**Manual pre-release checklist** (`docs/RELEASING.md`), against a real device: a 5 GB file both directions, a 2,000-file nested folder both directions, a cable pull mid-transfer, a move whose verification is forced to fail, and a 10,000-entry camera folder listing.

---

## 9. Implementation phases

| Phase | Content | Estimate |
|---|---|---|
| 0 | Repo, license, SPM packages, SwiftLint, CI on `macos-15` | 0.5 day |
| 1 | `ADBKit` complete, headless. Exit criterion: a CLI harness lists `/sdcard`, pulls a file and pushes it back with byte-accurate progress | 2 days |
| 2 | `TransportKit` + `LocalTransport` + `FakeTransport`, with the engine fully unit-tested | 1.5 days |
| 3 | Dual-pane browser UI: panes, sidebars, navigation, breadcrumbs, live Mac pane | 2 days |
| 4 | Transfers wired end to end: action column, drag-and-drop, progress bar, conflicts, move verification | 2.5 days |
| 5 | Onboarding and error states, settings, app icon, keyboard and VoiceOver pass, edge-case hardening | 2 days |
| 6 | Signing, notarization, DMG, Sparkle, Homebrew cask, release workflow, landing page | 2 days |

**≈ 12.5 days.** Phase 1 carries nearly all the technical risk, which is why it comes first, headless and testable, with the CLI fallback already designed.

---

## 10. Repository layout

```
conduit/
├── .github/workflows/{ci.yml,release.yml}
├── Conduit.xcodeproj
├── Sources/
│   ├── Conduit/{ConduitApp.swift,Views/,Models/,DragDrop/,Resources/}
│   ├── ADBKit/
│   ├── TransportKit/
│   ├── ADBTransport/
│   └── LocalTransport/
├── Tests/{ADBKitTests/,TransportKitTests/,Fixtures/}
├── Scripts/{bootstrap.sh,build-release.sh,sign-and-notarize.sh,make-dmg.sh}
├── docs/
│   ├── ARCHITECTURE.md
│   ├── ADB_PROTOCOL.md
│   ├── RELEASING.md
│   ├── mockups/
│   └── superpowers/specs/
├── README.md · CONTRIBUTING.md · CHANGELOG.md · LICENSE (MIT)
```

---

## 11. Open items

These do not block implementation; they block a public release.

1. **Final name.** `Conduit` is provisional and needs a trademark check.
2. **GitHub account and repo visibility.** `gh` is not installed locally (`brew install gh`).
3. **Apple Developer Program membership**, required only at Phase 6 for Developer ID signing and notarization.
4. **Homebrew** is not installed on the development machine and is needed for `adb` itself.
