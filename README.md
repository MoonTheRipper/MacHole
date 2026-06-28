# MacHole

**Route any app's audio to any output device — on your Mac.**

MacHole is a lightweight macOS menu-bar app that lets you choose which output
device each running application plays through. Send your music player to your
USB audio interface, keep video calls on your headphones, and push a game to
the living-room speakers — all at the same time, from one simple menu.

It’s built entirely on Apple’s native **Core Audio process taps**. There are no
kernel extensions and nothing to install at the system level.

---

## Requirements

- macOS **14.4** or later
- Apple Silicon or Intel

## Install

### Download

1. Go to the [latest release](https://github.com/MoonTheRipper/MacHole/releases/latest).
2. Download `MacHole.zip` and unzip it.
3. Drag **MacHole.app** to your `Applications` folder.
4. The app is ad-hoc signed, so the first time you open it, **right-click the
   app and choose “Open”** (or run `xattr -dr com.apple.quarantine MacHole.app`).

### Build from source

You only need the Swift toolchain (the Xcode Command Line Tools are enough — a
full Xcode install is not required):

```bash
git clone git@github.com:MoonTheRipper/MacHole.git
cd MacHole
./scripts/build-app.sh
open dist/MacHole.app
```

## How to use

1. Launch MacHole. A small **waveform icon** appears in your menu bar.
2. Click it to open the dropdown. You’ll see the apps currently using audio.
3. For any app, pick an output device from the menu next to it.
4. That app’s sound now plays through the device you chose. Pick **System
   Default** again to hand it back.

The first time MacHole redirects an app, macOS may ask for permission to
capture that app’s audio — this is required to move the sound to another
device. Click **Allow**.

Your choices are remembered and automatically re-applied when the apps relaunch.

## Settings

Open **Settings…** from the dropdown for advanced options:

- **Launch at login** — start MacHole automatically.
- **Only show apps that are currently playing** — keep the list short.
- **Automatically re-apply routes** — restore your routing when apps relaunch.
- **Active routes** — see and clear everything you’ve routed.

## How it works

When you route an app to a device, MacHole:

1. Creates a **process tap** on that app to capture its audio.
2. Builds a **private aggregate device** wrapping your chosen output.
3. Streams the captured audio to that device, while muting the app on its
   original output.

All of this uses public Core Audio APIs introduced in macOS 14.4. Nothing is
installed outside the app, and removing the app removes everything it created.

## Privacy

MacHole runs entirely on your Mac. It does not collect, transmit, or store any
audio, usage data, or personal information. It captures app audio **only** for
the apps you explicitly route, and only to play them through the device you pick.

## Troubleshooting

- **An app doesn’t appear in the list** — it has to be actively using audio.
  Start playback, then click the refresh icon.
- **No sound after routing** — make sure the target device is connected and not
  muted, then try selecting **System Default** and the device again.
- **“MacHole can’t be opened”** — right-click the app and choose **Open**, or run
  `xattr -dr com.apple.quarantine MacHole.app`.

## License

Released under the [MIT License](LICENSE).
