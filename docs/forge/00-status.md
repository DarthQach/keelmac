---
name: KeelMac
stage: "5 · Deployed (site live; app built, tested and packaged locally; notarized release pending Developer ID)"
variant: E · Native macOS (SwiftUI + privileged helper, static Cloudflare site)
live: https://keelmac.flowrunnerapp.workers.dev
repo: https://github.com/DarthQach/keelmac (private)
created: 2026-10-22
---

# KeelMac

**One-liner:** Keep your Mac fast and roomy: see what's happening, clean safely, and never pay a subscription.
**Live:** https://keelmac.flowrunnerapp.workers.dev (landing + appcast)
**Next step:** Carlos installs `dist/KeelMac-1.0.0.dmg`, grants Full Disk Access, approves the helper, then adds Developer ID + notary secrets and tags v1.0.0.

## Documents
- [01 · Brief](01-brief.md)
- [02 · Stack](02-stack.md)
- [03 · Design](03-design.md) · Claude Design canvas: https://claude.ai/artifact/RN1YhHXALokVCwBXWtDd29 · artboards: `design/canvas/`
- [04 · Plan](04-plan.md)

## Gates
Carlos asked app-forge not to wait for approvals ("Do not wait for me to approve anything"). Gates are recorded as approved by that standing instruction, with the defaults listed in each document.
- [x] Gate 1 · stack + design approved (2026-10-22, standing instruction; no changes)
- [x] Gate 2 · plan + access approved (2026-10-22, standing instruction). Missing access that doesn't block the build: Developer ID + notary credentials, Buy Me a Coffee handle.

## Log
- 2026-10-22 07:25 · 0 · Brief received · Normalized from the Notion spec. The brief is a native macOS app (no accounts, no payments); app-forge's web defaults apply only to the landing page. Scope: spec v1.0 + v2. No intake questions asked (standing instruction); defaults recorded as ASSUMPTION lines.
- 2026-10-22 07:40 · 1 · Stack chosen · Native macOS (Swift 6, SwiftUI, KeelKit package, SMAppService helper, SwiftData, Sparkle 2.10.0); Cloudflare static Worker for landing + appcast. Clerk, Stripe and AWS not used.
- 2026-10-22 08:35 · 1 · Stack chosen · Claude Design canvas published (24 artboards). Tokens contrast-checked (62 pairs). Slop audit: 0 errors, 8 intentional warnings, §10 clean.
- 2026-10-22 08:40 · 2 · Designed · Gate 1 approved by Carlos's standing instruction. Artboards copied to design/canvas/. Palette appended to app-forge history.
- 2026-10-22 08:55 · 2 · Designed · 04-plan.md written: M0–M9, SwiftData models, rules schema, test/deploy/rollback, access checked (Xcode, XcodeGen, signing team 735MC85596, wrangler, gh).
- 2026-10-22 08:56 · 3 · Planned · Gate 2 approved by standing instruction.
- 2026-10-22 09:20 · 4 · Building (M0) · SafetyKit (PathGuard, whitelist, Trash-first remover, op log types, command runner; 26 tests). XcodeGen app shell with sidebar, empty states, Settings, menu bar extra, welcome/FDA sheet; tokens → 23 colour sets; app icon; EN/ES catalog (67 keys); site EN/ES live on workers.dev; CI workflow; repo docs. verify.sh passes. Six module packages handed to parallel agents against docs/forge/contracts.md.
- 2026-10-22 10:00 · 4 · Building (M1–M9) · Six module packages built by parallel agents against contracts.md (308 tests). App screens: dashboard + load line, monitor, menu bar, storage map (treemap, sunburst), large/old, System Data, cleanup + result + coffee prompt, operation log, apps + uninstall + drop zone + trash watcher, leftovers, login items, maintenance + embedded SMAppService helper, duplicates, snapshots + weekly report, settings, about, Sparkle (key in login keychain, account "keelmac"). Spanish for all 562 strings. Site with real screenshots.
- 2026-10-22 10:05 · findings · Idle CPU 1.1–1.25 % at 2 s (target < 1 %, open). Two screenshots with the username were live on the site for ~2 minutes and removed. macOS window restoration kept the window closed after `-menuBarOnly` runs; launches now always open it.
- 2026-10-22 10:10 · 5 · Deployed · verify.sh passes; 5 UI tests pass; live clean acceptance passes. DMG at dist/KeelMac-1.0.0.dmg (Apple Development signed, not notarized). Site live. Pending on Carlos: helper approval, Developer ID + notarization, making the repo public, Buy Me a Coffee handle.
