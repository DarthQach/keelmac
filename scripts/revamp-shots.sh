#!/usr/bin/env bash
# Isolated UI checks + a local screenshot gallery. Optional argument: an existing xcresult.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs build/revamp-shots
result="${1:-build/revamp-ui-$(date +%s).xcresult}"
if [ "$#" -eq 0 ]; then
  xcodegen generate --quiet
  xcodebuild -project KeelMac.xcodeproj -scheme KeelMac -destination platform=macOS \
    -derivedDataPath build/DerivedData -resultBundlePath "$result" \
    test -only-testing:KeelMacUITests/RevampUITests >build/logs/revamp-ui.log 2>&1
fi
export_dir="$(mktemp -d "${TMPDIR:-/tmp}/keelmac-shots.XXXXXX")"
trap 'rm -rf "$export_dir"' EXIT
xcrun xcresulttool export attachments --path "$result" --output-path "$export_dir" >/dev/null
export KEELMAC_SHOT_EXPORT="$export_dir"
node --input-type=module <<'JS'
import fs from 'node:fs';
const dir = 'build/revamp-shots';
const manifest = JSON.parse(fs.readFileSync(`${process.env.KEELMAC_SHOT_EXPORT}/manifest.json`, 'utf8'));
for (const test of manifest) for (const a of test.attachments) {
  if (!a.exportedFileName.endsWith('.png')) continue;
  const name = a.suggestedHumanReadableName.split('_')[0];
  if (!name.startsWith('revamp-')) continue;
  fs.copyFileSync(`${process.env.KEELMAC_SHOT_EXPORT}/${a.exportedFileName}`, `${dir}/${name}.png`);
}
for (const name of fs.readdirSync(dir)) {
  if (/^revamp-(settings|welcome|about|menuBar|uninstall|result)-(light|dark)\.png$/.test(name) || /^revamp-(dashboard|cleanup|apps|monitor)-(960x640|1600x1000)\.png$/.test(name)) fs.unlinkSync(`${dir}/${name}`);
}
const names = fs.readdirSync(dir).filter(n => n.startsWith('revamp-') && n.endsWith('.png')).sort();
fs.writeFileSync(`${dir}/index.html`, `<!doctype html><html lang="en"><meta charset="utf-8"><title>KeelMac · UI review</title>
<style>body{font:16px -apple-system,system-ui;margin:40px;background:#eee;color:#222}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(440px,1fr));gap:32px}img{width:100%;height:auto;border-radius:12px}h2{font-size:16px}a{color:inherit}</style>
<h1>KeelMac · UI review</h1><p>Native screenshots using isolated synthetic fixtures. English, Spanish, light and dark; window sizes and presentation states.</p><main>
${names.map(n => `<article><h2>${n.replace('revamp-', '').replace('.png', '')}</h2><a href="${n}"><img loading="lazy" src="${n}" alt="${n}"></a></article>`).join('\n')}</main></html>`);
console.log(`${names.length} screenshots: ${dir}/index.html`);
JS
