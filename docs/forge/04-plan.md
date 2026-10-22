# Execution plan · KeelMac

> Approved 2026-10-22 (Gate 2, by Carlos's standing instruction "do not wait for me to approve anything"). Source documents: 01-brief, 02-stack, 03-design.

## Summary
When this plan is done, `~/Developer/KeelMac` holds a native macOS app, **KeelMac.app** (Swift 6, SwiftUI, macOS 14+), with a menu bar monitor, Health Score dashboard, storage map (treemap and sunburst), large and old files, System Data breakdown, safe dry-run cleanup with Trash-first deletion and an operation log, an app uninstaller with leftovers and login items, maintenance tasks with a privileged helper, duplicates, weekly snapshots and reports, Sparkle updates, English and Spanish. A notarization-ready release pipeline (GitHub Actions, DMG, appcast, Homebrew cask) exists, and the landing page plus appcast are live at `https://keelmac.<account>.workers.dev`. The app is built, tested and run on Carlos's Mac with the Apple Development identity; notarized public releases wait for Carlos's Developer ID secrets.

Independent module work inside a milestone (for example MetricsKit and ScanKit) runs in parallel subagents, each owning its own files; UI integration and verification happen in the main session.

## Repository layout
Modules are split into one Swift package per group (see contracts.md) so they build and test independently; `Packages/KeelKit/Sources/<Module>` below reads as `Packages/<Kit>/Sources/<Module>`.
```
KeelMac/
├── project.yml                  # XcodeGen: app, helper, UI tests (generates KeelMac.xcodeproj, not committed)
├── Config/                      # Shared.xcconfig, Info plists, entitlements, helper launchd plist
├── App/                         # SwiftUI app target
│   ├── KeelMacApp.swift         # scenes: main window, Settings, MenuBarExtra
│   ├── AppModel.swift           # @Observable root state, services wiring
│   ├── DesignSystem/            # Theme colours (asset catalog), LoadLineGauge, StatusBadge, ByteText, EmptyStateView…
│   ├── Features/<Screen>/       # one folder per screen (Dashboard, Monitor, MenuBar, Storage, LargeOld, SystemData, Cleanup, OperationLog, Apps, Leftovers, LoginItems, Maintenance, Duplicates, Snapshots, Settings, About, Onboarding)
│   ├── Persistence/             # SwiftData models + OperationLog/SnapshotStore implementations
│   └── Resources/               # Assets.xcassets (generated colour sets + AppIcon), Localizable.xcstrings
├── Helper/                      # KeelMacHelper daemon (main.swift, HelperService.swift)
├── Packages/KeelKit/            # Swift package, one library per module + tests
│   └── Sources/{SafetyKit,MetricsKit,ScanKit,CleanKit,AppsKit,MaintenanceKit,DuplicatesKit,ReportKit,HelperShared}
├── Tests/KeelMacUITests/        # XCUITest happy paths
├── scripts/                     # mac.sh (lint/test/build/run/e2e), tokens.mjs, make_icon.swift, make_dmg.sh, release.sh, strings.mjs
├── site/                        # Cloudflare Worker static assets (landing EN/ES, releases, privacy, appcast.xml)
├── Casks/keelmac.rb             # Homebrew cask (template filled by release.sh)
├── .github/                     # workflows (ci.yml, release.yml), issue templates
├── design/                      # tokens.css (source of truth), contrast-pairs.json, canvas/ artboards
└── docs/forge/                  # 00-status … 04-plan
```

## Milestones
| # | Milestone | Capabilities | Status |
|---|---|---|---|
| M0 | Foundation: repo, XcodeGen project, KeelKit skeleton, app shell, tokens, CI, site deployed | C30 (shell), C31 (part), C32 (part) | [x] |
| M1 | Monitor: MetricsKit, menu bar extra and popover, Monitor screen, battery | C3, C4, C5, C6 | [x] |
| M2 | Storage: ScanKit, storage map (treemap, sunburst), large and old files, System Data, file actions | C8, C9, C10, C11 | [x] |
| M3 | Cleanup and safety: SafetyKit, CleanKit, rules JSON, dry-run, Trash-first executor, operation log, coffee prompt | C12, C13, C14, C15, C28 (prompt) | [x] |
| M4 | Health, alerts, onboarding, settings | C1, C2, C3, C7, C26, C27 | [x] |
| M5 | Apps: inventory, uninstall, leftovers, drop zone, Trash watcher, login items | C16, C17, C18, C19, C20 | [x] |
| M6 | Helper and maintenance | C21, C22 | [x] |
| M7 | Duplicates, snapshots, weekly report | C23, C24, C25 | [x] |
| M8 | Distribution: Sparkle, About, landing page and appcast, release workflow, DMG, cask, repo docs | C28 (About), C29, C31, C32 | [x] |
| M9 | Polish: fidelity vs artboards, Spanish complete, accessibility, performance, docs final | C30, all | [x] |

### M0 · Foundation
**Goal:** `bash scripts/mac.sh run` opens KeelMac with the full sidebar, every destination showing its designed empty state, and the landing page skeleton is live on workers.dev.
**Capabilities:** C30 (shell), C31 (part), C32 (part)

| # | Task | Files |
|---|---|---|
| 1 | Repo hygiene: LICENSE (GPL-3.0), README, AGENTS, CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, CHANGELOG, issue templates, .gitignore | root, .github/ |
| 2 | `project.yml` with targets KeelMac (app), KeelMacHelper (tool), KeelMacUITests; KeelKit local package | project.yml, Config/ |
| 3 | KeelKit package with nine library targets and a test target each | Packages/KeelKit |
| 4 | `scripts/tokens.mjs` mirrors design/tokens.css into colour sets; `--check` in lint | scripts/tokens.mjs, App/Resources/Assets.xcassets |
| 5 | App icon generated from the design (hull ink, verdigris water, Plimsoll mark) | scripts/make_icon.swift |
| 6 | App shell: `NavigationSplitView` with sections, `Route` enum, empty states, Settings scene, MenuBarExtra placeholder | App/ |
| 7 | String Catalog with en + es | App/Resources/Localizable.xcstrings |
| 8 | `scripts/mac.sh` (lint, test, build, run, e2e) + `package.json` scripts for verify.sh | scripts/mac.sh, package.json |
| 9 | GitHub Actions CI: build + `swift test` + xcodebuild test on push | .github/workflows/ci.yml |
| 10 | Site skeleton (EN) and `wrangler deploy` | site/ |

**Acceptance criteria**
- [ ] `bash ~/.claude/skills/app-forge/scripts/verify.sh` exits 0.
- [ ] `xcodebuild -scheme KeelMac build` succeeds with zero warnings in our code under Swift 6 strict concurrency.
- [ ] The app launches; every sidebar item opens a screen with its empty state; ⌘, opens Settings.
- [ ] `curl -sI https://keelmac.<account>.workers.dev/` returns 200.

**Tests:** KeelKit placeholder tests compile and pass; UI test launches the app and visits every sidebar item.

### M1 · Monitor
**Goal:** The menu bar shows live CPU, memory pressure, disk free, network, battery and temperature; the popover shows 60-minute charts and the top 5 processes with Quit; the Monitor screen shows the same plus battery details.
**Capabilities:** C3 (metrics), C4, C5, C6

| # | Task | Files |
|---|---|---|
| 1 | `CPUReader` (host_processor_info deltas, per-core and total), `MemoryReader` (host_statistics64 + `kern.memorystatus_vm_pressure_level`), `DiskReader` (volume capacities), `NetworkReader` (getifaddrs deltas), `BatteryReader` (AppleSmartBattery + IOPowerSources), `TemperatureReader` (IOHID via dlsym, battery fallback), `ProcessSampler` (libproc, CPU% deltas, phys footprint, uid), `SystemInfo` (chip, model, macOS, uptime) | Packages/KeelKit/Sources/MetricsKit |
| 2 | `MetricsHistory` ring buffer (1,800 samples = 60 min at 2 s) | MetricsKit |
| 3 | `MetricsMonitor` @MainActor @Observable service on a configurable timer (1–10 s), heavy probes (processes, temperature) only while a consumer is visible | App/Services |
| 4 | MenuBarExtra label with configurable items (UserDefaults), popover (readouts, chart, top processes with Quit, battery line, footer) | App/Features/MenuBar |
| 5 | Monitor screen (four charts, top processes table with CPU/Memory toggle, battery panel) | App/Features/Monitor |
| 6 | Quit: `NSRunningApplication.terminate()` for apps; SIGTERM with confirmation for other own-user processes; system and other users' processes refused | App/Features/Monitor |

**Acceptance criteria**
- [ ] CPU and memory readings are within ±5% of Activity Monitor on this Mac (manual comparison, recorded in the status log).
- [ ] Battery cycle count and maximum capacity match `system_profiler SPPowerDataType`.
- [ ] The menu bar label updates every 2 s; changing the interval to 5 s takes effect without relaunch.
- [ ] Idle CPU of KeelMac with only the menu bar visible is < 1% averaged over 60 s (`ps -o %cpu`).
- [ ] Quit on a process owned by root is not offered.

**Tests:** CPU percentage math from tick deltas; memory used formula; network delta with counter wrap; ring buffer capacity and order; process CPU% from time deltas; battery dictionary parsing from a fixture; menu bar label formatting.

### M2 · Storage
**Goal:** A user scans Macintosh HD in under a minute, explores it as a treemap or sunburst with breadcrumbs, finds large and old files, sees System Data broken down, and can reveal, Quick Look or trash any item.
**Capabilities:** C8, C9, C10, C11

| # | Task | Files |
|---|---|---|
| 1 | `DiskScanner` actor: `getattrlistbulk` walker (name, type, alloc size, mod time, file id, link count, dev id), task-group fan-out, progress stream, cancellation, same-device only, hard links counted once, unreadable folders recorded | ScanKit |
| 2 | `ScanTree` (directory nodes with size, file count, mtime, top files), JSON cache in Application Support, FSEvents-based incremental rescan (replay since stored event id, rescan changed directories only) and "Rescan this folder" | ScanKit |
| 3 | `TreemapLayout` (squarified) and `SunburstLayout` (rings by depth, angle by size) as pure functions | ScanKit |
| 4 | `LargeFileIndex` (files ≥ 100 MB from the scan; last opened from `kMDItemLastUsedDate`, fallback access date) | ScanKit |
| 5 | `SystemDataBreakdown` (known locations, local snapshots via `tmutil listlocalsnapshots /` + `diskutil apfs` sizes when readable) | ScanKit |
| 6 | Storage map screen (Canvas treemap + sunburst with hit testing, keyboard navigation, breadcrumb, selection inspector), empty and scanning states | App/Features/Storage |
| 7 | Large and old files screen (filters, multi-select table, actions) and System Data screen | App/Features/LargeOld, SystemData |
| 8 | `FileActions`: Reveal in Finder, Quick Look panel, Move to Trash through SafetyKit and the operation log | App/Services |

**Acceptance criteria**
- [ ] Full scan of this Mac's Data volume finishes in < 60 s (timed, recorded) and peak memory < 300 MB.
- [ ] Treemap rectangles' areas are proportional to sizes (test), and double-click drills in; Escape goes up.
- [ ] Large and old filter "> 1 GB, not opened for 6 months" shows only matching files (test with fixture dates).
- [ ] Trashing a file from Storage moves it to the Trash and adds an operation log row.

**Tests:** Scanner on a temp fixture tree (sizes, hard links, unreadable folder, cancellation); treemap and sunburst layout invariants; cache round trip; incremental rescan updates a changed folder only; large-file filters.

### M3 · Cleanup and safety
**Goal:** A user reviews every cleanup category with sizes and items, excludes items, and moves exactly the previewed items to the Trash; every action is logged and exportable; protected and whitelisted paths are never touched.
**Capabilities:** C12, C13, C14, C15, C28 (prompt)

| # | Task | Files |
|---|---|---|
| 1 | `PathGuard`: hard-coded protected roots and patterns, whitelist (exact paths and `*`/`**` globs), symlink and `..` resolution, context (cleanup, userFile, uninstall, helper), verdict with reason | SafetyKit |
| 2 | `SafeRemover`: Trash-first (`FileManager.trashItem`) or permanent delete when the setting allows, re-checks `PathGuard` and "changed since preview", returns per-item results | SafetyKit |
| 3 | `cleanup-rules.json` (schema v1) with every category in C12; `RuleLoader`, `RuleEvaluator` (glob expansion, min age, skip if app running, opt-in, needs FDA) | CleanKit |
| 4 | `CleanupPlanner` → `CleanupPlan` (categories → items with id, path, bytes, mtime, reason); `CleanupExecutor` accepts only plan item ids | CleanKit |
| 5 | Command rules: `xcrun simctl delete unavailable`, `brew cleanup --prune=all`, `docker system prune -f` (opt-in), each measured before and run with fixed arguments | CleanKit |
| 6 | `OperationLogging` protocol; SwiftData `OperationRecord` store; export CSV, JSON and Markdown | SafetyKit, App/Persistence |
| 7 | Cleanup screen (categories, disclosure, per-item checkboxes, totals, primary action naming size), result screen, error and no-access states | App/Features/Cleanup |
| 8 | Operation log screen (search, result filter, export) | App/Features/OperationLog |
| 9 | `CoffeePrompt` policy (≥ 2 GB freed, ≥ 30 days since last, never after "Don't ask again") | ReportKit, Cleanup result |

**Acceptance criteria**
- [ ] Tests prove: every protected root and whitelist entry is refused by `PathGuard` in every context, including via symlink and `..`.
- [ ] Executor test: given a plan and a selection, only selected item paths are removed; an item added to the folder after planning is untouched.
- [ ] Each rule in `cleanup-rules.json` has a fixture test showing what it selects and what it never selects.
- [ ] A real cleanup of `~/Library/Developer/Xcode/DerivedData` on this Mac moves items to the Trash and the log shows one row per item.
- [ ] Export writes a CSV whose row count equals the log's.

**Tests:** PathGuard matrix; glob matcher; rule fixtures; planner snapshot on a fixture home; executor safety; coffee policy dates.

### M4 · Health, alerts, onboarding, settings
**Goal:** On launch the dashboard shows the cached Health Score instantly, refreshes it, and each factor links to its fix; alerts fire as notifications; Full Disk Access is detected with guided setup; every setting in C26 works.
**Capabilities:** C1, C2, C3, C7, C26, C27

| # | Task | Files |
|---|---|---|
| 1 | `HealthScore.compute(HealthInputs) -> HealthReport` (factors: disk free 30, memory pressure 20, battery 20, reclaimable 20, startup items 10; reasons; fix routes) and load-line math (85%) | ReportKit |
| 2 | Dashboard (score sentence, LoadLineGauge, factor ledger, summary strip), cached inputs in UserDefaults for instant display | App/Features/Dashboard |
| 3 | `AlertEngine` (thresholds, durations, hysteresis, cool-down) + `Notifier` (UserNotifications, actions open the right screen) | ReportKit, App/Services |
| 4 | `FullDiskAccess.probe()` + Welcome sheet + banners; polling while the sheet is open | App/Features/Onboarding |
| 5 | Settings scene: General (launch at login via `SMAppService.mainApp`, units, appearance), Menu bar, Alerts, Cleanup and safety (Trash vs permanent, whitelist editor with validation, log age), Scan exclusions, Helper, Updates | App/Features/Settings |

**Acceptance criteria**
- [ ] Dashboard shows a score within 3 s of launch (cached path measured with a UI test timestamp).
- [ ] Health score tests cover each factor's bounds and the sentence thresholds (80/60).
- [ ] Setting the disk alert above the current free space produces a notification within one sampling interval (manual check, recorded).
- [ ] With Full Disk Access off, the Welcome sheet appears on first launch and the dashboard shows the banner.

**Tests:** Health score factors; alert engine sequences (enter, sustain, recover, cool-down); settings defaults; FDA probe with injected file access.

### M5 · Apps
**Goal:** A user sees installed apps by size and last use, uninstalls one with all related files after a preview (by button or drag and drop), finds leftovers from deleted apps, gets an offer when an app is trashed, and manages login items and agents.
**Capabilities:** C16, C17, C18, C19, C20

| # | Task | Files |
|---|---|---|
| 1 | `AppInventory` (bundles in /Applications and ~/Applications, name, bundle id, version, team id, size, last used) | AppsKit |
| 2 | `RelatedFileMatcher` (Library locations by bundle id, name and team id prefix; shared vendor folders flagged and unchecked) | AppsKit |
| 3 | `OrphanFinder` (Library entries that look like bundle ids with no installed owner; Apple and system ids excluded) | AppsKit |
| 4 | `TrashWatcher` (FSEvents on ~/.Trash for `.app` bundles) → notification offer | AppsKit, App/Services |
| 5 | `LaunchItemStore` (parse plists in the three launchd folders, owner app, program, schedule, enabled state via `launchctl print-disabled`; enable/disable/remove for user agents; system items through the helper) | AppsKit |
| 6 | Apps, Uninstall preview sheet (running-app guard), Leftovers, Login items screens | App/Features |

**Acceptance criteria**
- [ ] Uninstalling a test app bundle created in a temp Applications folder moves the bundle and its fixture Library files to the Trash and logs each.
- [ ] A running app can't be uninstalled until it is quit (button offered).
- [ ] Orphan finder never lists `com.apple.*` or an installed app's id (tests).
- [ ] Disabling a user LaunchAgent updates `launchctl print-disabled gui/<uid>` (manual check on a test agent).

**Tests:** matcher fixtures (bundle id, name, team id, shared folders); orphan rules; launchd plist parsing; inventory on a fixture folder.

### M6 · Helper and maintenance
**Goal:** A user runs the seven maintenance tasks, each showing its exact command; admin tasks run through the KeelMac helper after a one-time approval; the helper refuses anything outside its allowlist.
**Capabilities:** C21, C22

| # | Task | Files |
|---|---|---|
| 1 | `HelperShared`: `KeelMacHelperProtocol` (`@objc` XPC), `HelperOperation` enum (flushDNS, rebuildSpotlight, runPeriodic, thinSnapshots(bytes), trashSystemPath(path), launchdSystemItem(label, action)), version handshake | HelperShared |
| 2 | `KeelMacHelper` daemon: `NSXPCListener(machServiceName:)`, `setConnectionCodeSigningRequirement` (same team, KeelMac bundle id), runs only enum operations with fixed argument arrays, re-validates paths with SafetyKit | Helper/ |
| 3 | launchd plist in `Contents/Library/LaunchDaemons/mx.cvillegas.keelmac.helper.plist`, helper binary embedded in `Contents/MacOS`; `HelperManager` (register, status, unregister, open Login Items settings) | Config/, App/Services |
| 4 | `MaintenanceTask` catalogue (title, description, exact command string, needsAdmin, runner); user-level runner with live output; admin runner through helper | MaintenanceKit |
| 5 | Maintenance screen (task rows, copy command, run, live output, last run) and helper settings tab | App/Features/Maintenance |

**Acceptance criteria**
- [ ] Unit tests: every `HelperOperation` maps to exactly one fixed executable and argument list; paths outside the allowlist are refused.
- [ ] User-level tasks (Launch Services, font caches, verify disk) run from the app and their output appears live (manual run on this Mac, recorded).
- [ ] Helper registration returns `.requiresApproval` until approved; the UI shows that state with "Open Login Items". Live helper execution is a manual check for Carlos after approval.

**Tests:** operation mapping; code-signing requirement string built from team id; task catalogue invariants (command string equals what runs).

### M7 · Duplicates, snapshots, weekly report
**Goal:** A user finds byte-identical duplicates in chosen folders and trashes extra copies by rule; KeelMac keeps weekly storage snapshots, compares them, and sends a weekly summary that can be exported as Markdown.
**Capabilities:** C23, C24, C25

| # | Task | Files |
|---|---|---|
| 1 | `DuplicateFinder` (size buckets → head/tail 64 KB SHA-256 → full SHA-256, progress, cancellation, skips packages and protected paths) and `AutoSelectRule` (newest, oldest, preferred folder) | DuplicatesKit |
| 2 | `SnapshotTaker` (top folders of home and volume totals, battery capacity), `SnapshotDiff` (what grew), SwiftData store, weekly schedule (`NSBackgroundActivityScheduler`) | ReportKit, App/Persistence |
| 3 | `WeeklyReport` (space change, battery trend, top growth, reclaimable) → notification body + Markdown export | ReportKit |
| 4 | Duplicates and Snapshots screens | App/Features |

**Acceptance criteria**
- [ ] Duplicate tests: same size different content is not a duplicate; three identical files form one group; auto-select always keeps exactly one per group.
- [ ] Diff test: growth sorted by bytes, new and removed folders handled.
- [ ] Markdown export matches a golden file.

**Tests:** as above.

### M8 · Distribution
**Goal:** KeelMac checks for updates via Sparkle against the live appcast; the landing page (EN/ES), release notes and privacy page are live; a tagged release builds, signs, notarizes (when secrets exist), creates a DMG and updates the appcast and cask.
**Capabilities:** C28 (About), C29, C31, C32

| # | Task | Files |
|---|---|---|
| 1 | Sparkle 2.10.0 via SPM, `SPUStandardUpdaterController`, `SUFeedURL`, `SUPublicEDKey`, automatic checks setting, no system profiling | project.yml, App/Services/Updater.swift |
| 2 | EdDSA key generated with Sparkle's `generate_keys` into Carlos's login keychain; public key in Info.plist | Config/ |
| 3 | About window (version, coffee, links, credits) | App/Features/About |
| 4 | Site: landing EN and ES from the artboards, `/releases/`, `/privacy/`, `/appcast.xml`, 404, real screenshots of the app | site/ |
| 5 | `scripts/make_dmg.sh` (hdiutil), `scripts/release.sh` (archive, export, sign, notarize, staple, DMG, `generate_appcast`, cask sha) | scripts/ |
| 6 | `.github/workflows/release.yml` on tags, secrets documented | .github/ |
| 7 | Repo docs final: README with safety model, install, permissions; CONTRIBUTING with "add a cleanup rule" guide; SECURITY | root |

**Acceptance criteria**
- [ ] `curl https://keelmac.<account>.workers.dev/appcast.xml` returns valid RSS with the 1.0.0 item.
- [ ] "Check for updates" in the app reports "You're up to date" against the live feed (manual).
- [ ] `scripts/make_dmg.sh` produces `dist/KeelMac-1.0.0.dmg` that mounts and contains the app and an Applications link.
- [ ] Site check: every page has lang, title, viewport; no broken internal links.

### M9 · Polish
**Goal:** Every screen matches its artboard in light and dark, in English and Spanish; accessibility and performance targets are met; docs are current.

| # | Task |
|---|---|
| 1 | Screenshot every screen at 1280-wide window in light/dark, compare to artboards, fix drift |
| 2 | `make-interfaces-feel-better` and `web-design-guidelines` reviews (site) and fixes; native equivalents applied by hand in SwiftUI |
| 3 | Spanish strings complete (`scripts/strings.mjs` reports 0 missing) |
| 4 | VoiceOver labels on charts, treemap, gauge; keyboard shortcuts ⌘1…⌘9 |
| 5 | Performance: idle CPU, scan time, memory, app size, launch time measured and recorded |
| 6 | Remove one accessory; final slop audit |

## Build results (2026-10-22)
| Check | Result |
|---|---|
| Package tests | 308 passing (SafetyKit 26, MetricsKit 28, ScanKit 28, CleanKit 61, AppsKit 50, MaintenanceKit 66, InsightsKit 46), zero warnings |
| App tests | 9 unit, 5 UI (navigation, live screens, real read-only disk scan, light-mode and Spanish shots) |
| `verify.sh` | passes (slop 0 errors, tokens, strings 562/562 es, build, site check) |
| Full scan of `/` (Data volume, ~850 GB used) | 24–27 s in scanbench; under 60 s through the app UI test; peak 128–134 MB |
| CPU / memory vs system tools | CPU matches `HOST_CPU_LOAD_INFO` within 0.01 pt; memory matches `vm_stat` exactly; battery cycles and condition match System Information, max capacity matches via `system_profiler` |
| Idle CPU, menu bar only, 2 s refresh | ~1.1–1.25 % (target < 1 %). The remaining cost is SwiftUI redrawing the menu bar label every tick; at a 3 s interval it drops below 1 %. Open item. |
| Memory | 59–61 MB footprint idle (target < 80 MB) |
| App size | 19 MB universal (arm64 + x86_64), DMG 6.5 MB |
| First window | under 1 s |
| Live clean acceptance | `KEELMAC_LIVE_CLEAN=1 swift test --filter LiveCleanAcceptance` in CleanKit: of a real 371-item plan, only the planted fixture was trashed; one log entry |
| Not verifiable here | Helper execution (needs a signed build approved in Login Items), notarized release (needs Developer ID), Sparkle against a real update (needs a published release) |

Deviations recorded during the build: `runPeriodic` is unavailable on macOS 27 (the tool was removed) and shows as such; language-file cleanup is limited to unsigned apps because removing `.lproj` from signed apps breaks their signature; the appcast stays empty until the first public release (its 1.0.0 item is written by `scripts/release.sh`).

## Data model
SwiftData models live in the app target (`App/Persistence`); KeelKit talks to them through protocols so packages stay testable without a store.

```swift
// App/Persistence/Models.swift
import SwiftData

@Model final class OperationRecord {
    @Attribute(.unique) var id: UUID
    var date: Date
    var batchID: UUID          // one cleanup run, one uninstall, one task
    var operation: String      // OperationKind.rawValue: cleanup, uninstall, trashFile, duplicates, leftovers, maintenance, loginItem
    var title: String          // "Uninstall Zoom", "Cleanup"
    var path: String           // path or exact command
    var bytes: Int64           // 0 when not applicable
    var result: String         // OperationResult.rawValue: trashed, deleted, ran, disabled, enabled, removed, skipped, failed, refused
    var reason: String?        // skip/fail/refuse reason, exit code
    init(...)
}

@Model final class StorageSnapshot {
    @Attribute(.unique) var id: UUID
    var date: Date
    var volumeTotal: Int64
    var volumeUsed: Int64
    var batteryMaxCapacity: Double?
    var reclaimableBytes: Int64
    @Relationship(deleteRule: .cascade, inverse: \SnapshotEntry.snapshot) var entries: [SnapshotEntry]
}

@Model final class SnapshotEntry {
    var path: String
    var bytes: Int64
    var snapshot: StorageSnapshot?
}
```
Store: `~/Library/Application Support/KeelMac/KeelMac.store`. Retention: operation log keeps 1 year (pruned at launch), snapshots keep 52.

KeelKit protocols:
```swift
public protocol OperationLogging: Sendable { func record(_ entries: [OperationEntry]) async }
public protocol SnapshotStoring: Sendable { func save(_ s: StorageSnapshotValue) async throws; func all() async throws -> [StorageSnapshotValue] }
```

Cleanup rules (`Packages/KeelKit/Sources/CleanKit/Resources/cleanup-rules.json`, schema v1):
```json
{ "schemaVersion": 1, "rules": [ {
  "id": "xcode-derived-data", "category": "developer",
  "title": {"en": "Xcode DerivedData", "es": "DerivedData de Xcode"},
  "detail": {"en": "Build products Xcode recreates.", "es": "Productos de compilación que Xcode vuelve a crear."},
  "kind": "paths", "paths": ["~/Library/Developer/Xcode/DerivedData/*"], "exclude": [],
  "minAgeDays": 0, "optIn": false, "needsAdmin": false, "needsFullDiskAccess": false,
  "skipIfRunning": [], "keepNewest": 0
} ] }
```
`kind: "command"` rules add `"command": {"executable": "/usr/bin/xcrun", "arguments": ["simctl","delete","unavailable"]}` and `"measure": {"paths": [...]}`.

## Interfaces (in place of an API route table)
| Boundary | Name | Caller | Purpose |
|---|---|---|---|
| XPC Mach service | `mx.cvillegas.keelmac.helper` | KeelMac.app (code-signing requirement checked by helper) | admin-only operations |
| URL scheme | `keelmac://open/<route>` | notifications, menu bar | open a screen (dashboard, cleanup, apps, leftovers?bundle=, storage) |
| Sparkle feed | `https://keelmac.<account>.workers.dev/appcast.xml` | Sparkle | update check (only network call) |
| Site | `/`, `/es/`, `/releases/`, `/privacy/`, `/es/privacy/` | visitors | landing |

## Env and secrets
| Name | Kind | Local | Production | Provided by |
|---|---|---|---|---|
| DEVELOPMENT_TEAM (735MC85596) | build setting | Config/Shared.xcconfig | same | Carlos's Apple team (found in keychain) |
| SUPublicEDKey | Info.plist | Config/Info-App.plist | same | generated at M8 (public) |
| Sparkle EdDSA private key | secret | login keychain (Sparkle `generate_keys`) | GitHub secret `SPARKLE_PRIVATE_KEY` | Carlos exports from keychain |
| DEVELOPER_ID_P12 / _PASSWORD | secret | — | GitHub secrets | Carlos (Developer ID Application certificate) |
| NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_PASSWORD | secret | — | GitHub secrets | Carlos (app-specific password) |
| CLOUDFLARE_API_TOKEN | secret | wrangler OAuth login | GitHub secret (for site deploy from release workflow) | Carlos |

No secret is committed; `.gitignore` covers key and certificate files.

## Webhooks
None (no server).

## Entitlements
| Plan | Limits | Features | Enforced in |
|---|---|---|---|
| Free | none | everything | — |

App entitlements: Hardened Runtime on; no App Sandbox (deep cleaning, per spec); `com.apple.security.cs.disable-library-validation` off. Helper: Hardened Runtime.

## Test plan
- `swift test` in `Packages/KeelKit`: SafetyKit matrix, rules fixtures, planner/executor, metrics math, scanner fixtures, layouts, matchers, duplicates, health, alerts, reports. Fixtures are built in temp directories; no test touches the real home folder.
- `xcodebuild test` for the app: unit tests for view-model glue and one XCUITest per milestone with UI (launch with `-uitest` to use an in-memory store and fixture data provider).
- `scripts/mac.sh lint`: `swift format lint --strict` on sources, `tokens.mjs --check`, `strings.mjs --check` (no missing es), slop check via verify.sh.
- `verify.sh` runs lint → test → build (+ e2e with `E2E=1`).
- Manual acceptance (recorded in the status log): Activity Monitor comparison, battery vs System Information, scan timing, idle CPU, real DerivedData cleanup, maintenance run, update check.

## Deploy plan
- **App:** `bash scripts/mac.sh build` (Release, Apple Development signing, universal), copy to `dist/KeelMac.app`, `scripts/make_dmg.sh` → `dist/KeelMac-1.0.0.dmg`. Run it on this Mac and smoke-test.
- **Site:** `cd site && npx wrangler deploy` → `keelmac.<account>.workers.dev`. Smoke: `/`, `/es/`, `/releases/`, `/privacy/`, `/appcast.xml` return 200.
- **Repo:** private GitHub repo `DarthQach/keelmac`, push `main`, CI runs.
- **Release (Carlos's step when ready):** add secrets, tag `v1.0.0`, release workflow notarizes and publishes; flip the repo public.

## Rollback
- Site: `wrangler rollback` to the previous version.
- App: Sparkle only offers versions in the appcast; remove a bad item from `appcast.xml` and redeploy the site; users keep their current version.
- Data: the SwiftData store is local; a schema change ships a lightweight migration; the operation log is exportable before upgrading.

## Risks
- **Deleting the wrong file.** Mitigation: PathGuard tests, plan-only executor, Trash-first, changed-since-preview check, rules fixtures; nothing in tests touches real user data.
- **Helper can't be fully exercised without approval.** Mitigation: allowlist unit tests, user-level tasks work without it, documented manual check.
- **Undocumented IOHID temperature API.** Mitigation: dlsym with graceful "Unavailable", battery temperature fallback.
- **Scan speed on 500 GB.** Mitigation: `getattrlistbulk` + parallel subtrees; measured at M2.
- **Swift 6 strict concurrency with C APIs.** Mitigation: readers are `Sendable` structs returning value types; one `@MainActor` monitor.

## Coverage
| Capability | Milestone(s) |
|---|---|
| C1 | M4 |
| C2 | M4 |
| C3 | M1, M4 |
| C4 | M1 |
| C5 | M1 |
| C6 | M1 |
| C7 | M4 |
| C8 | M2 |
| C9 | M2 |
| C10 | M2 |
| C11 | M2 |
| C12 | M3 |
| C13 | M3 |
| C14 | M3 |
| C15 | M3 |
| C16 | M5 |
| C17 | M5 |
| C18 | M5 |
| C19 | M5 |
| C20 | M5 |
| C21 | M6 |
| C22 | M6 |
| C23 | M7 |
| C24 | M7 |
| C25 | M7 |
| C26 | M4 |
| C27 | M4 |
| C28 | M3, M8 |
| C29 | M8 |
| C30 | M0, M9 |
| C31 | M0, M8 |
| C32 | M0, M8 |

## Access checklist
- [x] Xcode 27.1, Swift 6.4, macOS 27 SDK (`xcodebuild -version`).
- [x] XcodeGen installed (`/opt/homebrew/bin/xcodegen`).
- [x] Signing: "Apple Development: CARLOS VILLEGAS FROLA", team 735MC85596 (keychain).
- [ ] Developer ID Application certificate + notary credentials: not present. Not needed for the build; needed for the first public notarized release (Carlos's step).
- [x] `npx wrangler whoami` → Cvillegasfrola@gmail.com's Account (036c0bdf…). Static assets only, Workers Free is enough.
- [x] `gh auth status` → DarthQach; repo name `keelmac` is free. Visibility: private until Carlos flips it.
- [ ] Buy Me a Coffee handle `keelmac`: Carlos claims it (or changes the constant).
- [ ] Clerk / Stripe / AWS: not used.
