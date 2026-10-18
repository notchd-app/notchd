<p align="center">
  <img src="assets/logo.png" width="160" alt="notchd icon">
</p>

<h1 align="center">notchd</h1>

<p align="center">
  <b>Your MacBook notch, but alive.</b><br>
  A clean, open-source, Dynamic Island–style notch for macOS: music with synced lyrics, calendar, timers, a file tray, clipboard history, weather and live activities, all with springy Apple-like animations.
</p>

<p align="center">
  <a href="https://github.com/notchd-app/notchd/actions/workflows/build.yml"><img src="https://github.com/notchd-app/notchd/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/license-Apache%202.0-blue" alt="Apache 2.0">
  <img src="https://img.shields.io/badge/price-free-brightgreen" alt="Free">
</p>

<p align="center">
  <img src="assets/screenshots/nook.png" alt="The open notch with music, calendar, to-do and timer widgets">
</p>

---

## Why

The notch is dead space. notchd turns it into a small, living surface: it grows when something happens (a song plays, a meeting is about to start, your AirPods connect) and opens into a panel of widgets when you click it.

No account, no subscription, no telemetry. Everything stays on your Mac, and the code is right here.

## Features

### Live activities
The closed notch widens to show what's going on, then tucks itself away.

<p align="center">
  <img src="assets/screenshots/live-activity.png" width="420" alt="Media live activity with a Glance line">
</p>

| Activity | What it shows |
|---|---|
| 🎵 **Media** | Cover art and an animation (equalizer, wave, pulse or your own GIF), tinted with the cover's color. Works with Spotify, Apple Music, browsers and any app that reports Now Playing. |
| 📅 **Calendar** | Countdown to your next event; a green button joins Google Meet, Zoom, Teams or Webex calls in one click. |
| 🎧 **Bluetooth** | Device connected / disconnected, with battery level for AirPods. |
| 🔋 **Battery** | Charger connected or disconnected, fully charged, running low. |
| ⏱️ **Timer Done** | A ringing timer with a Stop button. |
| ⬇️ **New Update** | A new release is out: one click downloads it, swaps the app and relaunches. |
| 🗂️ **Tray** | How many files are waiting in your tray. |
| 🌙 **Focus** | Turning a Focus on or off flashes its own icon and color, like on iPhone (needs Full Disk Access, see below). |
| 🎥 **Camera & Mic** | A green or orange dot while any app uses your camera or microphone. |
| 🧠 **Focus Timer** | The Pomodoro phase and time left; a play button when the next phase is ready. |
| ✨ **Coding Agents** | Claude Code or Codex is working, needs your input, or has finished. Click to jump back to the terminal. |
| ⬇️ **Downloads** | A download just finished: show it in Finder or drop it in the tray (off until you turn it on). |
| ☕ **Keep Awake** | Your Mac is being kept awake, with the time left. Click to stop. |

- **Glance**: point at an activity and a line of details slides out below it (song title or the lyric being sung, event time, battery estimate…).
- **Your priorities**: drag activities to choose which one wins when several are active.
- **Swipe up** to tuck an activity away. It comes back on its own when there's news.
- **Fullscreen aware**: pick which activities may appear over fullscreen apps.

### Widgets
Click the notch (or swipe down) to open it.

- **Media player**: artwork, controls, draggable progress bar, **synced lyrics** (from the free LRCLIB database) and a **sound output switcher** with a volume slider.
- **Calendar**: today's events.
- **To-do list**: its own tasks, or **synced with an Apple Reminders list** so they follow you to your iPhone.
- **Timers**: scroll wheels with haptic ticks, several timers at once, saved across restarts.
- **Focus Timer**: Pomodoro cycles of focus and breaks, with a long break every few rounds and a count of today's sessions.
- **Notes**: rich text or code notes with syntax colors.
- **Shortcuts**: run your Shortcuts in one click.
- **Mirror**: a quick look at yourself before a call.
- **System**: CPU, graphics, memory, disk and network at a glance, with live graphs when it's wide enough.
- **Weather**: now and the next hours, from Open-Meteo (no account, only the place's coordinates are sent).
- **Color Picker**: an eyedropper for any pixel on any screen, copied as HEX, RGB, HSL, SwiftUI or NSColor, with a history of swatches.
- **Capture**: take a screenshot of an area or window, or record your screen. Finished PNG images and MOV videos go straight into the tray, which opens with the new file selected.

The open notch defaults to **Compact**, with tighter widget spacing and less empty height. Choose **Roomy** in Settings → Widgets for the larger layout. Widgets are sized in units (1U = 90 pt in Compact, 100 pt in Roomy). The notch grows to fit what you enabled and never takes more than 75% of the screen.

In **Settings → Widgets → Layout**, drag modules from the library into the notch preview or directly onto the notch at the top of your screen. Drag placed modules to reorder them, click × to remove one, and select a module to change its width. Removing and re-adding a module keeps its chosen width. Modules that exceed the screen’s capacity are marked **No room**.

**Screenshot** opens the macOS area selector; press Space to select a window or Escape to cancel. **Record screen** opens the recording controls; choose the area, click Record, then use Stop in the menu bar. The notch hides during capture. If macOS requests Screen Recording access, allow it in System Settings. Captures use your chosen tray folder; if the tray is unavailable, the original stays in Application Support/Notchd/Captures and an alert lets you reveal it in Finder.

### Tray & drop zone
Drag anything to the top of the screen and the notch opens into two drop zones: **Tray** and **AirDrop**. Drag back away and it folds up again.

- **Tray**: keeps files at hand. Drag them back out to copy, or ⌥-drag to move. Paste with ⌘V (text, images and links become files).
- **AirDrop**: drop files, links or text and the AirDrop window opens straight away to pick a nearby device.
- Finder-style shortcuts: multi-select, Space for Quick Look, ⌘C, Delete, Return to rename.
- **Clear All**: the trash button in the tray's corner (click twice to confirm) or ⇧⌘⌫ empties the tray.
- **Right-click a file for more**: compress to zip or expand one, convert images to PNG, JPEG or HEIC, make them smaller for mail, remove the background, combine images or PDFs into one PDF, or copy the text in an image. Results land in the tray; originals are never changed.
- Choose where tray files live, copy or move on drop, auto-clear old files. Removed files go to the Trash, never straight to oblivion.

### Clipboard history
Everything you copy appears in the notch's **Clipboard** tab: text, links, images and files, newest first. **⇧⌘V** opens it from anywhere; use ← → and Return to paste it back into the app you were in.

- Search finds words inside copied screenshots too (Live Text).
- Pin what you reuse; pinned items survive clearing.
- Drag a card out, open links, add items to the tray.
- Passwords stay out: anything an app marks as secret is skipped, and so are password managers (add your own apps to the list).
- Everything stays on your Mac, in Application Support.

### More in the notch
- **Volume, brightness and keyboard backlight** show in the notch instead of the macOS overlay (Settings → General).
- **Keep awake**: the cup in the open notch keeps your Mac (and its display) from sleeping, for a while or until you stop it.
- **Coding agents**: Settings → Live Activities → Coding Agents connects Claude Code and Codex with one click. It adds a tiny hook to their config (with a backup) that drops event files into Notchd's folder; nothing leaves your Mac.

### Make it yours

<p align="center">
  <img src="assets/screenshots/settings.png" width="560" alt="Settings: live activity priorities with a live preview">
</p>

- Pill-shaped or rounded-square buttons, frosted glass background (experimental), inner spacing.
- Trackpad gestures: swipe down/up to open/close, sideways to skip tracks (direction reversible).
- Handle size for screens without a notch, or hide it until hovered.
- Notch size adjustment, haptics on/off, launch at login, presentation mode for recordings.

<p align="center">
  <img src="assets/screenshots/welcome.png" width="320" alt="Welcome tour">
</p>

## Install

### Download
Grab the latest `Notchd-x.y.z.zip` from [Releases](https://github.com/notchd-app/notchd/releases), or a build of the latest commit from [Actions](https://github.com/notchd-app/notchd/actions/workflows/build.yml) (open a run, then *Artifacts*). It's a universal app: Apple Silicon and Intel, macOS 14 or later.

After that, notchd keeps itself up to date: it checks GitHub Releases in the background (Settings → About → *Check automatically*) and shows a **New Update** activity when there's one.

notchd isn't notarized yet, so macOS will refuse to open it the first time. After unzipping, run this once:

```sh
xattr -dr com.apple.quarantine Notchd.app
```

### Build from source
It takes about a minute.

**Requirements:** macOS 14 Sonoma or later, Xcode or the Command Line Tools (`xcode-select --install`), and `cmake` for the media helper (`brew install cmake`).

```sh
git clone https://github.com/notchd-app/notchd.git
cd notchd
./scripts/bundle.sh
open build/Notchd.app
```

Move `build/Notchd.app` to `/Applications` to keep it. If you have an Apple Development certificate, `bundle.sh` signs with it so macOS remembers your permissions across rebuilds; otherwise it signs ad hoc.

### Permissions
notchd only asks for what a feature needs, the first time it needs it:

| Permission | Used for |
|---|---|
| Calendars | Calendar widget and live activity |
| Reminders | To-do list synced with a Reminders list |
| Bluetooth | Device connect/disconnect activity |
| Screen Recording | Screenshots and screen recordings saved to the tray |
| Camera | Mirror widget |
| Location | Weather for where you are (or pick a city instead) |
| Downloads folder | Download finished activity |
| Accessibility | Pasting from the clipboard history into other apps |
| Full Disk Access | Focus activity: macOS keeps Focus status in a protected folder |

Now Playing works without any permission through [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter).

### Signing
Release builds are signed with a free self-signed certificate. It doesn't silence Gatekeeper on first launch (that takes a paid Developer ID), but a stable signature lets macOS keep notchd's permissions across updates, and the updater only installs builds signed with the same certificate.

Maintainers set it up once:

```sh
./scripts/make-signing-cert.sh --upload   # creates ~/.notchd-signing and the GitHub secrets
```

Back up `~/.notchd-signing`: a new certificate means everyone re-grants permissions once, and installed copies won't auto-update across the switch. Without the secrets, CI falls back to ad-hoc signing.

## Gestures cheat sheet

| Do this on the notch | To |
|---|---|
| Click / swipe down | Open |
| Swipe up / move the pointer away | Close |
| Swipe up on an activity | Tuck it away |
| Swipe left / right | Previous / next track |
| Right-click | Settings, Quit |
| Drag a file to the top of the screen | Tray or AirDrop |

## Development

```
Sources/Notchd/
  main.swift            app delegate, one notch window per screen
  NotchController.swift window, pointer tracking, gestures, keyboard
  NotchModel.swift      notch geometry and state, spring presets
  NotchView.swift       the notch shape and its states
  LiveActivities.swift  activity priority, Glance, fullscreen detection
  Media / Calendar (Widgets) / Timer / Tray / Bluetooth / Battery .swift
  Clipboard / Pomodoro / Stats / Weather / Lyrics / ColorPicker .swift
  Focus / Privacy / Downloads / Agents / KeepAwake / AudioDevices .swift
  TrayActions.swift     zip, image conversion, background removal, PDFs
  Grid.swift            unit-based widget layout
  Settings.swift        preferences (one JSON blob) and the Settings window
  Welcome.swift         first-launch tour
Tests/NotchdTests/      unit tests (Swift Testing)
scripts/                bundle, tests, media helper, icon
```

```sh
./scripts/test.sh                  # unit tests
./scripts/bundle.sh                # build build/Notchd.app for this Mac
UNIVERSAL=1 ./scripts/bundle.sh    # Apple Silicon + Intel, like CI
./scripts/make-icns.sh             # regenerate the icon from scripts/make-icon.swift
```

### Releases
The version lives in the `VERSION` file. CI ([`.github/workflows/build.yml`](.github/workflows/build.yml)) tests and builds every push and pull request and uploads the zipped app as an artifact. Pushing a tag that matches `VERSION` also publishes a GitHub Release:

```sh
echo 0.2.0 > VERSION && git commit -am "Release 0.2.0"
git tag v0.2.0 && git push origin main v0.2.0
```

Handy launch arguments while hacking:

```sh
open build/Notchd.app --args --open                  # open the notch on launch
open build/Notchd.app --args --settings              # open Settings
open build/Notchd.app --args --welcome               # show the welcome tour
open build/Notchd.app --args -demo bluetooth         # battery | unplugged | full | low | bluetooth | timer | peek | update | install
open build/Notchd.app --args -debugFakeEvent YES     # fake video call in 5 minutes
```

Pull requests are welcome. Keep the animations springy and the code small.

## Roadmap

- [ ] Notes, Shortcuts, Camera mirror and app launcher widgets
- [ ] Calendar day strip, to-do favorites and archive
- [ ] Drop-zone actions (zip, convert, compress images…) with installable packs
- [ ] Volume & brightness overlay
- [ ] Notarized, Developer ID–signed releases

## Credits

- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) by ungive (BSD-3-Clause), which makes Now Playing work on macOS 15.4 and later.

## License

[Apache 2.0](LICENSE).

notchd is an independent project, not affiliated with or endorsed by Apple Inc. "Dynamic Island" is a trademark of Apple Inc., used here only to describe the style of the interface.
