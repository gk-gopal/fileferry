# Releasing FileFerry

## What works today, and what is blocked

| Step | Status |
|---|---|
| Build the app bundle | ✅ `Scripts/make-app.sh` |
| Render the icon | ✅ `Scripts/make-icon.swift`, run automatically by `make-app.sh` |
| Build a DMG | ✅ `Scripts/make-dmg.sh` |
| Ad-hoc signature | ✅ runs on your own machine |
| **Developer ID signature** | ⛔ needs an Apple Developer Program membership ($99/yr) |
| **Notarization** | ⛔ same, plus an App Store Connect API key |
| Homebrew cask | ⛔ needs a public GitHub repo with a tagged release |
| Sparkle auto-update | ⛔ needs a signed, notarized build and somewhere to host the appcast |

## Do we actually need the $99/yr membership?

Not for this audience. Notarization only matters for the **download-a-DMG**
path, and there are two free channels that sidestep Gatekeeper completely:

| Channel | Gatekeeper prompt? | Cost |
|---|---|---|
| `brew install --cask --no-quarantine` from our own tap | none — Homebrew never sets the quarantine flag | free |
| Build from source (`Scripts/make-app.sh`) | none — quarantine comes from *downloading*, not from running | free |
| Download the DMG, unsigned | yes, and it got worse in macOS 15 | free |
| Download the DMG, notarized | none | $99/yr |

Since FileFerry's users already have to install `adb` and enable USB
debugging, they are comfortable with a terminal. A Homebrew tap is the
idiomatic channel for exactly this audience, so the membership buys very
little: a double-click install for people who were never going to get through
the USB-debugging setup anyway.

Worth paying for only if FileFerry is ever aimed at non-technical users, or if
Sparkle auto-updates become important — Sparkle needs a signed, notarized
build.

**Note the Sequoia change.** Before macOS 15, an unsigned app could be opened
with Control-click → Open. Apple removed that. On macOS 15 and later the user
must go to System Settings → Privacy & Security → Open Anyway and enter an
admin password. Any instructions still saying "right-click → Open" are wrong
for current macOS.

## Cutting a local build

```bash
Scripts/make-app.sh release       # -> dist/FileFerry.app
Scripts/make-dmg.sh 0.1.0         # -> dist/FileFerry-0.1.0.dmg
```

## Manual test checklist

The automated suite runs entirely against in-memory fakes, so nothing below
is covered by CI. Run these against a real phone before tagging.

- [ ] Connect a phone with USB debugging off — the walkthrough appears
- [ ] Connect with debugging on but not yet authorised — the "Check your
      phone" screen appears, and clears when you tap Allow
- [ ] Unplug mid-transfer — no truncated file survives, the error names the
      device
- [ ] Copy a folder of 2,000+ files both directions — counts and byte totals
      match on both sides
- [ ] Copy a file over 4 GB — the size is reported correctly, not wrapped
      (5 GiB must not appear as 1.07 GB)
- [ ] Move a file — the original disappears only after the copy verifies
- [ ] Force a verification failure — the original survives
- [ ] Preview a photo on the phone, then a 1 GB video — the video offers a
      button rather than fetching automatically
- [ ] Delete a file — confirmation names it, and it is gone afterwards
- [ ] Drag from the Mac pane into a Finder window — a real file appears
- [ ] Drop onto a folder in the sidebar tree — the file lands there
- [ ] Quit and relaunch — pinned folders and both last folders come back

## Once a Developer ID certificate exists

1. Add to GitHub Actions secrets:
   - `MACOS_CERTIFICATE` — base64 of the exported `.p12`
   - `MACOS_CERTIFICATE_PASSWORD`
   - `APPLE_TEAM_ID`
   - `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `NOTARY_KEY` — App Store Connect API key
2. Uncomment the signing and notarization steps in
   `.github/workflows/release.yml`.
3. Tag and push:
   ```bash
   git tag v0.1.0 && git push --tags
   ```
4. Verify on a machine that has never seen your certificate:
   ```bash
   spctl -a -vvv /Applications/FileFerry.app     # expect: accepted, Notarized Developer ID
   ```

`spctl` on your own build machine is not a valid check — the certificate is
already trusted there. Use a clean VM or another Mac.

## Homebrew cask

`Casks/fileferry.rb` in this repo is the template. Once a release is tagged and
notarized, fill in the version and SHA-256 and open a PR against
`homebrew/homebrew-cask`:

```bash
shasum -a 256 dist/FileFerry-0.1.0.dmg
```
