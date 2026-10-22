# Design · KeelMac

> Canvas: https://claude.ai/artifact/RN1YhHXALokVCwBXWtDd29 (24 artboards, rows Marketing, Core, Storage, Cleanup and history, Apps and maintenance, Settings and support) · Artboards in repo: `design/canvas/` · Tokens: `design/tokens.css` (mirrored to the asset catalog by `scripts/tokens.mjs`)

## Direction
**Looks like** a ship's load-line mark and a well-kept engine-room log, **not like** a neon "Mac optimizer" with a giant round Scan button, purple gradients and red scare warnings.
**The one bold thing:** the **load line**. Disk usage is drawn as a hull's waterline: verdigris water fills the hull as space is used, and a hull-ink Plimsoll mark (a ring crossed by a line) sits at the safe-load point (85% used, the free space macOS needs for updates, swap and snapshots). "38 GB above the load line" is the headline sentence of the dashboard and of the landing page. Everything else stays quiet and native.

Neutral: **sailcloth**, a barely warm grey (hue 70–85, chroma ≤ 0.014) that sits next to macOS's own window greys without looking like a template cream; it is the light theme only. Dark mode uses **neutral black** (chroma 0: black window, near-black surfaces, white text) so it never reads as brown. Accent: **verdigris** (hue 185), the patina on a ship's bronze fittings: calm, maritime, and far from both the semantic green (moved to 145) and the AI-default blues and purples. In the app the type is **SF Pro** (system, because the spec asks for a native macOS look) with **SF Mono** only for paths and the exact commands maintenance tasks run. The landing page uses **Public Sans**: plain-spoken and trustworthy, matching the "honest, no scare tactics" principle. Icons: **SF Symbols** in the app (hierarchical rendering, regular weight next to body text); the landing page uses no icon set, only the load-line mark and real app screens. Radius: macOS-native, 6px controls, 10px groups, 12px windows, concentric when nested. Voice: calm, specific, numbers first; never "danger", "infected" or "junk is slowing your Mac".

### Critique of the first idea (frontend-design pass)
- A warm sailcloth background close to `#F4F1EA` would read as default look #1 (cream). Revised to L 0.982, chroma 0.004: warmth you feel next to cool system greys, not cream. No serif anywhere.
- A big Health Score ring is the category default (CleanMyMac, every "optimizer") and a decorative progress ring. Revised: the score is a sentence ("Your Mac is in good shape. 82 of 100.") followed by a ledger of factors, each with its reason and fix. The load line carries the visual weight instead.
- A giant central "Scan" button is the optimizer cliché. Revised: KeelMac reads cached state at launch and shows results immediately; scans are ordinary toolbar buttons.
- Red for "junk found" is scare marketing. Revised: reclaimable space is neutral information in fg/accent; danger red appears only for real failures and destructive confirmations.
- "Developer tool" usually means mono everywhere or terminal cosplay. Revised: mono only where the content is a path or a command.

## Surfaces and dials
| Surface | Screens | Variance | Motion | Density | What that means here |
|---|---|---|---|---|---|
| Persuade | landing (EN/ES), release notes, privacy | 5 | 3 | 3 | Left-aligned hero with the real dashboard window offset to the right and bleeding off the edge (one asymmetric moment); one entrance: the water rises to its level in the hero gauge once (cross-fade under reduced motion); generous 96px section spacing |
| Operate | app windows, menu bar popover, notifications | 2 | 2 | 6 | Native `NavigationSplitView`, strictly aligned; motion only for state changes (treemap zoom, row removal after cleanup); compact 28–32px table rows, 1px dividers instead of cards, tabular numerals everywhere |

`Persuade V5 M3 D3 · Operate V2 M2 D6`

Palette history checked: differs from PaceProphet (blue 250, graphite, SF Pro) in hue and neutral; from Promptusphere redesign (pink, cool near-black, Archivo) in hue, neutral and font; from HumanyzeAI (petrol 205, cool slack water, Figtree) in neutral and font (verdigris 185 is within 30° of petrol 205, so hue is not counted as different there).

## Wireframes
Landing hero (1280):
```
┌──────────────────────────────────────────────────────────────────────────────┐
│ ◯— KeelMac                                  Safety  FAQ  GitHub  [Download] │
│                                                                              │
│  Keep your Mac above the load line.          ┌───────────────────────────────┤
│                                              │ ● ● ●  KeelMac               │
│  See what fills your disk, clean what's      │ ┌sidebar┐ Your Mac is in good│
│  safe to clean, and know exactly what        │ │Dashbd │ shape. 82 of 100.  │
│  happened. Free and open source.             │ │Monitor│ ▁▁▁▁▁▁▁▁▁◯—▁▁▁▁▁▁▁ │
│                                              │ │Storage│ ████████░░│░░░░░░  │
│  [Download for macOS]  brew install --cask   │ │Cleanup│ 38 GB above the    │
│                        keelmac  (copy)       │ │Apps   │ load line          │
│                                              │ │…      │ Factors ledger …   │
│  macOS 14 or later · Apple silicon and Intel │ └───────┘                    │
│                                              └───────────────────────────────┤
└──────────────────────────────────────────────────────────────────────────────┘
```
Then: "What it does" (four short rows, each a real cropped screen: Storage map, Cleanup preview, Menu bar, Maintenance with command), "Safety model" (the five rules as a plain list beside the operation log screen), "Free, really" (open source, no account, no telemetry, Buy Me a Coffee), FAQ, footer.

Dashboard window (1280 × 800):
```
┌───────────────┬─────────────────────────────────────────────────────────────┐
│ ● ● ●         │ Dashboard                          [Refresh]  Updated 2 min │
│ Overview      │                                                             │
│  ▸ Dashboard  │ Your Mac is in good shape.  82 of 100                       │
│    Monitor    │                                                             │
│ Storage       │ Macintosh HD          412 GB used of 494 GB                 │
│    Storage map│ ██████████████████████████░░░░│░░░░░  38 GB above the line  │
│    Large & old│                              ◯—  load line (85%)           │
│    System Data│ ─────────────────────────────────────────────────────────── │
│    Duplicates │ Factor              Score  Why                       Fix    │
│    Snapshots  │ Disk free            22/30 82 GB free, 38 GB over line  Open│
│ Clean         │ Memory pressure      20/20 Normal for the last hour     ·   │
│    Cleanup    │ Battery health       14/20 88% capacity, 412 cycles     View│
│    Apps       │ Reclaimable space    16/20 12.4 GB in developer caches Review│
│    Leftovers  │ Startup items        10/10 6 login items, all known     ·   │
│    Login items│ ─────────────────────────────────────────────────────────── │
│    Maintenance│ CPU 7%  │ Memory 18.2 of 36 GB │ Battery 76% │ Up 3 d 4 h   │
│ History       │ macOS 27.0  │ Apple M3 Pro                                  │
│    Op. log    │                                                             │
│ [FDA status]  │                                                             │
└───────────────┴─────────────────────────────────────────────────────────────┘
```

## Tokens summary
| Token | Light | Dark | Use |
|---|---|---|---|
| --accent (verdigris) | oklch(0.49 0.09 185) | oklch(0.74 0.095 185) | primary actions, selection, focus, links |
| --water / --water-edge | oklch(0.84 0.05 190) / accent | oklch(0.43 0.06 190) / accent | used space in the load-line gauge and treemap selection |
| --hull-ink | oklch(0.23 0.014 70) | oklch(1 0 0) | the Plimsoll mark |
| --bg / --surface | oklch(0.982 0.004 85) / oklch(0.997 0.002 85) | oklch(0 0 0) / oklch(0.16 0 0) | window / grouped content |
| --fg / --fg-muted | oklch(0.23 0.014 70) / oklch(0.49 0.014 70) | oklch(1 0 0) / oklch(0.76 0 0) | text |
| --success / --warning / --danger | 145 / 65 / 27 | 145 / 75 / 25 | status only, always with a word or symbol |

Contrast check: passed 2026-10-22 (62 pairs, including the gauge, banner and sidebar pairs in `design/contrast-pairs.json`).

## Type
- App: SF Pro via system text styles (`.largeTitle` for the score sentence, `.title2` section titles, `.body` 13pt macOS body, `.callout`/`.footnote` secondary). Weights 400 and 600. `monospacedDigit()` on every number. SF Mono (`.monospaced()`) only for paths and commands.
- Landing: Public Sans (self-hosted variable woff2), hero 3rem/1.1 weight 650 with −0.02em tracking, body 1.0625rem/1.6, max 64ch.

## Layout
- Main window: `NavigationSplitView`, sidebar 220pt with sections Overview, Storage, Clean, History; detail area max content width 1100pt, 24pt padding. Minimum window 960 × 640.
- Settings: separate `Settings` scene with tabs General, Menu bar, Alerts, Cleanup & safety, Helper, Updates.
- Menu bar popover: 340pt wide, sections stacked: readouts row, 60-minute mini chart (CPU/memory toggle), top 5 processes (CPU | Memory segmented), battery line, footer (Open KeelMac, Settings…, Quit).
- Landing: max width 1200px, 24px gutters, collapses to one column below 768px; hero screenshot moves below the text.

## Components
SwiftUI native: `Table` (sortable, multi-select), `List` with `DisclosureGroup` for cleanup categories, `Toggle` checkboxes per item, `ProgressView` (linear for scans), `Charts` `LineMark`/`AreaMark` for mini charts, `.confirmationDialog` for destructive confirmations, `.alert` only for errors that block. Custom: `LoadLineGauge` (Canvas), `TreemapView` and `SunburstView` (Canvas with hit testing), `CommandLabel` (mono command with Copy button), `StatusBadge` (symbol + word + semantic colour), `EmptyStateView`, `PermissionBanner` (FDA / helper), `ByteText` (formatted bytes, tabular).

## Screens
| # | Screen | Route | Role | Capabilities | Primary action |
|---|---|---|---|---|---|
| S1 | Welcome and Full Disk Access | first launch sheet | Owner | C27 | Open Privacy & Security |
| S2 | Dashboard | sidebar › Dashboard | Owner | C1, C2, C3 | Fix the top factor (contextual) |
| S3 | Monitor | sidebar › Monitor | Owner | C5, C6 | Quit process (per row) |
| S4 | Menu bar popover | menu bar | Owner | C4, C5, C6 | Open KeelMac |
| S5 | Storage map | sidebar › Storage map | Owner | C8, C11 | Scan disk / Rescan |
| S6 | Large & old files | sidebar › Large & old | Owner | C9, C11 | Move to Trash (selected) |
| S7 | System Data | sidebar › System Data | Owner | C10, C11 | Reveal in Finder |
| S8 | Cleanup review | sidebar › Cleanup | Owner | C12, C13, C14 | Move 12.4 GB to Trash |
| S9 | Cleanup result | after S8 | Owner | C13, C15, C28 | Done (secondary: View log) |
| S10 | Operation log | sidebar › Operation log | Owner | C15 | Export log… |
| S11 | Apps | sidebar › Apps | Owner | C16, C18, C20 | Uninstall… |
| S12 | Uninstall preview | sheet from S11 / drop | Owner | C16, C14 | Move 1.3 GB to Trash |
| S13 | Leftovers | sidebar › Leftovers | Owner | C17 | Move to Trash (selected) |
| S14 | Login items | sidebar › Login items | Owner/Admin | C19, C22 | Disable (per row) |
| S15 | Maintenance | sidebar › Maintenance | Owner/Admin | C21, C22 | Run (per task) |
| S16 | Duplicates | sidebar › Duplicates | Owner | C23 | Move duplicates to Trash |
| S17 | Snapshots | sidebar › Snapshots | Owner | C24, C25 | Take snapshot / Export report… |
| S18 | Settings | ⌘, | Owner | C7, C14, C22, C26, C29 | (immediate apply) |
| S19 | About | KeelMac › About | Owner | C28, C29, C31 | Buy me a coffee |
| S20 | Notifications | macOS Notification Center | Owner | C7, C18, C25 | Open (notification action) |
| L1 | Landing (EN, ES) | / , /es/ | Visitor | C32, C28 | Download for macOS |
| L2 | Release notes | /releases/ | Visitor | C29 | Download |
| L3 | Privacy | /privacy/ | Visitor | C32 | — |

## Coverage
| Capability | Screen(s) |
|---|---|
| C1 | S2 |
| C2 | S2 |
| C3 | S2 |
| C4 | S4, S18 |
| C5 | S3, S4 |
| C6 | S3, S4 |
| C7 | S18, S20 |
| C8 | S5 |
| C9 | S6 |
| C10 | S7 |
| C11 | S5, S6, S7 |
| C12 | S8 |
| C13 | S8, S9 |
| C14 | S8, S12, S18 |
| C15 | S9, S10 |
| C16 | S11, S12 |
| C17 | S13 |
| C18 | S11, S20 |
| C19 | S14 |
| C20 | S11 |
| C21 | S15 |
| C22 | S14, S15, S18 |
| C23 | S16 |
| C24 | S17 |
| C25 | S17, S20 |
| C26 | S18 |
| C27 | S1, S2 (banner) |
| C28 | S9, S19, L1 |
| C29 | S18, S19, L2 |
| C30 | all (EN/ES, light/dark, VoiceOver) |
| C31 | repo (no screen), L1 links |
| C32 | L1, L3 |

## State matrix
"No permission" means missing Full Disk Access or an unapproved helper. There are no plans, so "over limit" doesn't apply (n/a).

| Screen | Empty | Loading | Error | Success | No permission | Over limit |
|---|---|---|---|---|---|---|
| S2 Dashboard | First launch: cached nothing yet, shows live metrics + "Run your first scan to score reclaimable space" | Cached values shown immediately, factor rows refresh in place | Factor shows "Couldn't read" + Retry | Score sentence + ledger | FDA banner; reclaimable factor marked "Partial" | n/a |
| S3 Monitor | — (always data) | First sample within 1 s, charts fill from the left | Temperature "Unavailable on this Mac" | Live | Other users' processes shown without Quit | n/a |
| S4 Popover | — | "Measuring…" for the first sample | Readout shows "–" | Live | — | n/a |
| S5 Storage map | "Scan Macintosh HD to see what fills it" + Scan disk | Linear progress, files counted, current folder, Cancel | "Scan stopped: …" + Retry; unreadable folders listed | Treemap/sunburst + breadcrumb | Banner: N folders skipped without Full Disk Access | n/a |
| S6 Large & old | "No files over 500 MB opened more than 3 months ago" | Uses scan; if none: "Scan first" | as S5 | Table | as S5 | n/a |
| S7 System Data | "Scan to break down System Data" | Rows appear as measured | Row "Couldn't measure" with reason | Table with sizes | Rows needing FDA marked | n/a |
| S8 Cleanup | "Nothing to clean right now. Last checked 2 min ago." | Category rows measure one by one with spinners | Category "Couldn't read" + reason | Category list with totals, items, exclusions | Categories needing FDA show "Needs Full Disk Access" and are unchecked | n/a |
| S9 Result | — | Progress "Moving 214 items to Trash…" | Per-item failures listed with reason; summary counts | "Moved 12.4 GB to Trash" + skipped list | — | n/a |
| S10 Op log | "No operations yet. Everything KeelMac moves or deletes is listed here." | Skeleton rows | "Couldn't open the log" + Retry | Table | — | n/a |
| S11 Apps | "No apps found in /Applications" (rare) | Sizes measure in place | Row size "–" | Table + drop zone | — | n/a |
| S12 Uninstall preview | "Only the app bundle was found" | Matching related files… | Item can't be moved: reason | List with checkboxes | App is running: "Quit Xcode to uninstall it" + Quit | n/a |
| S13 Leftovers | "No leftovers from deleted apps" | Searching Library… | as S8 | Table grouped by bundle id | FDA banner | n/a |
| S14 Login items | "No login items or background agents" | Reading launchd… | Toggle failed: reason | Table | System items: "Needs the KeelMac helper" + Install helper | n/a |
| S15 Maintenance | — (catalogue) | Task row shows progress + live output | Exit code and last output lines | "Finished in 3 s" + output | Admin tasks: "Needs the KeelMac helper" + Install helper | n/a |
| S16 Duplicates | "Choose folders to search" / "No duplicates found in ~/Documents" | Stages: grouping by size, hashing (n of m) | Unreadable files listed | Groups with auto-select | FDA banner | n/a |
| S17 Snapshots | "No snapshots yet. KeelMac takes one every week." + Take snapshot | Taking snapshot… | Couldn't save snapshot + Retry | Snapshot list + "What grew" comparison | — | n/a |
| S18 Settings | — | — | Inline validation (e.g. whitelist path doesn't exist) | Applied instantly | Helper status row | n/a |
| S1 Welcome | — | Checking access… (probe) | — | "Full Disk Access is on" check | Steps + Open Privacy & Security | n/a |

## Microcopy
Voice: calm, specific, numbers first, second person, sentence case, no exclamation marks except the one coffee prompt the spec writes. Never "danger", "threat", "infected", "boost", "junk is slowing you down".
- Score sentence: "Your Mac is in good shape." (≥ 80) · "Your Mac could use some room." (60–79) · "Your Mac needs attention." (< 60), then "82 of 100".
- Load line: "38 GB above the load line" / "6 GB below the load line. macOS needs free space for updates and swap."
- Cleanup primary: **Move 12.4 GB to Trash** (permanent mode: **Delete 12.4 GB permanently**, danger solid, confirmation names the size and count).
- Result: "Moved 12.4 GB to Trash. 3 items were skipped." · Skip reasons: "In use by Xcode", "Whitelisted", "Protected system location", "Changed since preview".
- Coffee prompt: "Freed 14 GB. Buy me a coffee?" with **Buy me a coffee** and **Not now**, plus "Don't ask again".
- FDA: "KeelMac needs Full Disk Access to see caches, mail attachments and other protected folders. It never reads file contents except to find duplicates."
- Helper: "Some tasks need administrator rights. KeelMac installs a small helper that can only run the tasks listed here."
- Errors: "Couldn't read ~/Library/Caches/com.spotify.client. Permission denied." (path in mono)
- Empty states as in the state matrix.
- Spanish (es) mirrors every string; numbers and bytes formatted with the user's locale (`ByteCountFormatter`, `Measurement`).

## Accessibility notes
- Every chart and the treemap/sunburst expose an accessibility representation (the top 10 items as a list with sizes).
- Load line gauge has an accessibility label: "412 GB used of 494 GB, 38 GB above the load line".
- Status always symbol + word + colour.
- Full keyboard navigation: sidebar (⌘1…⌘9), tables (arrow keys, space to toggle, ⌘⌫ Move to Trash with confirmation), treemap (arrow keys move selection, Return drills in, Esc goes up).
- Respect Reduce Motion: treemap zoom becomes a cross-fade.

## Slop audit
- slop_check on canvas (2026-10-22): **0 errors, 8 warnings**, each intentional:
  - `side-tab` ×4 (Dashboard, Dashboard-Dark, Main, Landing-Phone): the 2px verdigris right edge is the waterline of the load-line gauge, not a card border.
  - `shadow-and-border` ×4 (About notifications, Storage-Map selected tile, Uninstall sheet and note): the shadows are `0 0 0 1px` rings or an inset selection ring, used instead of a border, not stacked on one.
- anti-slop.md §10 checklist: clean.
  - Not guessable from the category: no scan button, no score ring, no purple, no scare red; direction line names what it isn't.
  - No §2 tells, none of the §3 default looks. Hero opens with the real dashboard and its load line, left-aligned with the window bleeding off the right edge.
  - One bold thing (the load line); accessory removed: the per-row icons in the cleanup list and decorative category colours in the treemap (all water tints of one hue).
  - Fonts: SF Pro (app), Public Sans (site, not on the avoid list). Palette differs from the last three apps (see Surfaces and dials).
  - One accent per view; no gradients or glows. Icons: SF Symbols in the app, inline stroke SVG only for the load-line mark and app icon on the site; no emoji, no Unicode arrows (one "↓" replaced by "In").
  - Copy: no hype words, no placeholder names, no em dashes in UI copy, CTAs name the action and size ("Move 40.1 GB to Trash").
  - Dials match: Operate screens are dense tables with 1px dividers; Persuade has one entrance (water rising once).
- Revisions made: Large-Old dropped a row that contradicted its own filter; Storage-Map treemap label fixed; banner colours promoted to tokens (`--warning-soft`, `--warning-ink`) and `--sidebar` added so every artboard colour is a token.

## App icon
Hull-ink rounded square, verdigris water across the lower third, the Plimsoll mark (ring and line) in sailcloth white on the waterline (About artboard).
