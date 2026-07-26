# Conduit — Build Plan

A native macOS app for transferring files between a Mac and an Android device over USB, using ADB as the transport.

> **Name is a placeholder.** `Conduit` is used throughout for the app name, `conduit` for the repo, and `dev.gopalkannan.conduit` for the bundle identifier. All three are a find-and-replace away from anything else. Check the name against the [USPTO TESS](https://tmsearch.uspto.gov) database before shipping paid.

---

## 1. Decisions already made

| Decision | Choice | Why |
|---|---|---|
| Transport | ADB over USB | 3–10× faster than MTP, especially on many-small-files; macOS has no native MTP stack, so MTP means vendoring libmtp + a C bridge + permanent vendor quirks |
| Mac UI | Swift 6 + SwiftUI, macOS 14+ | Native Finder drag-and-drop, small signed binary, Xcode 26.6 already installed |
| Primary distribution | Developer ID signed + notarized `.dmg` on GitHub Releases, plus a Homebrew cask | See §2 — the App Store cannot host an ADB-based app |
| Android-side app | None | ADB requires no companion app. This is the single biggest scope saving |

### macOS 14 as the floor

macOS 14 (Sonoma) gives us `Table` column customization, `NavigationSplitView` maturity, `Observable` macro, and `ImportFromDevicesPicker`-era file APIs without back-deployment shims. It covers roughly 90% of active Macs. Dropping to macOS 13 costs several SwiftUI workarounds for very little reach.

---

## 2. The App Store problem, and the answer

**The constraint.** Mac App Store submissions must enable App Sandbox. An ADB-based app needs three things that fight the sandbox:

1. **Raw USB device access.** The `com.apple.security.device.usb` entitlement exists, so this alone is survivable.
2. **A long-lived daemon.** `adb` works by starting a server process that owns the USB connection and listens on TCP `127.0.0.1:5037`. It outlives the app, and it conflicts with any `adb` the user already has from Homebrew or Android Studio. A persistent out-of-bundle daemon is a reliable review rejection.
3. **Redistributing `adb` itself.** Google's prebuilt `platform-tools` is covered by the Android SDK Terms of Service, which prohibit redistribution. The `adb` *source* in AOSP is Apache 2.0, so building it ourselves is the clean path — but that's a build-system project of its own (AOSP uses Soong/`Android.bp`).

**The evidence.** No ADB-based Android file transfer app exists on the Mac App Store. MacDroid, AnyDroid, and Google's own (now discontinued) Android File Transfer all ship as direct downloads.

**The plan.** Ship direct-download as the real product. Structure the code so an App Store SKU is a later addition:

- All device I/O goes through a `DeviceTransport` protocol (§4.2).
- `ADBTransport` is the Phase 1–5 implementation. Not sandbox-compatible, ships direct.
- `WiFiTransport` is Phase 6: Mac runs an embedded HTTP server advertised over Bonjour, phone connects from Chrome or a small companion app. Fully sandbox-compatible (`network.server` + `network.client` entitlements only).
- The App Store build is then a second scheme that compiles in `WiFiTransport` only, with `ADBTransport` excluded by a compilation condition.

This is why the protocol abstraction goes in on day one even though there's only one implementation. Retrofitting it after the UI is wired directly to adb is the expensive version.

---

## 3. Architecture

### 3.1 The key technical call: wire protocol, not CLI parsing

There are two ways to drive adb, and this choice determines how good the app can be.

**Option A — shell out to the CLI.** `Process` + `adb push`, `adb pull`, `adb devices`, parse stdout. Fast to write. But you are screen-scraping human-readable output that changes between platform-tools versions, progress comes as coarse percentage strings, and there is no clean way to stream device connect/disconnect events.

**Option B — speak the adb protocol to port 5037.** Let the bundled `adb` binary run purely as the *server* (it owns the USB stack, which is the part we genuinely don't want to reimplement), then open our own TCP socket to `127.0.0.1:5037` and speak the host protocol directly.

**Go with B.** This is what Android Studio does, and it unlocks the features that separate a good file transfer app from a bad one:

| Service | What it gives us |
|---|---|
| `host:track-devices` | A *persistent stream* of device state changes. Devices appear and disappear in the sidebar instantly, with zero polling |
| `host-serial:<s>:features` | Feature negotiation, so we know whether the device supports the v2 sync services |
| `sync:` → `LIS2` | Directory listing with 64-bit sizes and proper mtimes |
| `sync:` → `STA2` | Stat a single path, 64-bit |
| `sync:` → `RECV` | Pull, streamed as 64 KB chunks — **byte-accurate progress**, real MB/s, real ETA |
| `sync:` → `SEND` | Push, same |
| `shell,v2:` | Structured shell with separated stdout/stderr and a real exit code, for `df`, `getprop`, `mkdir`, `rm` |

The protocol is a length-prefixed request (`%04x` hex length + payload) answered by `OKAY` or `FAIL`. It is small — a few hundred lines of Swift — and it is stable, because Android Studio depends on it.

> **Use `LIS2`/`STA2`, not the legacy `LIST`/`STAT`.** The original sync protocol encodes file size as a 32-bit integer, which silently breaks on files ≥ 4 GB — exactly the 4K video case users will test first. Gate on the `ls_v2`/`stat_v2` feature flags and only fall back to the legacy opcodes on ancient devices.

### 3.2 Module layout

Three Swift packages plus a thin app target. The packages are testable without a UI and without a phone.

```
ADBKit          — no UI, no SwiftUI import
  ADBBinary        locate / validate / version-check the adb executable
  ADBServer        server lifecycle: start-server, health check, graceful adopt of
                   an already-running server, port conflict handling
  ADBConnection    the socket + framing layer (%04x length prefix, OKAY/FAIL)
  DeviceTracker    host:track-devices → AsyncStream<[ADBDevice]>
  SyncSession      sync: service — LIS2 / STA2 / RECV / SEND
  ShellSession     shell,v2: with exit codes
  ADBError         typed errors mapped to user-facing recovery text

TransportKit    — the abstraction that keeps the App Store door open
  DeviceTransport      protocol: list / stat / read / write / mkdir / delete / move
  TransferEngine       queue, concurrency limits, progress, cancellation, retry
  TransferItem         one file's state machine
  ConflictPolicy       skip / overwrite / rename / ask

ADBTransport    — DeviceTransport conformance backed by ADBKit

Conduit         — the SwiftUI app target
```

`TransferEngine` lives in `TransportKit`, not `ADBKit`, because queueing and progress semantics are transport-independent — the Wi-Fi transport gets them for free.

### 3.3 Concurrency model

Swift 6 strict concurrency, complete checking on from the first commit. Retrofitting `Sendable` onto a codebase later is miserable.

- `ADBServer` is an `actor` — it serializes binary launching and health checks.
- Each `SyncSession` owns its own TCP socket. **One socket per transfer**, which is what makes parallelism safe: two concurrent pushes are two independent sockets, not two writers racing on one.
- `TransferEngine` is an `actor` with a bounded `TaskGroup`. Cap concurrent transfers at **2**. USB is the bottleneck; more streams than that reduces throughput through contention while making progress reporting confusing.
- UI state objects are `@MainActor @Observable`.
- Progress flows out as an `AsyncStream` of byte counts, coalesced to ~10 Hz before touching the UI. Publishing every 64 KB chunk will pin the main thread on a fast transfer.

---

## 4. UI design

### 4.1 Shape

One window. `NavigationSplitView`, two columns.

```
┌────────────────────┬──────────────────────────────────────────────┐
│ DEVICES            │  ← →  ⌂  /sdcard/DCIM/Camera        ⇱ ⇲  ⚙  │
│  ▸ Pixel 8         ├──────────────────────────────────────────────┤
│      41 GB free    │  Name              Size      Modified        │
│                    │  ▸ 📁 .thumbnails            12 Mar 2026     │
│ FAVOURITES         │    🖼 IMG_2027.jpg  4.2 MB    18 Jul 2026     │
│  ⬇ Downloads       │    🎬 VID_2031.mp4  1.8 GB    21 Jul 2026     │
│  📷 Camera          │    🖼 IMG_2033.jpg  3.9 MB    24 Jul 2026     │
│  🎵 Music           │                                              │
│  🎬 Movies          │                                              │
│                    ├──────────────────────────────────────────────┤
│                    │ ▓▓▓▓▓▓▓▓░░░ VID_2031.mp4  62% · 78 MB/s · 4s │
└────────────────────┴──────────────────────────────────────────────┘
```

**Single pane showing the phone — not dual-pane.** A left pane duplicating Finder is wasted pixels; the Mac side of the transfer is Finder itself. Files move by dragging between Conduit and a Finder window, in both directions.

But drag-and-drop is undiscoverable on its own, so every drag gesture has a visible equivalent:

- Toolbar `⇱ Upload…` opens an `NSOpenPanel`, uploads to the current directory.
- Toolbar `⇲ Download…` saves the selection to the default folder (or prompts, per Settings).
- Context menu on any row: Download, Rename, Delete, Copy Path.
- `⌘↓` download, `⌘↑` upload, `⌫` delete, `⏎` rename, `Space` Quick Look.

### 4.2 Drag-and-drop, precisely

- **Finder → Conduit (upload):** the file browser is a drop target for `.fileURL`. The drop highlights either the current directory or a specific folder row when hovered over one.
- **Conduit → Finder (download):** rows export via `NSFilePromiseProvider`. This is the correct API and it matters — a file promise means the download only starts once the user actually drops, and macOS hands us the real destination directory. The naive alternative (pull to a temp dir on drag start, then hand over a URL) downloads gigabytes for a drag the user cancels.

### 4.3 Onboarding is the make-or-break screen

ADB's cost is one-time device setup. If that's confusing, nothing else matters. Every device state gets its own dedicated, actionable view — never a generic "no device found."

| State | What the user sees |
|---|---|
| No adb binary | "Conduit needs Android platform-tools." One button to install, or point at an existing binary |
| No device | Illustrated 3-step walkthrough: tap Build number 7× → enable USB debugging → connect cable. With a "still not working?" disclosure covering charge-only cables and USB hubs |
| `unauthorized` | "Check your phone." Shows an image of the RSA fingerprint dialog and the actual fingerprint to compare, with the "Always allow" checkbox called out |
| `offline` | "Reconnect the cable." Offers Restart ADB Server |
| Multiple devices | Picker; remembers the last-used serial |
| `device` (ready) | The browser |

Detect the charge-only-cable case explicitly: USB device present in IOKit but no adb device means cable or debugging, not a missing phone. That single distinction eliminates most support email.

### 4.4 Details that make it feel native

- Real file icons via `NSWorkspace.icon(forFileType:)` keyed off extension.
- Quick Look on `Space`: pull to a temp file, preview, clean up on close. Cache by `(path, size, mtime)`.
- `.fileSize` byte formatting via `ByteCountFormatter` (decimal, matching Finder).
- Sortable, reorderable, hideable `Table` columns, persisted.
- Free/total storage in the sidebar from `shell,v2: df /sdcard`.
- Full keyboard navigation; VoiceOver labels on every row and progress element.
- Dark mode from using semantic colors only — no hardcoded hex.
- Menu bar: File / Edit / View / Device (Restart ADB Server, Reconnect) / Window / Help.

---

## 5. Phases

Estimates assume focused work and are ordered so something runnable exists early.

### Phase 0 — Repo and CI skeleton · ~0.5 day
- `git init`, MIT license, `.gitignore` (Swift + macOS + Xcode).
- SPM packages for `ADBKit` / `TransportKit` / `ADBTransport`; `.xcodeproj` for the app.
- `.swiftlint.yml`, `.swift-format`.
- `ci.yml`: build + test on `macos-15`, on push and PR.
- README with the honest state of things ("alpha, not signed yet").

**Exit:** `swift test` green in CI on an empty test suite.

### Phase 1 — ADBKit · ~2 days
The whole protocol layer, headless and fully testable.
- `ADBBinary`: resolve from bundle → Homebrew → `ANDROID_HOME` → user-selected path. Version check with a minimum of platform-tools 34.
- `ADBServer`: start, adopt-if-running, health check, port-conflict diagnosis.
- `ADBConnection`: `%04x` framing, `OKAY`/`FAIL`, timeouts, cancellation.
- `DeviceTracker`: `host:track-devices` → `AsyncStream<[ADBDevice]>`, with reconnect-on-server-death.
- `SyncSession`: `LIS2`, `STA2`, `RECV`, `SEND`, with legacy fallback behind feature flags.
- `ShellSession`: `shell,v2:` with exit codes.

**Exit:** a CLI test harness lists `/sdcard`, pulls a file, and pushes it back with byte-accurate progress. No UI yet.

> This phase carries the real risk. Everything after it is comparatively predictable. If the wire protocol fights back, the escape hatch is CLI shelling behind the same `DeviceTransport` protocol — degraded progress reporting, same UI, unblocked.

### Phase 2 — Browser UI · ~2 days
- `NavigationSplitView`, device sidebar with live state from `DeviceTracker`.
- `FileBrowserView`: `Table`, sortable columns, icons, breadcrumb path bar, back/forward/up, favorites.
- Directory listing cache with pull-to-refresh and invalidation on write.

**Exit:** browse the entire device filesystem fluidly, including 10k-file directories.

### Phase 3 — Transfers · ~3 days
- `TransferEngine`: queue, 2-way concurrency, progress, cancel, retry, conflict policy.
- Upload via `NSOpenPanel` and via Finder drop.
- Download via toolbar and via `NSFilePromiseProvider`.
- Transfers panel: per-file progress, aggregate progress, MB/s, ETA, cancel, retry, reveal in Finder.
- Nested directory transfers with correct recursive `mkdir`.
- Rename, delete (with confirmation), new folder.

**Exit:** a 2,000-file nested folder round-trips in both directions with accurate progress, survives a mid-transfer cable pull with a clear error, and resumes cleanly on reconnect.

### Phase 4 — Polish · ~2 days
- All six onboarding/error states from §4.3.
- Settings: adb path, default download folder, conflict policy, concurrency, launch-at-login.
- App icon and a minimal brand pass.
- Quick Look, full keyboard support, VoiceOver audit.
- Localizable strings extracted (English only at v1, but not hardcoded).
- Crash-free pass over the awkward cases: emoji and spaces in filenames, symlinks, permission-denied paths, 0-byte files, files > 4 GB.

**Exit:** a person who has never enabled USB debugging can install, connect, and transfer without asking a question.

### Phase 5 — Ship it · ~2 days
- Developer ID Application signing, hardened runtime. The bundled `adb` must be signed with the same team ID, hardened, and secure-timestamped, or notarization rejects it.
- Notarize with `notarytool`, staple the ticket.
- `.dmg` via `create-dmg`.
- Sparkle 2 auto-update with an EdDSA-signed appcast served from GitHub Pages.
- `release.yml`: on tag `v*` → build, sign, notarize, DMG, GitHub Release, appcast update. Certificates and the App Store Connect API key live in GitHub Actions secrets and are imported into a temporary keychain.
- Homebrew cask PR to `homebrew-cask`.
- Landing page on GitHub Pages.

**Exit:** `git tag v1.0.0 && git push --tags` produces a downloadable, notarized DMG that opens on a Mac that has never seen the developer certificate. Verify with `spctl -a -vvv Conduit.app` on a clean machine or VM.

### Phase 6 — Wi-Fi transport and the App Store SKU · conditional, ~5+ days
Only if you want the App Store listing.
- `WiFiTransport`: embedded HTTP server, Bonjour advertisement, pairing code, TLS.
- Responsive web UI served to the phone's browser for both directions.
- Sandboxed App Store target: `WiFiTransport` only, `ADBTransport` excluded by compilation condition.
- App Store Connect metadata, screenshots, privacy nutrition label (Conduit collects nothing — that section is short).

---

## 6. Repository layout

```
conduit/
├── .github/
│   └── workflows/
│       ├── ci.yml                  build + test on PR
│       └── release.yml             tag → sign → notarize → DMG → Release
├── Conduit.xcodeproj
├── Sources/
│   ├── Conduit/                    app target
│   │   ├── ConduitApp.swift
│   │   ├── Views/
│   │   │   ├── DeviceSidebarView.swift
│   │   │   ├── FileBrowserView.swift
│   │   │   ├── TransfersView.swift
│   │   │   ├── Onboarding/
│   │   │   └── SettingsView.swift
│   │   ├── ViewModels/
│   │   ├── DragDrop/               NSFilePromiseProvider glue
│   │   └── Resources/
│   │       ├── Assets.xcassets
│   │       └── adb                 vendored binary — see §7
│   ├── ADBKit/
│   ├── TransportKit/
│   └── ADBTransport/
├── Tests/
│   ├── ADBKitTests/                protocol framing, parsing, against a fake server
│   ├── TransportKitTests/          queue, conflict policy, cancellation
│   └── ConduitUITests/
├── Scripts/
│   ├── bootstrap.sh                dev setup
│   ├── build-release.sh
│   ├── sign-and-notarize.sh
│   └── make-dmg.sh
├── docs/
│   ├── ARCHITECTURE.md
│   ├── ADB_PROTOCOL.md             our notes on the wire format
│   └── RELEASING.md
├── PLAN.md                         this file
├── README.md
├── CONTRIBUTING.md
├── CHANGELOG.md
└── LICENSE                         MIT
```

### Testing without a phone

`ADBKitTests` runs against a **fake adb server** — a local socket that speaks the protocol from recorded fixtures. This is what makes CI possible at all, since GitHub's runners have no Android device attached. Record fixtures once from a real device, replay forever. Real-device testing stays a manual pre-release checklist in `docs/RELEASING.md`.

---

## 7. Risks, and what we do about them

| Risk | Severity | Mitigation |
|---|---|---|
| Can't redistribute Google's prebuilt `adb` | **High** — legal | v1: don't bundle. Detect Homebrew's copy, and offer one-click `brew install --cask android-platform-tools`. Later: build `adb` from AOSP (Apache 2.0) in CI and bundle that |
| App Store rejection | **High** | Already absorbed: direct download is the shipping channel (§2). Not a surprise, a plan |
| Port 5037 conflict with the user's own adb | Medium | Adopt an existing server rather than fighting it. Version-check it; only offer to restart if it's too old. **Never** silently `kill-server` — that breaks the user's Android Studio session mid-debug |
| Files ≥ 4 GB | Medium | `LIS2`/`STA2` with 64-bit sizes; explicitly test a 5 GB file in Phase 4 |
| macOS accessory consent | Medium | On Apple Silicon, macOS 13+ prompts "Allow accessory to connect." Detect the pre-approval state and surface it in onboarding rather than appearing hung |
| Wire protocol undocumented | Medium | It's stable in practice (Android Studio depends on it) and `SERVICES.TXT` in AOSP describes it. Escape hatch is CLI shelling behind the same protocol |
| Sparkle + notarization interaction | Low | Sparkle's XPC services need signing individually. Known, documented, just fiddly |
| Scoped storage blocking paths | Low | `adb shell` runs as the `shell` user, which reads `/sdcard` fully. `/data/data` stays inaccessible on non-rooted devices — out of scope, and we should say so in the README rather than fail confusingly |

---

## 8. What I need from you

Two are blocking, the rest can wait.

**Blocking:**
1. **Accept the Xcode license** — `sudo xcodebuild -license`. Right now this blocks not just builds but `git` itself, since macOS routes `git` through the Xcode shim. Run it in this session with:
   `! sudo xcodebuild -license`
2. **Apple Developer Program membership** ($99/yr) — required for the Developer ID certificate that makes the app installable by anyone else. Needed by Phase 5, not before. Everything through Phase 4 works fine with a local unsigned build.

**Not blocking:**
3. Final app name and bundle ID prefix (I'll use `dev.gopalkannan.conduit` until told otherwise).
4. GitHub account/org for the repo, and public vs private. `gh` isn't installed — `brew install gh`.
5. License preference. MIT assumed.
6. Free, paid, or freemium — this only changes Phase 5 and the App Store math in Phase 6.

---

## 9. Suggested first move

Phases 0 and 1 together. That's the repo scaffold plus the entire ADB protocol layer, ending at a CLI harness that lists a directory on your phone and round-trips a file with real progress.

It front-loads all the technical risk. If the wire protocol turns out to be a fight, we learn that in day two with no UI thrown away — and the fallback is already designed. And it's genuinely satisfying to watch a 2 GB video move at 90 MB/s from a terminal before any pixels exist.
