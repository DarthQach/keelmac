# AGENTS.md · KeelMac

Read this before changing code. Source-of-truth documents live in `docs/forge/` (brief, stack, design, plan, module contracts). If code and docs disagree, fix the doc first, then the code.

## Layout
- `App/` SwiftUI app. `KeelMacApp.swift` (scenes: main `Window`, `Settings`, `MenuBarExtra`), `AppModel.swift` (root @Observable state), `Route.swift` (sidebar destinations), `Features/<Screen>/`, `DesignSystem/` (Theme colours from the asset catalog, components), `Services/`, `Persistence/` (SwiftData models).
- `Helper/` the privileged helper daemon target (`KeelMacHelper`), embedded in `Contents/MacOS`, launchd plist in `Contents/Library/LaunchDaemons`.
- `Packages/<Kit>/` one Swift package per module group; public APIs listed in `docs/forge/contracts.md`.
- `design/` tokens (`tokens.css` is the only colour source), contrast pairs, Claude Design artboards in `design/canvas/`.
- `site/` landing page generator (`build.mjs`), static output in `site/public`, Sparkle `appcast.xml`.
- `scripts/` `mac.sh` (lint/test/build/e2e/run/release-build), `tokens.mjs`, `strings.mjs`, `make_icon.swift`, `shots.sh`, release scripts.

## Commands
| Task | Command |
|---|---|
| Run the app | `bash scripts/mac.sh run` |
| All checks | `bash ~/.claude/skills/app-forge/scripts/verify.sh` (lint → test → build) |
| Package tests | `cd Packages/<Kit> && swift test` |
| UI tests + screenshots | `bash scripts/shots.sh` → `build/shots/*.png` |
| Regenerate colours | `node scripts/tokens.mjs --write` |
| Update the string catalog | build, then `node scripts/strings.mjs --write` |
| Deploy the site | `cd site && node build.mjs && node check.mjs && npx wrangler deploy` |

## Conventions
- Every removal goes through `SafetyKit.SafeRemover` with the right `PathContext`; every external command through `CommandRunning` (absolute executable + argument array, never a shell string).
- Packages return values; the app localizes. Every user-facing string in `App/` needs an `es` entry in `App/Resources/translations.es.json`.
- Only token colours (`.kmFg`, `.kmAccent`…), SF Symbols, system text styles; numbers use `.monospacedDigit()`.
- Every screen ships with its empty, loading and error states (see the state matrix in `docs/forge/03-design.md`).
- Tests never touch the real home folder, Trash, launchd or the network: use fixtures in temp dirs, `SafeRemover.trasher` injection and `RecordingCommandRunner`.
- Commits: conventional (`feat(Mx): …`). Never commit secrets or signing material.

## Gotchas
- macOS restores the main window's closed state between launches (same bundle ID for Debug and Release). The menu bar label opens the window on launch unless `-menuBarOnly` is passed; use `-menuBarOnly` only to measure idle cost.
- UI test screenshots show real data from this Mac (usernames, apps, processes). Review them before publishing anything to the site.
- Detailed metrics (processes, per-tick temperature) run only while a view using `.detailedMetrics(_:)` is in a visible window.
- Live, opt-in package tests: `KEELMAC_LIVE=1` (CleanKit, AppsKit read-only), `KEELMAC_LIVE_CLEAN=1` (CleanKit, trashes only a planted fixture).
- `URL.resolvingSymlinksInPath()` strips `/private` from `/private/var/...`; compare paths through `PathGuard.canonical`.
- Window screenshots need Screen Recording permission for the shell; use `scripts/shots.sh` (UI test attachments) instead.
- The helper only works in a signed build after the user approves it in System Settings › General › Login Items.
