#!/usr/bin/env bash
# Synthetic Storage Map matrix; accepts existing xcresult bundles to export without rerunning.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs build/storage-map-shots
if [ "$#" -eq 0 ]; then
  result="build/storage-map-$(date +%s).xcresult"
  xcodegen generate --quiet
  xcodebuild -project KeelMac.xcodeproj -scheme KeelMac -destination platform=macOS \
    -derivedDataPath build/DerivedData -resultBundlePath "$result" \
    test -only-testing:KeelMacUITests/StorageMapRevampUITests >build/logs/storage-map-ui.log 2>&1
  set -- "$result"
fi
for result in "$@"; do bash scripts/revamp-shots.sh "$result"; done
node --input-type=module <<'JS'
import fs from 'node:fs';
const source = 'build/revamp-shots', output = 'build/storage-map-shots';
const names = fs.readdirSync(source).filter(n => n.startsWith('revamp-map-') && n.endsWith('.png')).sort();
for (const name of names) fs.copyFileSync(`${source}/${name}`, `${output}/${name}`);
fs.writeFileSync(`${output}/index.html`, `<!doctype html><html lang="en"><meta charset="utf-8"><title>KeelMac · Storage Map review</title>
<style>body{font:16px -apple-system,system-ui;margin:40px;background:#eee;color:#222}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(440px,1fr));gap:32px}img{width:100%;height:auto;border-radius:12px}h2{font-size:16px}a{color:inherit}</style>
<h1>Storage Map · visual review</h1><p>Isolated synthetic trees. Two levels, synchronized contents, small-item aggregation; light/dark, English/Spanish, and minimum/default/wide windows.</p><main>
${names.map(n => `<article><h2>${n.replace('revamp-map-', '').replace('.png', '')}</h2><a href="${n}"><img loading="lazy" src="${n}" alt="${n}"></a></article>`).join('\n')}</main></html>`);
console.log(`${names.length} storage map screenshots: ${output}/index.html`);
JS
