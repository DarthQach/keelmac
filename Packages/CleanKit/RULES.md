# Cleanup rules

KeelMac's Cleanup screen is driven by one file:
`Packages/CleanKit/Sources/CleanKit/Resources/cleanup-rules.json` (schema version 1).
Add or change a rule with a pull request. A machine-readable description of the format is in
[`cleanup-rules.schema.json`](cleanup-rules.schema.json).

## What a rule can and can't do

A rule only *proposes* items for the preview. Every proposed path, at plan time and again right
before removal, goes through `SafetyKit.PathGuard` with the `cleanup` context. A rule can never
reach a protected location (`/System`, `/usr`, `~/Library/Mail`, iCloud Drive, Keychains,
Photos libraries, `~/Library/Safari`, …), another user's home, a container folder such as
`~/Library/Caches` itself, or anything the user whitelisted. Those matches are dropped silently and
only counted (`refusedCount`). Items go to the Trash; only a rule with `deletesPermanently` (the
Trash itself) deletes.

The executor never re-expands a rule: it removes exactly the previewed items the user left checked,
and skips any whose modification date changed since the preview.

## Fields

| Field | Type | Default | Meaning |
|---|---|---|---|
| `id` | string | required | Unique, letters, digits and `-`. Becomes the group id and the prefix of item ids. Never rename a shipped id. |
| `category` | string | required | `developer`, `userCaches`, `browserCaches`, `logs`, `installers`, `iosBackups`, `docker`, `languageFiles`, `trash`. |
| `title`, `detail` | `{ "en": …, "es": … }` | required | Shown in the app. Both languages are required. Calm and specific: what it is, what happens after removal. |
| `note` | string | — | For contributors only (English, not shown): sources, why something is excluded. |
| `kind` | `paths` \| `command` | `paths` | Path rules offer files and folders. Command rules offer one item that runs a command. |
| `paths` | [glob] | `[]` | Where items are found. See *Globs*. Each match is one item. |
| `exclude` | [glob] | `[]` | A match, anything inside a match, and any item that would contain a match is never offered. Case-insensitive. |
| `minAgeDays` | int | `0` | Only items whose newest modification (for folders: the newest file or folder inside) is at least this old. |
| `keepNewest` | int | `0` | For each entry of `paths` separately, the N matches with the newest modification are kept. |
| `optIn` | bool | `false` | Listed but unchecked by default. Use for anything a person may still want (archives, backups, docker). |
| `needsFullDiskAccess` | bool | `false` | Without Full Disk Access the group shows "Needs Full Disk Access" and offers nothing. Set it for TCC-protected folders. |
| `needsAdmin` | bool | `false` | Needs root. CleanKit never runs these; the group reports `needsHelper`. |
| `skipIfRunning` | [bundle id] | `[]` | While any of these apps runs, the whole rule is skipped (`appRunning`), its matches listed as skipped. |
| `skipItemIfAppRunning` | bool | `false` | Per item: an item named like a running app's bundle id (`com.foo.app`, `com.foo.app.helper`) is skipped. |
| `deletesPermanently` | bool | `false` | Delete instead of moving to the Trash. Only for emptying the Trash; the UI warns. |
| `command` | `{executable, arguments, timeoutSeconds?}` | — | `kind: command` only. `executable` is absolute or `{tool}`. Arguments are passed as an array; there is never a shell. |
| `requiresTool` | string | — | Tool name shown when it's missing (`brew`, `docker`). |
| `toolPaths` | [path] | `[]` | Candidate locations, in order; the first executable one is `{tool}`. None found → `toolMissing`. No wildcards. |
| `toolCheck` | command | — | Must exit 0 before the rule is offered (e.g. `docker info`); otherwise `toolNotResponding`. |
| `measure` | [path] | — | Folders whose allocated size is the expected saving of a command rule. They are also claimed: no path rule may offer anything overlapping them. |
| `measureWith` | string | — | Built-in measurement: `simctlUnavailableDevices`, `pnpmStorePath`, `dockerSystemDF`. |
| `filter` | string | — | Built-in filter: `unsignedAppLanguages` (paths match `.app` bundles; unsigned ones offer their unused `.lproj` folders). |
| `keepLanguages` | [string] | `[]` | For `unsignedAppLanguages`: languages always kept, in addition to the user's preferred languages. |
| `itemInfo` | string | — | Extra item info: `iosBackup` reads device name, model, iOS version and date from `Info.plist`. |

Unknown fields are ignored, so a newer file still loads in an older build; a different
`schemaVersion` is refused.

## Globs

- Absolute (`/…`) or home-relative (`~/…`). Relative paths, `.` and `..` are rejected.
- `*` and `?` match within one path component, including names that start with a dot.
  There is no `**`: expansion stays bounded and predictable.
- `{uid}` is replaced by the user's numeric id (`/Volumes/*/.Trashes/{uid}/*`).
- Expansion never walks through a symlink. A symlink can be an item (removing it removes the link,
  never its target); a symlink in the middle of a pattern ends that branch.
- Prefer `folder/*` (the contents) over `folder` when the app expects the folder to exist.

## Sizes and dates

Sizes are allocated bytes (what removal frees), measured without following symlinks, counting hard
links once and never crossing into another mounted volume. Empty items (0 bytes) are not offered,
except in the Trash.

## Overlaps

No path is ever offered twice or inside another item. Folders claimed by command rules (`measure`,
measured folders) come first; then path items in file order: a later item that equals, contains or
lies inside an earlier one is dropped. Don't rely on this: exclude explicitly (as `user-caches`
excludes the browser and package-manager folders other rules own).

## Checklist for a new rule

1. Check the location on a real Mac (`ls`), on macOS 14 and later, Apple silicon and Intel paths.
2. Is it rebuilt automatically? If not, or if someone could still want it, set `optIn`.
3. Is it protected by macOS privacy controls? Set `needsFullDiskAccess`.
4. Does an app hold it open? Use `skipIfRunning`.
5. Add en and es text. Say what the user loses, honestly.
6. Add a fixture test in `Tests/CleanKitTests/RuleTests.swift`: what it selects and what it must
   never select. `swift test` must pass with zero warnings.
