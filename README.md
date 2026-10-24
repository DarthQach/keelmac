# KeelMac

Keep your Mac fast and roomy: see what's happening, clean safely, and never pay a subscription.

KeelMac is a free, open-source native macOS app that combines what usually takes five tools: a menu bar monitor (like Stats), a storage map (like DaisyDisk), a safe cleaner (like CleanMyMac), an app uninstaller (like AppCleaner) and classic maintenance tasks (like OnyX). It has no account, no telemetry, and makes no network calls on its own except the update check. The Assistant talks to your local Ollama or LM Studio, and Projects talks to GitHub through your own git and gh logins, only when you turn them on.

## Features

- **Dashboard and Health Score.** One score from 0 to 100 with the reasons behind it (disk free, memory pressure, battery health, reclaimable space, startup items) and a fix for each. Disk usage is shown against a *load line* at 85% full, the point below which macOS has room for updates, swap and snapshots.
- **Menu bar monitor.** CPU, memory pressure, disk free, network, battery and temperature every 2 seconds (1–10 s configurable), the last hour as charts, and the top 5 processes with Quit.
- **Battery.** Cycle count, maximum capacity, condition, temperature, charging state and adapter wattage.
- **Storage map.** A full-disk scan in under a minute, explored as a treemap or a sunburst; incremental rescans; large and old files; the real folders behind "System Data".
- **Cleanup.** User caches, logs, crash reports, browser caches (never history or passwords), Trash, developer junk (Xcode DerivedData, Archives, old DeviceSupport, unavailable simulators, SwiftPM, npm, Yarn, pnpm, Homebrew, CocoaPods, Gradle, Docker opt-in), old iPhone backups, installers in Downloads, and language files of unsigned apps.
- **Apps.** Complete uninstall with related files, drag-and-drop, leftovers from deleted apps, an optional watcher when you trash an app, login items and background agents.
- **Maintenance.** Rebuild Spotlight, flush DNS, run periodic scripts, verify the startup disk, rebuild Launch Services, clear font caches, thin local Time Machine snapshots. Each task shows the exact command it runs.
- **Projects.** Point it at `~/Developer` (or any folders) and see, for each project, whether every branch, tag and change is on GitHub and when you last touched it. Projects proved to be on GitHub and untouched for 6 months (adjustable) can go to the Trash; the rest can be backed up to a private repository with your `gh` login, after a preview of every command.
- **Duplicates, snapshots and a weekly report** you can export as Markdown.
- English and Spanish, light and dark mode, VoiceOver labels and keyboard navigation.

## Safety model

KeelMac deletes files, so it is built around five rules:

1. **Preview first.** Every cleanup, uninstall and duplicate removal starts as a list of every path and size. Only items in that list, and only the ones you leave checked, are touched.
2. **Trash first.** Items go to the Trash. Permanent delete is a setting you turn on yourself, and it still asks. Projects always go to the Trash.
3. **Protected in code.** `/System`, `/usr` (except `/usr/local`), `/bin`, `/sbin`, other users' homes, iCloud Drive, the Photos library, Mail, Messages, Safari history, Keychains and KeelMac's own data are refused by `PathGuard` (in [SafetyKit](Packages/SafetyKit/Sources/SafetyKit/PathGuard.swift)), in the app and again in the privileged helper. Symlinks and `..` can't escape it.
4. **Your whitelist wins.** Paths and patterns you add in Settings are checked immediately before every removal.
5. **Everything is logged.** Each action (path, size, date, result) goes to the operation log, which you can search and export as CSV, JSON or Markdown.

If something can't be proved safe (it changed since the preview, an app is using it, it needs permissions KeelMac doesn't have), it is skipped and the reason is shown.

## Install

KeelMac is installed by building it from this repository. The first time takes about ten minutes, most of it Xcode's download.

You need:

- A Mac with macOS 14 Sonoma or later. Apple silicon is the main target; Intel works on a best-effort basis.
- Xcode, free from the Mac App Store. KeelMac is built and tested with Xcode 27.1; older versions may not compile it. Open Xcode once after installing it so it can finish setting up.
- [Homebrew](https://brew.sh), then XcodeGen, which creates the Xcode project:

```bash
brew install xcodegen
```

Then:

1. **Get the code.**

   ```bash
   git clone https://github.com/DarthQach/keelmac.git && cd keelmac
   ```

2. **Choose how the app is signed.** This copies a ready-made setting that needs no Apple account; the app is signed to run on your Mac only. The file explains how to use your own Apple developer team instead.

   ```bash
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

3. **Build it.** This creates `dist/KeelMac.app`.

   ```bash
   bash scripts/mac.sh release-build
   ```

4. **Move it to Applications.** Open the `dist` folder and drag KeelMac into Applications, then open it from there.

   ```bash
   open dist
   ```

## Update

New versions arrive as commits to this repository. From the `keelmac` folder you cloned:

```bash
git pull && bash scripts/mac.sh release-build
```

Quit KeelMac, then drag the new `dist/KeelMac.app` into Applications and choose **Replace**. Your settings and the operation log are kept: they live in `~/Library/Application Support/KeelMac` and KeelMac's preferences, not in the app.

Builds from source update this way only. **Check for Updates…** in the app looks for published releases, so it will say you're up to date.

## Permissions

| Permission | Why | Without it |
|---|---|---|
| Full Disk Access | Many caches, logs, Mail downloads, Safari's cache and the Trash live in folders macOS protects. | KeelMac works, skips those folders and tells you which ones. |
| Notifications | Disk, memory, temperature and battery alerts, the weekly summary, the trashed-app offer. | No alerts; everything else works. |
| Background item "KeelMac" (helper) | Admin-only maintenance tasks and system login items, approved once in System Settings › General › Login Items. Needs an app signed with an Apple developer team (option B in `Config/Local.xcconfig.example`). | Admin tasks show "Needs the KeelMac helper"; user-level tasks still run. |

## Development

Node 20 or later is needed for the asset and string scripts.

```bash
bash scripts/mac.sh run          # generates KeelMac.xcodeproj, builds a debug app, launches it
bash scripts/mac.sh test         # package tests + app unit tests
```

## Project layout

| Path | What |
|---|---|
| `App/` | SwiftUI app: screens in `App/Features`, design system in `App/DesignSystem` |
| `Helper/` | The privileged helper daemon (runs only named operations) |
| `Packages/SafetyKit` | PathGuard, whitelist, Trash-first remover, operation log types |
| `Packages/MetricsKit` | CPU, memory, disk, network, battery, temperature, processes |
| `Packages/ScanKit` | Disk scanner, treemap and sunburst layouts, large files, System Data |
| `Packages/CleanKit` | Cleanup rules (`cleanup-rules.json`), planner and executor |
| `Packages/AppsKit` | App inventory, related files, leftovers, launch items |
| `Packages/MaintenanceKit` | Maintenance tasks, helper protocol and client |
| `Packages/InsightsKit` | Duplicates, Health Score, alerts, snapshots, weekly report |
| `Packages/AssistantKit` | Ollama and LM Studio clients and the Assistant's tool loop |
| `Packages/ProjectsKit` | Project checks with git and gh, backup planner and executor |
| `site/` | The landing page and Sparkle appcast (Cloudflare Workers static assets) |
| `docs/forge/` | Brief, stack, design and plan documents |

## Contributing

Bug reports and cleanup-rule ideas are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md); safety problems go through [SECURITY.md](SECURITY.md).

## Support

KeelMac is free. If it saved you an afternoon, you can [buy me a coffee](https://buymeacoffee.com/keelmac).

## Credits

Metric collection approaches were studied from [Stats](https://github.com/exelban/stats) (MIT) and cleanup coverage from [Mole](https://github.com/tw93/mole) (GPL-3.0). Updates use [Sparkle](https://sparkle-project.org).

## Licence

GPL-3.0. See [LICENSE](LICENSE).
