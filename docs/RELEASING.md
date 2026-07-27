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

Without notarization, macOS blocks the app on double-click. Users have to
right-click → Open once. That is acceptable for an alpha shared with a few
people, and unacceptable for a public release — which is why notarization is
the first thing to fix once a membership exists.

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
