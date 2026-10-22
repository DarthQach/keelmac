#!/usr/bin/env bash
# KeelMac checks. Called by package.json scripts so app-forge's verify.sh runs unchanged.
#   bash scripts/mac.sh lint | test | build | e2e | run | release-build
set -euo pipefail
cd "$(dirname "$0")/.."

DD=build/DerivedData
LOGS=build/logs
mkdir -p "$LOGS"
PACKAGES=(${KM_PACKAGES:-SafetyKit MetricsKit ScanKit CleanKit AppsKit MaintenanceKit InsightsKit})

gen() { xcodegen generate --quiet; }

xb() { # xb <log-name> <xcodebuild args...>
  local log="$LOGS/$1.log"; shift
  if ! xcodebuild -project KeelMac.xcodeproj -scheme KeelMac -destination "platform=macOS" \
      -derivedDataPath "$DD" "$@" >"$log" 2>&1; then
    grep -E "error:|\*\* (BUILD|TEST) FAILED|Failing tests:|^\s+-|failed \(" "$log" | head -60 >&2 || true
    echo "✗ xcodebuild $* failed; full log: $log" >&2
    return 1
  fi
  local warns
  warns=$(grep -E "^/.*(App|Helper|Tests)/.*warning:" "$log" | sort -u || true)
  if [ -n "$warns" ]; then echo "$warns" >&2; echo "✗ compiler warnings in app sources" >&2; return 1; fi
  grep -E "Executed [0-9]+ tests?|Test run with|\*\* (BUILD|TEST) SUCCEEDED" "$log" | tail -3 || true
}

case "${1:-}" in
  lint)
    node scripts/tokens.mjs --check
    swift format lint --recursive App Helper Tests $(for p in "${PACKAGES[@]}"; do [ -d "Packages/$p/Sources" ] && echo "Packages/$p/Sources"; done) 2>"$LOGS/format.log" || true
    w=$(grep -c "warning:" "$LOGS/format.log" || true); echo "swift format: ${w:-0} style note(s) (see $LOGS/format.log)"
    ;;
  test)
    for p in "${PACKAGES[@]}"; do
      if [ -f "Packages/$p/Package.swift" ]; then
        echo "▶ swift test $p"
        (cd "Packages/$p" && swift test 2>&1 | grep -E "error:|✘|Test run with|Executed" | tail -5)
        (cd "Packages/$p" && swift test >/dev/null 2>&1) || { echo "✗ $p tests failed" >&2; exit 1; }
      fi
    done
    gen
    xb unit-tests test -only-testing:KeelMacTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60
    ;;
  build)
    gen
    xb build build
    node scripts/strings.mjs --check
    (cd site && node check.mjs)
    ;;
  e2e)
    gen
    xb ui-tests test -only-testing:KeelMacUITests -test-timeouts-enabled YES -default-test-execution-time-allowance 180
    ;;
  run)
    gen
    xb build build
    pkill -x KeelMac 2>/dev/null || true
    open "$DD/Build/Products/Debug/KeelMac.app"
    ;;
  release-build)
    gen
    xb release build -configuration Release
    mkdir -p dist && rm -rf dist/KeelMac.app && cp -R "$DD/Build/Products/Release/KeelMac.app" dist/
    echo "dist/KeelMac.app"
    ;;
  *) echo "usage: scripts/mac.sh lint|test|build|e2e|run|release-build" >&2; exit 2 ;;
esac
