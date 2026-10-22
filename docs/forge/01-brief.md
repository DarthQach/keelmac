# Brief · KeelMac

> Source: Notion page "KeelMac — Mac Health App Spec" (https://app.notion.com/p/401e7b5d7d898150939fc56df62c0587), read 2026-10-22.
> Carlos's instruction with the brief: "Do not wait for me to approve anything, go on the steps, until the app is complete." Intake questions and both gates are therefore resolved by the defaults recorded below instead of being asked.

## One-liner
Keep your Mac fast and roomy: see what's happening, clean safely, and never pay a subscription.

## Problem
Mac maintenance is split across many apps: Stats for live metrics, DaisyDisk for storage, AppCleaner for uninstalls, OnyX for maintenance, CleanMyMac for cleanup. The all-in-ones (CleanMyMac, MacKeeper, BuhoCleaner) are paid or subscription-based and often use scary scan results as marketing. A developer's Mac also accumulates tens of gigabytes of Xcode, simulator, npm and Docker junk that generic cleaners don't understand. Today Carlos copes by running several tools and remembering cache paths by hand.

## Product form
A **native macOS app** (Swift 6, SwiftUI, AppKit where needed), free and open source (GPL-3.0), distributed as a notarized DMG and a Homebrew cask from GitHub Releases, plus a small static landing page. This is not a web app: app-forge's Cloudflare/Clerk/Stripe defaults apply only to the landing page and update feed (see 02-stack.md).

## Principles (from the spec, binding on every capability)
- **Safety first:** nothing is deleted without a preview; everything goes to Trash first; every action is logged.
- **Honest:** no fake warnings, no "RAM boost". macOS manages memory; KeelMac only reports it.
- **Transparent:** open source; maintenance tasks show the exact command they run.
- **Private:** zero telemetry, no account, works offline except the update check.
- **Native and light:** small binary, near-zero idle CPU.

## Users and roles
| Role | Who they are | What they can do |
|---|---|---|
| Owner | The person logged in to the Mac (primary: Carlos on a MacBook Pro with a developer workload) | Everything in the app for their own user account |
| Admin (same person, elevated) | The owner after approving the privileged helper once | Run admin-only maintenance and system-level cleanup through the helper's fixed allowlist |
| Visitor | Anyone on the landing page | Read about KeelMac, download the DMG, copy the Homebrew command, support the project |

There are no accounts and no multi-user features.

## Capabilities
Numbered; everything downstream traces to these ids. Spec priority in brackets: [v1] = spec "MVP", [v2] = spec "v2". app-forge builds both (no MVPs); spec "Later" items are out of scope.

**Dashboard and health**
- **C1** [v1] · A user sees a Health Score from 0 to 100 within 3 s of launch (cached values allowed), broken down into disk free, memory pressure, battery health, reclaimable junk and startup items.
- **C2** [v1] · Each score factor says why it scored that way and offers a one-click fix (for example "12.4 GB of developer caches · Review cleanup").
- **C3** [v1] · A user sees summary cards for storage used/free, memory pressure, CPU load, battery %, uptime, macOS version and chip.

**Live monitor and menu bar**
- **C4** [v1] · A user keeps a menu bar item with configurable readouts (CPU, memory pressure, disk free, network up/down, battery, temperature) that updates every 2 s (configurable 1–10 s).
- **C5** [v1] · The menu bar popover shows mini charts for the last 60 minutes and the top 5 processes by CPU and by memory, each with a Quit button.
- **C6** [v1] · A user sees battery cycle count, maximum capacity %, condition, temperature, charging state and adapter wattage from IOKit.
- **C7** [v1] · A user sets alert thresholds (disk below X GB, memory pressure red for X minutes, temperature above X °C, battery capacity below X%) and receives macOS notifications when they are crossed.

**Storage**
- **C8** [v1/v2] · A user scans the startup volume and explores it as a treemap or a sunburst, drilling into folders, with progress, cancel and incremental rescan.
- **C9** [v1] · A user finds large and old files, filtered by size (> 500 MB, > 1 GB) and last opened (> 3, 6, 12 months).
- **C10** [v1] · A user sees macOS "System Data" broken down into the real folders behind it.
- **C11** [v1] · From any file list a user can Reveal in Finder, Quick Look, or Move to Trash.

**Cleanup**
- **C12** [v1] · A user reviews cleanup categories, each with its size and item list: user caches, app logs, crash reports, browser caches (Safari, Chrome, Arc, Firefox, Edge; cache only), Trash on all volumes, developer junk (Xcode DerivedData, Archives, old iOS DeviceSupport, unavailable simulators, SwiftPM, npm/yarn/pnpm, Homebrew, CocoaPods, Gradle, Docker prune opt-in), old iOS/iPadOS backups, installer leftovers in Downloads, and app language files (opt-in).
- **C13** [v1] · Every cleanup starts as a dry-run preview listing every path and size; the user can exclude any item before cleaning.
- **C14** [v1] · Protected paths are hard-coded and a user-editable whitelist is enforced on every delete call, including from the helper; items go to Trash by default, permanent delete only via an explicit setting; anything not provably safe is skipped with a reason.
- **C15** [v1] · A user views every operation (path, size, date, result) in an operation log and exports it.

**Apps**
- **C16** [v2] · A user fully uninstalls an app: the bundle plus related files (Application Support, Caches, Preferences, Containers, Group Containers, Saved State, Logs, LaunchAgents, cookies) matched by bundle ID and name, previewed first.
- **C17** [v2] · A user finds orphaned files left by apps that are already deleted.
- **C18** [v2] · A user drags an app onto a drop zone to uninstall it, and can turn on a watcher that offers cleanup when an app is moved to the Trash.
- **C19** [v2] · A user lists login items and background agents (LaunchAgents, LaunchDaemons, SMAppService items) and can enable, disable or remove them.
- **C20** [v2] · A user sees installed apps sorted by size and last-used date.

**Maintenance**
- **C21** [v2] · A user runs maintenance tasks, each showing a description, the exact command and whether admin is needed: rebuild Spotlight index, flush DNS cache, run periodic scripts, verify startup disk (read-only), rebuild Launch Services database, clear font caches, thin local Time Machine snapshots.
- **C22** [v1] · Admin-only actions go through a privileged helper (SMAppService daemon) that the user approves once; the helper runs only a fixed allowlist of named operations, checks the caller's code signature, and re-validates every path.

**Duplicates**
- **C23** [v2] · A user finds duplicate files (size, then partial hash, then full hash) and reviews them with auto-select rules (keep newest, keep the copy in a preferred folder).

**Snapshots and reports**
- **C24** [v2] · KeelMac takes a weekly storage snapshot by top folders, and a user compares two snapshots to see what grew.
- **C25** [v2] · A user gets a weekly summary notification (space change, battery capacity trend, top growing folders, reclaimable junk) and can export the report as Markdown.

**Settings and support**
- **C26** [v1] · A user sets launch at login, menu bar items, alert thresholds, units, scan exclusions, the whitelist, and Trash versus permanent delete.
- **C27** [v1] · KeelMac detects missing Full Disk Access, explains why it is needed, and deep-links to the right System Settings pane.
- **C28** [v1] · A user can support the project from About (Buy Me a Coffee), and after a big cleanup sees one soft prompt at most once per 30 days, dismissible forever.
- **C29** [v1] · KeelMac checks for updates with Sparkle (EdDSA-signed appcast, signed updates only) and links to release notes and GitHub issues.
- **C30** [v1] · The app is fully usable in English and Spanish, in light and dark mode, with VoiceOver labels and keyboard navigation.

**Distribution**
- **C31** [v1] · A contributor finds a complete repo (README with safety model, LICENSE, CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, CHANGELOG, issue templates), CI that builds and tests every push, a release workflow (sign, notarize, DMG, appcast), and a Homebrew cask; cleanup rules live in a versioned JSON file contributors can extend by PR.
- **C32** [v1] · A visitor reads the landing page (what it does, screenshots, safety model, FAQ), downloads the DMG or copies the Homebrew command, and can support the project.

## Monetization
Free, open source (GPL-3.0). Optional Buy Me a Coffee. No payments in the app, so no Stripe.

| Plan | Price | Limits / features |
|---|---|---|
| KeelMac | Free | Everything |

## Data
All local, in the user's Library:
- **Operation log entry:** date, operation (clean, uninstall, trash file, maintenance task), path, size, result (trashed, deleted, skipped + reason, failed + error).
- **Storage snapshot:** date, volume totals, sizes of top folders.
- **Scan cache:** last scan tree of the startup volume (for incremental rescan and the Health Score's cached values).
- **Metrics history:** rolling 60 minutes of CPU, memory, network, battery, temperature samples (in memory; not persisted).
- **Settings:** menu bar items, refresh interval, thresholds, units, exclusions, whitelist, delete mode, watcher on/off, coffee prompt state.
- **Cleanup rules:** versioned JSON shipped in the app (category, paths/globs, min age, needs-admin, description, safety notes).

## Integrations
- macOS system APIs: Mach (`host_statistics64`, `host_processor_info`), `libproc` (`proc_pidinfo`), IOKit (`AppleSmartBattery`, IORegistry), IOHID temperature sensors, `statfs`/`URLResourceValues`, `getattrlistbulk`, `ServiceManagement` (`SMAppService`), `UserNotifications`, `NSWorkspace`, Quick Look.
- Sparkle 2 for updates (appcast hosted on the landing site).
- GitHub (repo, Actions, Releases) and Homebrew (cask).
- Buy Me a Coffee (outbound link only).

## Content and notifications
- Carlos writes the landing page copy, release notes, cleanup rule descriptions (contributors may add rules by PR).
- Local notifications only: threshold alerts (C7), weekly summary (C25), app-trashed watcher offer (C18).

## Non-functionals
- Users at launch / in 12 months: 1 (Carlos) / a few thousand downloads; no server load beyond static files.
- Regions and data residency: none; no data leaves the Mac.
- Compliance: none regulated. Privacy: zero telemetry, no network calls except the Sparkle feed.
- Languages (UI copy): English and Spanish at v1.0.
- Accessibility: VoiceOver labels, keyboard navigation, Dynamic Type where macOS supports it; landing page WCAG 2.2 AA.
- Platform: macOS 14 Sonoma or later, Apple silicon primary, universal binary (Intel best-effort).
- Performance targets: idle CPU < 1% (menu bar only), memory < 80 MB idle and < 300 MB during a full scan, full scan of 500 GB used < 60 s, app < 25 MB, first window < 1.5 s.
- Safety: zero deletions outside the previewed list; every delete logged.

## Out of scope
- Antivirus or malware scanning (spec non-goal).
- "RAM cleaner" or memory purging (spec non-goal).
- Windows or Linux (spec non-goal).
- Mac App Store distribution (sandbox blocks deep cleaning).
- Similar-photo detection with Vision (spec "Later").
- Browser history, cookies and password cleaning (only caches; see assumptions).

## Assumptions
- ASSUMPTION · Scope is spec v1.0 plus v2 (app-forge builds every capability); "Later" items are out of scope. Carlos told app-forge not to wait for approvals, so this is recorded rather than asked.
- ASSUMPTION · License GPL-3.0, the spec's default.
- ASSUMPTION · No Developer ID certificate exists on this Mac (only Apple Development). The build is signed with Apple Development for local use; the release workflow signs with Developer ID and notarizes once Carlos adds the certificate and notary credentials as GitHub Actions secrets. Paying for / enabling Developer ID and the first notarized release is Carlos's step.
- ASSUMPTION · The GitHub repository `keelmac` is created **private** under Carlos's account; making it public (the spec says public from day one) is a one-command step left to Carlos, because publishing code is outward-facing.
- ASSUMPTION · Docker prune is an opt-in cleanup category (off by default) and runs `docker system prune` only when Docker is installed and running; browser history stays out of scope (open question resolved to the safer option).
- ASSUMPTION · "Big cleanup" for the coffee prompt means at least 2 GB freed in one run.
- ASSUMPTION · The Buy Me a Coffee URL is `https://buymeacoffee.com/keelmac`, held in one constant; Carlos must claim that handle (or change the constant) before release. GitHub Sponsors is not added.
- ASSUMPTION · No custom domain yet; the landing page and appcast live on `keelmac.<account>.workers.dev`.
- ASSUMPTION · Settings live in `UserDefaults`; the operation log and snapshots use SwiftData (spec), stored in `~/Library/Application Support/KeelMac`.
- ASSUMPTION · Bundle ID `mx.cvillegas.keelmac`, helper `mx.cvillegas.keelmac.helper`, matching Carlos's other apps.
- ASSUMPTION · The privileged helper is approved by the user in System Settings › Login Items; app-forge cannot approve it, so live helper acceptance is a manual check for Carlos.
- ASSUMPTION · CPU/SoC temperature on Apple silicon is read from IOHID temperature sensors (as Stats does); when unavailable, temperature readouts show "Unavailable" rather than a guess.

## Open questions
- Domain for KeelMac (not blocking; workers.dev until then).
- When to pay the Apple Developer Program fee and switch releases to notarized (not blocking the build).
