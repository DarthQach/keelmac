#!/usr/bin/env bash
# Runs the UI tests and exports their screenshots to build/shots/<name>.png.
#   bash scripts/shots.sh [-only-testing:KeelMacUITests/Class/test]
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build/ui.xcresult build/shots && mkdir -p build/shots build/logs
xcodegen generate --quiet
pkill -x KeelMac 2>/dev/null || true
xcodebuild -project KeelMac.xcodeproj -scheme KeelMac -destination platform=macOS -derivedDataPath build/DerivedData \
  -resultBundlePath build/ui.xcresult test ${1:--only-testing:KeelMacUITests} >build/logs/shots.log 2>&1 || { grep -E "error:|failed" build/logs/shots.log | head -20; }
xcrun xcresulttool export attachments --path build/ui.xcresult --output-path build/shots >/dev/null
node -e '
const fs=require("fs"),p="build/shots/manifest.json";const m=JSON.parse(fs.readFileSync(p,"utf8"));
for(const t of m) for(const a of t.attachments){const n=a.suggestedHumanReadableName.replace(/_\d+_[0-9A-F-]+\.png$/i,".png").replace(/^(.*?)_\d+\.png$/,"$1.png"); fs.renameSync("build/shots/"+a.exportedFileName,"build/shots/"+n);}
'
ls build/shots | grep -v manifest
