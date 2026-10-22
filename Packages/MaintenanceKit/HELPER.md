# KeelMacHelper: wiring notes for the main session

MaintenanceKit has everything the helper needs except its tiny `main.swift`, the launchd plist and the Xcode
target. This page gives all three, the build settings, and the manual approval and verification steps.

Identities (in `HelperShared.HelperIdentity`):

| | Value |
|---|---|
| App bundle id | `mx.cvillegas.keelmac` |
| Helper bundle id, launchd label, Mach service | `mx.cvillegas.keelmac.helper` |
| Team | `735MC85596` |
| Plist in the app | `KeelMac.app/Contents/Library/LaunchDaemons/mx.cvillegas.keelmac.helper.plist` |
| Helper binary in the app | `KeelMac.app/Contents/MacOS/KeelMacHelper` |

## 1. launchd plist (`Config/mx.cvillegas.keelmac.helper.plist`)

Copy it verbatim into `Contents/Library/LaunchDaemons/`. `BundleProgram` is relative to the app bundle.
`SMAppService.daemon(plistName:)` looks the file up by name, so the file name must be exactly this.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>mx.cvillegas.keelmac.helper</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/KeelMacHelper</string>
    <key>MachServices</key>
    <dict>
        <key>mx.cvillegas.keelmac.helper</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>mx.cvillegas.keelmac</string>
    </array>
</dict>
</plist>
```

No `RunAtLoad` or `KeepAlive`: launchd starts the helper on demand when the app connects to the Mach service.

## 2. `Helper/main.swift`

Compiled and checked against this package with zero warnings (Swift 6 mode):

```swift
import Foundation
import HelperCore
import HelperShared

// KeelMacHelper: launchd starts this as root on demand when the app connects to the Mach service.
let delegate = HelperListenerDelegate.production()
let listener = NSXPCListener(machServiceName: helperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
```

`HelperListenerDelegate.production()` sets `CodeSigningRequirement.client()` on every connection, which is
`anchor apple generic and identifier "mx.cvillegas.keelmac" and certificate leaf[subject.OU] = "735MC85596"`.
It also binds each connection to the caller's `effectiveUserIdentifier`, so `removeSystemItems` and
`launchd(…, .remove)` move items into that user's `~/.Trash/KeelMac` instead of deleting them.
The listener keeps `delegate` as a weak reference, so the top-level `let` must stay.

## 3. Targets and build settings (project.yml)

**KeelMacHelper** (`type: tool`, platform macOS, deployment target 14.0)
- Sources: `Helper/main.swift`. Dependencies: package products `HelperCore` and `HelperShared` from
  `Packages/MaintenanceKit` (they pull in SafetyKit).
- `PRODUCT_NAME = KeelMacHelper`
- `PRODUCT_BUNDLE_IDENTIFIER = mx.cvillegas.keelmac.helper`
- `CREATE_INFOPLIST_SECTION_IN_BINARY = YES` and `INFOPLIST_FILE = Helper/Info.plist`. A tool has no bundle, so
  the Info.plist goes into the binary's `__TEXT,__info_plist` section. Without it, `codesign` uses the file name
  as the identifier and the app's requirement `identifier "mx.cvillegas.keelmac.helper"` never matches.
  `Helper/Info.plist`:
  ```xml
  <dict>
      <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
      <key>CFBundleName</key><string>KeelMacHelper</string>
      <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
      <key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
      <key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
  </dict>
  ```
  You can also use `GENERATE_INFOPLIST_FILE = YES` together with `CREATE_INFOPLIST_SECTION_IN_BINARY = YES`, as long
  as `codesign -dv` reports the identifier below.
- `ENABLE_HARDENED_RUNTIME = YES`, `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM = 735MC85596`,
  `CODE_SIGN_IDENTITY = Apple Development` (Debug) / `Developer ID Application` (Release),
  `OTHER_CODE_SIGN_FLAGS = --timestamp` for Release (notarization).
- `SKIP_INSTALL = YES`, `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`.
- No entitlements file is needed (not sandboxed; root daemon).

**KeelMac** (app)
- Target dependency on KeelMacHelper.
- Copy Files phase "Embed helper": destination *Executables* (`Contents/MacOS`), file `KeelMacHelper`, Code Sign On Copy.
- Copy Files phase "Embed launchd plist": destination *Wrapper*, subpath `Contents/Library/LaunchDaemons`, file
  `Config/mx.cvillegas.keelmac.helper.plist` (no code signing).
- Links `MaintenanceKit` and `HelperShared` (for `HelperClient`, `MaintenanceCatalog`, `MaintenanceRunner`).
- Both executables must be signed by the same team (735MC85596) with an Apple-issued certificate. Ad-hoc signing
  (`CODE_SIGN_IDENTITY = -`, typical in CI) builds fine, but the XPC requirements refuse the connection at runtime.
- If the app is ever sandboxed, it needs
  `com.apple.security.temporary-exception.mach-lookup.global-name = [mx.cvillegas.keelmac.helper]`. It is not sandboxed today.

## 4. App-side API (MaintenanceKit)

```swift
let helper = HelperClient()                // SMAppService.daemon(plistName: "mx.cvillegas.keelmac.helper.plist")
helper.status                              // .notRegistered / .requiresApproval / .enabled / .notFound / .unavailable
try helper.register()                      // doesn't throw when the result is "needs approval"
helper.openApprovalSettings()              // SMAppService.openSystemSettingsLoginItems()
try await helper.unregister()
let response = try await helper.perform(.flushDNS)   // version handshake + timeout built in

let runner = MaintenanceRunner(runner: ProcessCommandRunner(), helper: helper)
for await event in runner.run(MaintenanceCatalog.task(.flushDNS)) { … }   // .output(line) … .failed(_)? .finished(exitCode:duration:)
```

Re-read `status` when the app becomes active, because the user approves the helper in System Settings.
For `HelperClientError.versionMismatch`, the installed helper is from an older build: call `unregister()` and then `register()`.

## 5. Manual approval and verification (Carlos, signed build)

1. Build Debug signed with "Apple Development: CARLOS VILLEGAS FROLA". Copy `KeelMac.app` to `/Applications`,
   because approval is tied to the bundle's path and signature. Launch it from there.
2. Check the signatures first:
   ```sh
   codesign -dv /Applications/KeelMac.app/Contents/MacOS/KeelMacHelper 2>&1 | grep -E 'Identifier|TeamIdentifier|Runtime'
   # Identifier=mx.cvillegas.keelmac.helper, TeamIdentifier=735MC85596, flags include runtime
   codesign -v -R='anchor apple generic and identifier "mx.cvillegas.keelmac" and certificate leaf[subject.OU] = "735MC85596"' /Applications/KeelMac.app && echo app-ok
   codesign -v -R='anchor apple generic and identifier "mx.cvillegas.keelmac.helper" and certificate leaf[subject.OU] = "735MC85596"' /Applications/KeelMac.app/Contents/MacOS/KeelMacHelper && echo helper-ok
   plutil -lint /Applications/KeelMac.app/Contents/Library/LaunchDaemons/mx.cvillegas.keelmac.helper.plist
   ```
3. In KeelMac › Settings › Helper, click Install (`register()`). macOS shows "Background Items Added", and the
   status becomes `.requiresApproval`.
4. Click "Open Login Items" (`openApprovalSettings()`). Under Allow in the Background, turn on KeelMac and authenticate.
   Back in the app, the status should read `.enabled`.
5. Confirm launchd knows the job: `sudo launchctl print system/mx.cvillegas.keelmac.helper | head -20`, and
   `sfltool dumpbtm | grep -B3 -A12 mx.cvillegas.keelmac.helper` (disposition `enabled, allowed`).
6. Run **Flush DNS cache** from Maintenance. Expect exit code 0. The helper's log is at
   `log show --last 5m --predicate 'process == "KeelMacHelper"'`.
7. Refusal check: from a debug menu or test hook, ask for `removeSystemItems(paths: ["/Users/<you>/Documents"])` and
   `launchd(label: "com.apple.Finder", …)`. Expect `.refused` (`outsideAllowedRoots`) and `.rejected(.appleLabel)`.
8. Trash check: `sudo mkdir /Library/Caches/KeelMacHelperTest`, then call `removeSystemItems(paths: ["/Library/Caches/KeelMacHelperTest"])`.
   The folder should show up in `~/.Trash/KeelMac/`. **If the outcome is `.failed` with "Operation not permitted"**,
   it is TCC: `~/.Trash` is privacy-protected even for root. You can grant KeelMacHelper Full Disk Access
   (System Settings › Privacy & Security › Full Disk Access › + › the binary inside the app). Or you can pass a
   different `bindExecutor` to `HelperListenerDelegate` that builds a `UserTrashMover` with a folder outside TCC.
   Nothing is ever deleted when the move fails.
9. After you rebuild the helper, launchd may keep the old process: `sudo launchctl kickstart -k system/mx.cvillegas.keelmac.helper`.
   You can also call `unregister()` and then `register()`. Avoid `sfltool resetbtm` except as a last resort: it resets every app's background approvals.

## 6. What the helper will and won't do

- Operations are only the `HelperOperation` cases. Each one maps to fixed absolute executables and argument arrays in
  `HelperCommandMap`, and nothing outside `HelperCommandMap.allowedExecutables` ever runs. There is no shell.
- `launchd`: the label must be reverse-DNS (`[A-Za-z0-9_-]` components, at least two, no spaces, `/`, `;` or `..`)
  and must not start with `com.apple.`. The plist must sit directly in `/Library/LaunchDaemons` (`system/<label>`) or
  `/Library/LaunchAgents` (`gui/<caller uid>/<label>`). It must be named `<label>.plist`, or its `Label` key (read
  without following symlinks) must equal the label. Enable runs `enable` then `bootstrap` (best effort).
  Disable runs `disable` then `bootout` (best effort). Remove runs `bootout` (best effort) and then moves the plist to the Trash.
- `removeSystemItems`: 1 to 1,000 clean absolute paths. Each one is re-checked by `SafeRemover` with `PathContext.helper`
  (system Library caches/logs/support/preferences, launchd folders, PrivilegedHelperTools, `/private/var/log`, app bundles
  in `/Applications`). The user's home, other homes, `/System`, `/usr` and container folders are refused.
- `thinLocalSnapshots(bytes)`: 1 byte to 100 TB, `tmutil thinlocalsnapshots / <bytes> 4`.
- `dumpBackgroundItems`: `sfltool dumpbtm`. On macOS 27 the app can run this itself (`BackgroundItemsReader.read(runner:)`).
  The helper route is for systems where it needs root. Parse the output with `BackgroundItemsDump.parse`.
