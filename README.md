# KeelMac

Keep your Mac fast and roomy: see what's happening, clean safely, and never pay a subscription.

KeelMac is a free, open-source native macOS app that combines what usually takes five tools: a menu bar monitor (like Stats), a storage map (like DaisyDisk), a safe cleaner (like CleanMyMac), an app uninstaller (like AppCleaner) and classic maintenance tasks (like OnyX). It has no account, no telemetry, and makes no network calls except the update check.

**Website:** https://keelmac.flowrunnerapp.workers.dev · **Español:** https://keelmac.flowrunnerapp.workers.dev/es/

## Features

- **Dashboard and Health Score.** One score from 0 to 100 with the reasons behind it (disk free, memory pressure, battery health, reclaimable space, startup items) and a fix for each. Disk usage is shown against a *load line* at 85% full, the point below which macOS has room for updates, swap and snapshots.
- **Menu bar monitor.** CPU, memory pressure, disk free, network, battery and temperature every 2 seconds (1–10 s configurable), the last hour as charts, and the top 5 processes with Quit.
- **Battery.** Cycle count, maximum capacity, condition, temperature, charging state and adapter wattage.
- **Storage map.** A full-disk scan in under a minute, explored as a treemap or a sunburst; incremental rescans; large and old files; the real folders behind "System Data".
- **Cleanup.** User caches, logs, crash reports, browser caches (never history or passwords), Trash, developer junk (Xcode DerivedData, Archives, old DeviceSupport, unavailable simulators, SwiftPM, npm, Yarn, pnpm, Homebrew, CocoaPods, Gradle, Docker opt-in), old iPhone backups, installers in Downloads, and language files of unsigned apps.
- **Apps.** Complete uninstall with related files, drag-and-drop, leftovers from deleted apps, an optional watcher when you trash an app, login items and background agents.
- **Maintenance.** Rebuild Spotlight, flush DNS, run periodic scripts, verify the startup disk, rebuild Launch Services, clear font caches, thin local Time Machine snapshots. Each task shows the exact command it runs.
- **Duplicates, snapshots and a weekly report** you can export as Markdown.
- English and Spanish, light and dark mode, VoiceOver labels and keyboard navigation.

## Safety model

KeelMac deletes files, so it is built around five rules:

1. **Preview first.** Every cleanup, uninstall and duplicate removal starts as a list of every path and size. Only items in that list, and only the ones you leave checked, are touched.
2. **Trash first.** Items go to the Trash. Permanent delete is a setting you turn on yourself, and it still asks.
3. **Protected in code.** `/System`, `/usr` (except `/usr/local`), `/bin`, `/sbin`, other users' homes, iCloud Drive, the Photos library, Mail, Messages, Safari history, Keychains and KeelMac's own data are refused by `PathGuard` (in [SafetyKit](Packages/SafetyKit/Sources/SafetyKit/PathGuard.swift)), in the app and again in the privileged helper. Symlinks and `..` can't escape it.
4. **Your whitelist wins.** Paths and patterns you add in Settings are checked immediately before every removal.
5. **Everything is logged.** Each action (path, size, date, result) goes to the operation log, which you can search and export as CSV, JSON or Markdown.

If something can't be proved safe (it changed since the preview, an app is using it, it needs permissions KeelMac doesn't have), it is skipped and the reason is shown.

## Install

- **Download:** the latest DMG from [Releases](https://github.com/DarthQach/keelmac/releases/latest), open it and drag KeelMac to Applications.
- **Homebrew:** `brew install --cask keelmac` (once the cask is published).

Requires macOS 14 Sonoma or later. Apple silicon is the primary target; Intel works on a best-effort basis (universal binary).

## Permissions

| Permission | Why | Without it |
|---|---|---|
| Full Disk Access | Many caches, logs, Mail downloads, Safari's cache and the Trash live in folders macOS protects. | KeelMac works, skips those folders and tells you which ones. |
| Notifications | Disk, memory, temperature and battery alerts, the weekly summary, the trashed-app offer. | No alerts; everything else works. |
| Background item "KeelMac" (helper) | Admin-only maintenance tasks and system login items, approved once in System Settings › General › Login Items. | Admin tasks show "Needs the KeelMac helper"; user-level tasks still run. |

## Build from source

Requirements: Xcode 16 or later (built with Xcode 27.1), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), Node 20+ for the asset and site scripts.

```bash
git clone https://github.com/DarthQach/keelmac.git && cd keelmac
bash scripts/mac.sh run          # generates KeelMac.xcodeproj, builds, launches
bash scripts/mac.sh test         # package tests + app unit tests
```

To sign with your own team, create `Config/Local.xcconfig` with `DEVELOPMENT_TEAM = <your team id>`.

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
