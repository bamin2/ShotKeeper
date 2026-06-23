# ShotKeeper

**Screenshots are a second brain — ShotKeeper keeps them named and findable.**

ShotKeeper is a native macOS app that automatically gives your screenshots clear,
descriptive names and builds a fast, private, offline search index — so you can
find any screenshot by keyword, the text inside it, or what it shows. Inspired by
[Keep It Shot](https://keepitshot.com).

---

## Features

- **AI renaming** — turns `Screenshot 2026-06-23 at 11.04.21.png` into
  `Strathclyde Business School Market Structure.png`.
- **Three naming engines** with automatic fallback: **Claude**, **OpenAI**, and
  **Apple Intelligence** (fully on-device). Tried in priority order; Apple
  Intelligence always works as the offline fallback, so no API key is required.
- **Private, offline search** — name, OCR text, one-line summary, and keywords
  are stored in a local SQLite full-text index. Searching never touches the network.
- **Rename from Finder** — select screenshots in Finder and rename them with a
  global hotkey (⌥⌘I) or the menu-bar item, without switching apps.
- **Auto-rename** — optionally watch a folder (e.g. your Desktop) and name new
  screenshots as they appear.
- **List & grid views** grouped by date, clickable keyword chips, full-image
  thumbnails, inline rename, drag-and-drop, copy-to-clipboard, and one-click revert.
- **Menu bar + Dock hybrid** — lives in the menu bar; the Dock icon appears only
  while a window is open.
- **Auto-updates** via [Sparkle](https://sparkle-project.org).

---

## Privacy

Search and the index are entirely local. With the **Apple Intelligence** engine,
images never leave your Mac — OCR and naming run on-device. The **Claude** and
**OpenAI** engines send each image to that provider only at the moment you rename
it. API keys are stored in the macOS **Keychain**, never in plain files.

---

## Install

Download the latest `ShotKeeper.dmg` from the
[**Releases**](https://github.com/bamin2/ShotKeeper/releases) page, open it, and
drag ShotKeeper into Applications. The app updates itself from then on.

> Requires macOS 14 or later. On-device naming with **Apple Intelligence**
> requires a recent macOS with Apple Intelligence enabled (Apple Silicon).

---

## How it works

Every engine returns the same `VisionResult` (name, OCR, summary, keywords), so
the rename engine, search index, and UI are completely decoupled from *how* a
screenshot is described.

```
ShotKeeperApp.swift     App entry, menu-bar menu, Dock/accessory switching, Sparkle updater
AppStore.swift          State + orchestration: engine routing, rename/revert,
                        Keychain, shortcuts, Finder bridge, global hotkey
Models/
  Screenshot.swift      Data model + VisionResult
Services/
  VisionClient.swift    Claude + OpenAI clients, the on-device describer
                        (Vision OCR + classification + Apple Intelligence), heuristics
  SearchIndex.swift     Local SQLite FTS5 search index
  FolderWatcher.swift   FSEvents watcher for auto-rename
Views/
  ContentView.swift     Search, list/grid, cards, chips, drag-and-drop, status bar
  SettingsView.swift    Preferences / API Key / Help / About tabs
```

**Naming pipeline (on-device):** Apple's Vision framework extracts text (OCR) and
image tags locally; the heading is detected (skipping vertical sidebar/letterhead
text); that context is handed to Apple's on-device model via the Foundation Models
framework, which returns a structured name, summary, and keywords. Names are
normalized to Title Case. If Apple Intelligence isn't available, a local heuristic
namer is used. Cloud engines (Claude/OpenAI) follow the same contract.

---

## Build from source

Requires Xcode 16+ (Xcode 26/27 for the Apple Intelligence APIs).

1. Clone the repo and open `ShotKeeper.xcodeproj`.
2. Resolve the Swift Package dependency ([Sparkle](https://github.com/sparkle-project/Sparkle)) — Xcode does this automatically.
3. Set your signing **Team** under the target's *Signing & Capabilities*.
4. Build & run (⌘R). Add an API key in **Settings ▸ API Key** to use Claude or
   OpenAI, or leave it empty to use on-device Apple Intelligence.

---

## Releasing

Releases are produced locally with a single script:

```
# 1. Bump Version / Build in Xcode (target ▸ General)
./release.sh
# 2. Commit docs/ and push (GitHub Pages serves the Sparkle appcast)
# 3. Upload the generated build/ShotKeeper-<version>.dmg to a GitHub Release
```

`release.sh` archives a Release build, signs it with Developer ID, notarizes and
staples it, zips it into `docs/` and regenerates the Sparkle appcast, then builds
a signed, notarized DMG installer. Update feed:
`https://bamin2.github.io/ShotKeeper/appcast.xml`.

See `ShotKeeper/sparkle/SPARKLE-SETUP.md` for the update-hosting details.

---

## Tech stack

SwiftUI · Apple Vision · Foundation Models (Apple Intelligence) · SQLite FTS5 ·
Carbon (global hotkey) · Sparkle (updates) · Anthropic & OpenAI APIs.

---

## Credits

Built by **Bader Amin**.
