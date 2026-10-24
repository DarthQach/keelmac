# Contributing to KeelMac

Thanks for helping. KeelMac deletes files, so the bar for anything that removes data is high: every change that affects what gets removed needs tests that prove what it removes and what it never removes.

## Getting set up

```bash
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # sign to run locally, or set your own team
bash scripts/mac.sh run      # generate the project, build, launch
bash scripts/mac.sh test     # all package tests + app unit tests
bash scripts/mac.sh lint     # token drift + swift format
```

`KeelMac.xcodeproj` is generated from `project.yml`; don't commit it.

## Adding a cleanup rule

Cleanup rules are data: `Packages/CleanKit/Sources/CleanKit/Resources/cleanup-rules.json`. The schema is documented in `Packages/CleanKit/RULES.md`.

1. Add the rule with a unique `id`, a `category`, English **and** Spanish `title` and `detail`, and the narrowest `paths` that work. Prefer the contents of a cache folder (`…/Caches/Tool/*`) over the folder itself.
2. Say why it's safe in `detail` (the app shows it): who recreates the data, and what happens if it's removed.
3. Use `minAgeDays`, `exclude`, `skipIfRunning` and `optIn` generously. Anything a user might want to keep is `optIn`.
4. Add a fixture test in `Packages/CleanKit/Tests` showing what the rule selects and something next to it that it must not select.
5. Run `swift test` in `Packages/CleanKit`.

Rules can never reach protected locations: `PathGuard` refuses them regardless of what a rule says, and a test enforces that.

## Code style

- Swift 6 language mode with strict concurrency; zero warnings.
- Package code returns values and enums, the app turns them into localized text. Every user-facing string needs a Spanish translation in `App/Resources/translations.es.json` (`node scripts/strings.mjs --check`).
- UI colours only from the asset catalog (generated from `design/tokens.css` by `node scripts/tokens.mjs --write`).
- Every removal goes through `SafetyKit.SafeRemover`; every external command through `CommandRunning` with an absolute path and an argument array.

## Pull requests

Keep them focused, describe what a user can now do, and include screenshots for UI changes (light and dark). CI must pass.
