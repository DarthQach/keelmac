# Security and safety

KeelMac deletes files, so two kinds of report matter most:

1. **Unsafe deletion**: KeelMac offered, moved or deleted something it should never touch (a protected location, a whitelisted path, user data that isn't a cache).
2. **Privilege issues**: anything that lets another process make the KeelMac helper (which runs as root) do something outside its fixed list of tasks.

## How to report

- Unsafe deletion that doesn't expose anything private: open an issue with the **Unsafe deletion** template.
- Anything involving the helper, code signing, the update feed, or a way to make KeelMac delete arbitrary paths: please report privately with GitHub's **Report a vulnerability** (Security tab of the repository) instead of a public issue.

Include the KeelMac version, macOS version, the path involved and the matching rows from the operation log (Operation log › Export log…).

## Safety model (what we promise)

- Every removal is previewed first, and only previewed items are removed.
- Items go to the Trash unless you switched permanent delete on in Settings.
- `/System`, `/usr` (except `/usr/local`), `/bin`, `/sbin`, other users' homes, iCloud Drive, the Photos library, Mail, Messages, Safari history, Keychains and KeelMac's own data are refused in code (`Packages/SafetyKit/Sources/SafetyKit/PathGuard.swift`), in the app and again in the helper.
- Your whitelist is checked immediately before every removal.
- Every action is written to the operation log.
- The helper runs only named operations with fixed arguments and accepts connections only from KeelMac signed by the same team.

## Supported versions

Only the latest release receives fixes.
