# UI revamp verification · 2026-10-22

The approved refined native direction is implemented across the 13 main destinations and secondary surfaces. Shared spacing, typography, panels, file identities, adaptive action bars and metric layouts replace the compact ledger presentation. The website is unchanged.

## Scope and behavior

- Dashboard preserves the HealthScore inputs, factors, fix routes and 85% load line; free space now leads the storage panel.
- Monitor uses existing history and visibility-based sampling. Native process sorting and Quit handlers remain intact.
- Cleanup preserves category/rule/item selection, exclusions, unavailable reasons and confirmation handlers. The action bar describes permanent removals using the existing selection flag.
- Apps keeps native sorting/selection, context actions and the file-URL drop handler. Inspectors scroll when needed; file names and locations are distinct.
- The initial revamp preserved storage geometry. The subsequent Storage Map refinement below changes app-level geometry and hit testing together; scans, removal policies, public package APIs, schemas and helper protocol remain unchanged.
- Snapshots now displays its existing load/save error state, alongside retained data and a retry action.
- Settings uses grouped native tabs on macOS 15+; macOS 14 keeps its supported default tab style.

## Reproducible visual review

Run `bash scripts/revamp-shots.sh`. The script builds and runs only `RevampUITests`, exports named PNGs and generates `build/revamp-shots/index.html`. An existing result bundle can also be passed as its first argument.

The 22 app artboards in `design/canvas/` reference these local captures. The two marketing artboards remain unchanged. Generated captures stay in the ignored build directory and contain synthetic data.

The matrix includes:

- All 13 routes in English/Spanish and light/dark appearances.
- Dashboard, Cleanup, Apps and Monitor at requested 960 × 640 and 1600 × 1000 sizes, in light English and dark Spanish, plus default 1180 × 780 captures. Native chrome/minimum-content constraints can add height to the smallest outer window.
- Welcome, About, menu popover content, uninstall preview, cleanup result and all six Settings tabs in both languages and appearances.
- Empty/loading/error/partial-access/unavailable-sensor states, long names/paths, large sizes, locked rows, native uninstall sheet and sunburst.
- Cleanup item selection, disclosure expansion, confirmation/cancellation, keyboard route shortcuts and app-preview cancellation.

`VisualFixtures` is opt-in and Debug-only (also active in the unit-test host). It seeds an in-memory store and suppresses real scanning, sampling, helper calls and removals. The cleanup result uses a planted temporary cache file, a no-op injected trasher and `RecordingCommandRunner`. No live cleanup tests run.

## Checks

- 310 package tests passed across SafetyKit, MetricsKit, ScanKit, CleanKit, AppsKit, MaintenanceKit and InsightsKit (ReportKit and DuplicatesKit).
- 19 app unit tests passed.
- Nine UI test methods passed in `build/revamp-final.xcresult`; subsequent targeted runs refresh captures after final layout adjustments.
- All 28 generated color assets match the token source; 72 configured contrast pairs pass.
- Repository lint completed. Swift format reports advisory style notes; the repository lint command treats these as informational.
- All 624 extracted strings have Spanish translations; the native build and catalog are checked with the repository scripts.

Test logs are under `build/logs/revamp-*`. The final build log is `build/logs/build.log`.

## Review limits

The host runs macOS 27.0.1. The app retains a macOS 14 deployment target and availability guards, but this pass does not constitute a macOS 14 runtime test. Native accessibility labels/representations, focus behavior and Reduce Motion branches were reviewed; keyboard interactions are automated. A full spoken VoiceOver session and an end-to-end drag from Finder were not automated. The existing drop handler and all safety handlers were retained.

## Storage Map follow-up · 2026-10-22

The map is now paired with a complete size-ranked contents list, with two actual folder levels and explicit Up/breadcrumb navigation. Selecting a child region expands and scrolls its list parent; hover is independent of selection. At workspace widths below 1,000 points the map and list stack in a scrolling workspace, while selection actions stay visible.

Treemap headers and child labels have separate clipped bounds, with measured single-line truncation. Sunburst uses a neutral center and two rings. Both share a projection that retains exact byte totals and distinguishes omitted named nodes from small-file aggregate bytes. Synthetic regions never acquire filesystem actions other than revealing their containing folder. Selection survives scan index changes by path, with a surviving-parent fallback. The native list provides every scan node to keyboard and accessibility navigation.

Reproduce this focused visual/interaction review with `bash scripts/storage-map-shots.sh`; gallery: `build/storage-map-shots/index.html`. Tests use synthetic trees (including 3,000 folders, a dominant folder, long file names, empty folders, and missing access). No live cleanup tests or real filesystem removals are involved. Runtime verification remains on the current host; a spoken VoiceOver session and macOS 14 device check remain manual.

Follow-up checks passed: 32 ScanKit tests, 26 app tests, and all five focused Storage Map UI methods (visual matrix, edge states, map/list keyboard navigation, grouped-item safety, and minimum-width Spanish actions). The gallery contains 36 focused captures. The native build and all 647 Spanish string entries pass repository checks; lint reports advisory formatting notes. All 72 token contrast pairs pass, plus 16 composited map-label checks (minimum 8.72:1). Results are in `build/storage-map-acceptance.xcresult`, `build/storage-map-actions-final.xcresult`, and `build/storage-map-bar.xcresult`; the acceptance bundle's earlier keyboard failure is superseded by the passing targeted action run. Logs are under `build/logs/storage-*`.
