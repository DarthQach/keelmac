# Design · KeelMac

> Current app references: `design/canvas/` (native fixture captures, regenerated with `scripts/revamp-shots.sh`). The original hosted canvas is historical. Marketing artboards are unchanged. Tokens: `design/tokens.css`, mirrored to the asset catalog by `scripts/tokens.mjs`.

## Direction · refined native (2026-10-22)

The entire app is a refined native Mac utility: comfortable lists, strong information hierarchy, informative dashboards and consistent secondary windows. Keep all capabilities, routes, commands, safety previews and scoring. The website is outside this revamp.

SF system typography and SF Symbols; teal is a restrained signature for primary actions and selection. Inactive icons are neutral. Native segmented chart controls use a deeper teal token because macOS draws their selected labels in white. Near-white background/white panels in light mode; charcoal background/lighter neutral panels in dark mode. The nautical load line remains an accurate secondary storage cue at 85%, while available space leads the storage panel.

## Layout and components

- Spacing: 8, 12, 16, 24, 32 pt; page gutters 24, panels 20, panel gaps 16; panel radius 12. Subtle borders and minimal elevation.
- Primary information uses body text, headings system title styles, metric values large titles and tabular digits. Paths/commands alone use monospace. Supporting text remains readable in both appearances.
- Rows: minimum 40 pt for one line, 56 pt for name + detail; allow growth for localization/accessibility. No density toggle.
- Native NavigationSplitView retains sections, routes, shortcuts, selection and deep links. Standard page headers introduce each workspace; toolbar actions stay native.
- Shared panels, filter/summary strips, row identity labels, status badges, notices and adaptive action bars enforce consistent hierarchy.
- 960 × 640 minimum, 1180 × 780 default. Metrics use two columns when narrow and four when wide. Supporting panels stack when space is limited. The Assistant (S21) is a resizable 300–480 pt trailing panel on every route (toolbar sparkles, ⌘⇧A), below the window toolbar so each screen's toolbar controls stay a window-level band; it sits on `surface-muted` behind a full-height 1 pt divider, and screens keep their own side panels. Tables retain native scrolling, selection and sorting with meaningful minimum column widths.
- Permission and error notices wrap; persistent removal bars keep totals, consequences and actions readable. Empty/loading/success states use the same typography, spacing and panel treatment. Cleanup’s summary explicitly identifies selections containing permanent removals, using the existing `selectionDeletesPermanently` value.
- English and Spanish, light/dark, VoiceOver, keyboard navigation and Reduce Motion remain supported. No new data sampling, package APIs, storage schemas or helper protocols.

## Screen compositions

- Dashboard: health summary and score; storage panel led by free capacity; four metric tiles; health-factor breakdown with every score, reason, measurement state and existing fix action.
- Monitor: four independent chart panels with units/time context, process table and battery/system panel. Existing history and visibility-based sampling only.
- Cleanup: overall/selected summary above category/detail workspace, comfortable category rows, distinct rule headers, item name over location, trailing sizes. Preserve tri-state selection, disclosures, unavailable reasons and confirmation behavior.
- Apps: comfortable native table with a focused selected-app inspector and secondary drop target. Uninstall preview retains all selectable files and running-app checks.
- Storage map: synchronized two-level map and contents list, breadcrumb/Up navigation, fixed hover preview and selection details. App-level geometry and hit testing share one presentation model; scanning and removal policy stay unchanged. Large files keep owner, locks, location and filters.
- Other lists: consistent table headers and row rhythm; distinct duplicate groups; aligned snapshot comparison values; clear System Data size bars; operation log result labels remain explicit.
- Maintenance: separate task panels containing description, exact command, helper status and output. Settings, Welcome, About, results and menu bar use the same visual vocabulary. Settings uses native grouped tabs on macOS 15+, with the default tab style on macOS 14; all seven sections remain visible at the intended 700 pt width.

## Verification

Use isolated presentation fixtures and an in-memory store for screenshot automation; never operate on real files, launchd or the network. Inspect every route and secondary surface in both appearances and both languages; representative screens at minimum/default/wide sizes. Run lint, package/app tests, build, localization and contrast checks. Capture local reference screenshots; do not publish personal data or modify the website.

## Screens
| # | Screen | Route | Role | Capabilities | Primary action |
|---|---|---|---|---|---|
| S1 | Welcome and Full Disk Access | first launch sheet | Owner | C27 | Open Privacy & Security |
| S2 | Dashboard | sidebar › Dashboard | Owner | C1, C2, C3 | Fix the top factor (contextual) |
| S3 | Monitor | sidebar › Monitor | Owner | C5, C6 | Quit process (per row) |
| S4 | Menu bar popover | menu bar | Owner | C4, C5, C6 | Open KeelMac |
| S5 | Storage map | sidebar › Storage map | Owner | C8, C11 | Scan disk / Rescan |
| S6 | Review large files (per-kind totals, owner app and in-use status; AI models one row per model; a running owner locks its rows) | sidebar › Review large files | Owner | C9, C11 | Move to Trash / Remove model (selected) |
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
| S21 | Assistant panel | toolbar sparkles / ⌘⇧A, resizable trailing panel on every route | Owner | C33 | Send |
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
| C33 | S21, S18 |

## State matrix
"No permission" means missing Full Disk Access or an unapproved helper. There are no plans, so "over limit" doesn't apply (n/a).

| Screen | Empty | Loading | Error | Success | No permission | Over limit |
|---|---|---|---|---|---|---|
| S2 Dashboard | Missing values use “Measuring…”; unmeasured reclaimable factor links to Cleanup | Cached values shown immediately, factor rows refresh in place | Missing sensor values retain their unavailable/unmeasured explanation | Health summary, storage panel, metric tiles and factor breakdown | FDA banner explains that reclaimable space is only partly measured | n/a |
| S3 Monitor | — (always data) | First sample within 1 s, charts fill from the left | Temperature "Unavailable on this Mac" | Live | Other users' processes shown without Quit | n/a |
| S4 Popover | — | "Measuring…" for the first sample | Readout shows "–" | Live | — | n/a |
| S5 Storage map | "Scan Macintosh HD to see what fills it" + Scan disk | Linear progress, files counted, current folder, Cancel | "Scan stopped: …" + Retry; unreadable folders listed | Treemap/sunburst + breadcrumb | Banner: N folders skipped without Full Disk Access | n/a |
| S6 Review large files | "No files over 500 MB that you haven’t opened in 6 months" | Uses scan; if none: "Scan first" | as S5 | Table | as S5 | n/a |
| S7 System Data | "Scan to break down System Data" | Centered measurement progress before results | Unmeasured row shows a dash | Table with sizes | Rows needing FDA marked | n/a |
| S8 Cleanup | "Nothing to clean right now. Last checked 2 min ago." | Centered measurement progress; no removal available | Rule-loading error with Try again; unavailable rules keep their reasons | Summary header above two panes: categories on the left; the selected category's rules (wrapping title and metadata, description in a tooltip/popover) on the right, items indented under each opened rule; unavailable rules in a collapsed "Not available here" footer | Categories needing FDA show "Needs Full Disk Access" and are unchecked | n/a |
| S9 Result | — | Progress "Moving 214 items to Trash…" | Per-item failures listed with reason; summary counts | "Moved 12.4 GB to Trash" + skipped list | — | n/a |
| S10 Op log | "No operations yet. Everything KeelMac moves or deletes is listed here." | Native data query; no synthetic loading skeleton | Failed/refused result rows; export errors in a native alert | Table | — | n/a |
| S11 Apps | "No apps found in /Applications" (rare) | Sizes measure in place | Row size "–" | Table + drop zone | — | n/a |
| S12 Uninstall preview | "Only the app bundle was found" | Matching related files… | Item can't be moved: reason | List with checkboxes | App is running: "Quit Xcode to uninstall it" + Quit | n/a |
| S13 Leftovers | "No leftovers from deleted apps" | Searching Library… | as S8 | Table grouped by bundle id | FDA banner | n/a |
| S14 Login items | "No login items or background agents" | Reading launchd… | Toggle failed: reason | Table | System items: "Needs the KeelMac helper" + Install helper | n/a |
| S15 Maintenance | — (catalogue) | Task row shows progress + live output | Exit code and last output lines | "Finished in 3 s" + output | Admin tasks: "Needs the KeelMac helper" + Install helper | n/a |
| S16 Duplicates | "Choose folders to search" / "No duplicates found in ~/Documents" | Stages: grouping by size, hashing (n of m) | Unreadable files listed | Groups with auto-select | FDA banner | n/a |
| S17 Snapshots | "No snapshots yet. KeelMac takes one every week." + Take snapshot | Taking snapshot… | Inline load/save error with Try again | Snapshot list + "What grew" comparison | — | n/a |
| S18 Settings | — | — | Inline validation (e.g. whitelist path doesn't exist) | Applied instantly | Helper status row | n/a |
| S1 Welcome | — | Checking access… (probe) | — | "Full Disk Access is on" check | Steps + Open Privacy & Security | n/a |
| S21 Assistant | "Ask about what you see." + up to three full-width suggested questions; a "Looking at …" line under the composer opens the exact context sent | "Checking Ollama…" in the header status line; first reply shows "Loading the model… the first answer takes a few seconds." inline | Inline error under the transcript with Try again; the transcript is kept | Streaming transcript: accent user bubbles, unboxed assistant text, lookups as capsules ("Looked up the Health Score") that open to the raw result; follow-up chips wrap above the composer | Off: "The Assistant is off." + Open Settings…; Ollama down: "Ollama isn’t running." + Open Ollama / Try again; no models: `ollama pull qwen3` | Context capped at 12 items / 1.5 KB; tool output 4 KB; 24 messages of history |

## Microcopy
Voice: calm, specific, numbers first, second person, sentence case, no exclamation marks except the one coffee prompt the spec writes. Never "danger", "threat", "infected", "boost", "junk is slowing you down".
- Assistant: it never claims to have changed anything; it names the screen and button ("Review large files › Move to Trash") and links it; unknown vendor folders get "I can’t be sure"; tool rows read "Looked up the Health Score"; the Settings footer states exactly what is sent (question, screen summary, names/sizes/dates) and what never is (file contents).
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
- Charts expose accessible summaries. Storage maps use the complete, keyboard-accessible contents list as their accessible alternative; no ten-item cutoff.
- Load line gauge has an accessibility label: "412 GB used of 494 GB, 38 GB above the load line".
- Status always symbol + word + colour.
- Native keyboard navigation: sidebar shortcuts (⌘1…⌘9), table selection and sorting, checkbox activation, keyboard-accessible cleanup category/disclosure controls, and native confirmation dismissal. Treemap arrow keys move selection, Return drills in, Esc goes up.
- Respect Reduce Motion: storage navigation redraws without spatial animation.

## App icon
Hull-ink rounded square, verdigris water across the lower third, the Plimsoll mark (ring and line) in sailcloth white on the waterline (About artboard).

## Storage Map · progressive exploration

- Show exactly the current folder and up to two real child levels, without collapsing dominant folder chains. At workspace widths >= 1,000 pt use a 60/40 map/list split; below that stack a 320 pt map and 340 pt list inside a scrolling workspace. Keep the wrapping selection action bar outside the scroll view.
- The list shows all immediate scan nodes largest first, including empty and unreadable folders. Disclosures expose one further level. Clicking a map child expands its parent and scrolls the matching row into view. Single-click selects; double-click, Return or Open folder drills in. Escape/Up navigates to the parent. Mode switches preserve selection.
- Treemap parents reserve a 40 pt header; children cannot draw into it. Names use measured, single-line truncation and labels are omitted when they cannot fit. Stop previews in small containers. Sunburst has a neutral center and two rings, no rotated text or callouts. Both use subtle file-kind tones, clear boundaries, and distinct hover/selection outlines, without dense hatching.
- Hover previews live in a fixed strip above the map and never replace selection. Current folder, measured bytes and breadcrumbs remain visible; middle ancestors collapse into a menu. Selected item metadata appears below the workspace; actions remain visible at minimum window size. Show in list brings the contents panel into view without changing selection. Return opens the selected folder; Escape uses Up, including when native list focus is active.
- A shared presentation model groups named nodes below 0.8% of their parent or beyond the largest 24 into Other items. Small files held only as aggregate bytes remain a separate Small files region. Areas/angles use exact measured proportions; no minimum inflated geometry. All named nodes remain available in the list; synthetic selections offer navigation/reveal of their containing folder, never file removal or Quick Look.
- Highlight controls retain existing review semantics; totals explicitly refer to the entire scan. On replacement scans, restore focus/selection by path and fall back to the nearest surviving parent. Empty, scanning, missing-access and failure states retain the same hierarchy.
- Verify both maps at minimum/default/wide sizes, both themes/languages, including long names, deep/dominant trees, thousands of small nodes, zero bytes and missing access. No live cleanup tests.
