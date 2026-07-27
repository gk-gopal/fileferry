# Privacy

Short version: FileFerry has no analytics, no telemetry, no crash reporting,
no accounts, and makes no network connections at all beyond talking to `adb`
on your own machine.

You do not have to take that on trust. The source is here, and the checks
below can be run yourself.

## Network

FileFerry opens exactly one kind of connection: TCP to `127.0.0.1:5037`, the
local `adb` server. That address is hardcoded, appears in two places in
`Sources/ADBKit/ADBServer.swift`, and is the only host any connection is ever
opened to.

Check it while the app is running:

```bash
lsof -nP -iTCP -a -p "$(pgrep -x FileFerry)"
```

Everything listed should be `127.0.0.1:…->127.0.0.1:5037`. Nothing leaves your
machine.

There are also **no third-party dependencies** — `Package.swift` declares an
empty `dependencies` array — so there is no vendored SDK that could phone home
without appearing in this repository.

## What is stored on your Mac

Two things, both local, both removable.

**Preferences** — `~/Library/Preferences/app.fileferry.FileFerry.plist`

Pinned folders, the folder each pane was last showing, window size, and your
settings. A complete example:

```
"NSWindow Frame main" = "115 160 1240 680 0 0 1470 923";
macLastPath   = "/Users/you/Documents";
phoneLastPath = "/sdcard/Pictures";
```

**No transfer history is kept.** Nothing records what you copied, when, or
where it went. That was a design decision from the start, not an omission.

**Preview cache** — `~/Library/Caches/app.fileferry.FileFerry/preview`

This one deserves a plain statement: **previewing a file on your phone copies
it to your Mac.** Quick Look needs a real file on disk, so a selected phone
file is fetched into this folder and kept, keyed by path, size and
modification time, so a second look is instant.

Practically, that means photos you clicked on while browsing your phone are
sitting in your Mac's cache. Nothing is uploaded anywhere, but they are on
disk. Settings → General shows the cache size and clears it, or:

```bash
rm -rf ~/Library/Caches/app.fileferry.FileFerry/preview
```

## What FileFerry can see

It reads and writes files you point it at, on both your Mac and your phone.
Over ADB it runs as the `shell` user, which can reach `/sdcard` and external
storage but not app-private data on a non-rooted device.

macOS gates Documents, Desktop, Downloads and removable volumes behind a
consent prompt. FileFerry asks for those the first time you browse into them,
and you can revoke access at any point in System Settings → Privacy &
Security → Files and Folders.

## What is outside FileFerry's control

Being straight about the edges:

- **Downloading a release** contacts GitHub, and GitHub logs that request —
  your IP, the time, the user agent — under
  [their privacy policy](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).
  This has nothing to do with the app, but it is a network request you made to
  get it. Download counts per release are public.
- **`adb` itself** is Google's software, not part of this project. It runs
  locally and FileFerry only talks to it over loopback, but its behaviour is
  Google's to describe, not ours.
- **The installer** clears the quarantine attribute, which means macOS stops
  checking the app with Apple. That is a trade you are making knowingly, and
  it is why the installer prints the SHA-256 of what it installed.

## Reporting

If you find anything in this repository that contradicts the above, please
open an issue. It would be a bug, not a policy.
