---
name: KeelMac
stage: "1 · Stack chosen"
variant: E · Native macOS (SwiftUI + privileged helper, static Cloudflare site)
live:
repo:
created: 2026-10-22
---

# KeelMac

**One-liner:** Keep your Mac fast and roomy: see what's happening, clean safely, and never pay a subscription.
**Live:** (landing page once deployed)
**Next step:** Phase 2 · design with Claude Design.

## Documents
- [01 · Brief](01-brief.md)
- [02 · Stack](02-stack.md)
- [03 · Design](03-design.md) · Claude Design canvas: (pending) · artboards: `design/canvas/`
- [04 · Plan](04-plan.md)

## Gates
Carlos asked app-forge not to wait for approvals ("Do not wait for me to approve anything"). Gates are recorded as approved by that standing instruction, with the defaults listed in each document.
- [ ] Gate 1 · stack + design approved
- [ ] Gate 2 · plan + access approved

## Log
- 2026-10-22 07:25 · 0 · Brief received · Normalized from the Notion spec. The brief is a native macOS app (no accounts, no payments); app-forge's web defaults apply only to the landing page. Scope: spec v1.0 + v2. No intake questions asked (standing instruction); defaults recorded as ASSUMPTION lines.
- 2026-10-22 07:40 · 1 · Stack chosen · Native macOS (Swift 6, SwiftUI, KeelKit package, SMAppService helper, SwiftData, Sparkle 2.10.0); Cloudflare static Worker for landing + appcast. Clerk, Stripe and AWS not used.
