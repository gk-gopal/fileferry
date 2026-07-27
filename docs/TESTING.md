# FileFerry — notes for testers

Thanks for trying this. It's an early build: the file transfer layer is
verified against real hardware, but the app around it has only ever been run
on one Mac and one phone. Rough edges are expected — that's the point.

## What you need

- **macOS 14 (Sonoma) or later.** Works on both Apple Silicon and Intel.
- **An Android phone** and a cable that carries **data**. Many charging cables
  do not, and this is the single most common reason nothing shows up.
- **adb**: `brew install --cask android-platform-tools`

## Setting up the phone (once)

1. Settings → About phone → tap **Build number** seven times
2. Settings → System → Developer options → turn on **USB debugging**
3. Plug the phone into the Mac
4. Tap **Allow** on the phone, ticking "Always allow from this computer"

If FileFerry says the device is *unauthorized*, step 4 hasn't happened yet —
unlock the phone and look for the prompt.

## Getting the app

You'll get a GitHub invite by email, or at
[github.com/notifications](https://github.com/notifications). Accept it first —
until you do, every link below 404s.

### Option A — download the built app (about two minutes)

1. Go to <https://github.com/gk-gopal/fileferry/releases>
2. Download the newest `FileFerry-x.y.z.dmg`
3. Open it and drag FileFerry to Applications
4. Follow **Installing** below to get past Gatekeeper once

### Option B — build it yourself (no Gatekeeper prompt at all)

Needs Xcode installed (a large download; skip this if you don't have it).
Quarantine is applied to things you *download*, so an app you build locally is
never blocked:

```bash
git clone https://github.com/gk-gopal/fileferry
cd fileferry
Scripts/make-app.sh release      # -> dist/FileFerry.app
open dist/FileFerry.app
```

You can also run the test suite, which needs neither a phone nor adb:

```bash
swift test        # 72 tests
```

### Not yet: Homebrew

`brew tap gk-gopal/tap` exists but **won't work while the repo is private** —
Homebrew's downloader has no GitHub credentials, so fetching the release
asset fails. Use Option A or B for now.

## Installing

FileFerry isn't notarized by Apple (that costs $99/yr), so macOS blocks it the
first time. This is expected, not a warning about the app itself.

**macOS 15 (Sequoia) and later:**

1. Drag FileFerry to Applications and try to open it. macOS refuses.
2. System Settings → Privacy & Security
3. Scroll down to "FileFerry was blocked" → **Open Anyway** → password

**macOS 14 (Sonoma):** right-click FileFerry → Open → confirm.

Only once. After that it opens normally.

## What would be most useful to hear about

Roughly in order of how much it would help:

1. **Anything that lost data.** A move that deleted the original when the copy
   didn't arrive is the worst possible bug and the one I most want to know
   about. Moves are supposed to verify the destination before deleting.
2. **Anything that hung** rather than showing an error.
3. **Wrong file sizes**, especially on files over 4 GB.
4. **The first two minutes.** Did you get from opening the app to moving a
   file without asking me anything? Where did you stall?
5. **Speed.** Roughly how fast was a big transfer? A folder of many small
   files? (There's a progress bar showing MB/s.)
6. Anything that looked broken, cramped, or ugly at your window size.

## Known and already on the list

- Dragging *from* the phone pane into a Finder window doesn't work. Phone →
  Mac pane does. (Finder needs file promises; not built yet.)
- Folders outside `/sdcard` may show as empty rather than "not allowed" —
  Android reports them identically over adb.
- No auto-update. You'll get new builds from me by hand.
- Previews of phone files over 50 MB need a button press, because previewing
  has to fetch the file over USB first.

## Things I'd rather you didn't do yet

- Don't use it as your only copy of anything. It's an early build.
- Deleting is real and immediate — there's no trash on a phone.

## Reporting

Just message me. Include your macOS version, your phone model, and what you
were doing. If the app crashed, there'll be a report in Console → Crash
Reports named FileFerry.
