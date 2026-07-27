# Changelog

All notable changes to FileFerry. Dates are ISO 8601.

## 0.2.1 — 2026-07-27

### Added

- **Rename**, from the pencil button in the pane header or the context menu.
  Both transports refuse to overwrite an existing name rather than relying on
  the underlying tool to fail — verified on hardware that Android's `mv`
  silently destroys the file it lands on, with no error, so without the check
  a rename could quietly delete an unrelated file.
- **The phone's real name** instead of its adb serial. Android has no single
  property for this — `ro.product.model` returns a part number on many phones
  — so vendor marketing names are tried first. A OnePlus 12R reported
  `CPH2585`; it now shows "OnePlus 12R".
- **Elapsed time and average rate** in the completion bar. The rate is shown
  only above 1 MB, since quoting KB/s for a small file is measurement noise.

### Fixed

- The macOS consent prompt for Documents, Desktop, Downloads and removable
  volumes gave no reason at all. Those folders are gated by TCC for every app,
  and the prompt now explains why FileFerry is asking — which matters when a
  user is already being asked to trust an unnotarized app.

## 0.2.0 — 2026-07-27

### Added

- **External drives and SD cards are reachable.** Both sidebars now list
  mounted volumes — external drives and card readers on the Mac under
  *Locations*, SD cards and USB-OTG storage on the phone under *Storage*.
  Each is a drop target, so files can go straight from a USB stick to a phone
  without being staged on the Mac's internal disk first. Mac volumes appear
  and disappear as they are mounted, without a relaunch.
- **One-command installer** (`Scripts/install.sh`). Downloads the latest
  release, installs to `/Applications`, and clears the quarantine attribute so
  macOS does not block the first launch. Works offline when run from inside a
  mounted DMG or an unpacked zip.
- **A `.zip` artifact alongside the `.dmg`**, for networks that block GitHub
  downloads or mail filters that reject disk images. Built with `ditto` to
  preserve the bundle's symlinks and code signature.
- `fileferry-cli volumes` reports external storage on both sides.
- Tester documentation (`docs/TESTING.md`).

### Fixed

- **Universal binary.** Builds were arm64-only and would not launch at all on
  an Intel Mac.
- The Swift 6 language mode is declared package-wide; the per-target form
  broke the multi-architecture build on CI while working locally.
- The installer printed an unbound-variable error when piped into `bash`.
- Release checksums now cover the zip as well as the disk image.

### Changed

- Install instructions corrected throughout. macOS 15 removed the
  Control-click → Open bypass, so an unnotarized app must now be allowed from
  System Settings → Privacy & Security. Homebrew has removed `--no-quarantine`
  with no replacement and requires `brew trust` for third-party taps, so the
  `curl` installer is now the recommended route rather than Homebrew.

## 0.1.1 — 2026-07-27

- First build shared for testing. Universal binary.

## 0.1.0 — 2026-07-27

- First tagged build. ADB wire-protocol layer verified against real hardware:
  a 5 GiB file round-tripped byte-identical, and 5,429 files (3.17 GB) copied
  at 37 MB/s with counts and byte totals matching the device exactly.
- Dual-pane app, transfer engine with verified moves, folder tree, preview,
  drag and drop, sorting.

[0.2.1]: https://github.com/gk-gopal/fileferry/releases/tag/v0.2.1
[0.2.0]: https://github.com/gk-gopal/fileferry/releases/tag/v0.2.0
[0.1.1]: https://github.com/gk-gopal/fileferry/releases/tag/v0.1.1
[0.1.0]: https://github.com/gk-gopal/fileferry/releases/tag/v0.1.0
