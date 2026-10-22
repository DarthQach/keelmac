#!/usr/bin/env node
// Builds App/Resources/Localizable.xcstrings from the keys the Swift compiler extracts (SWIFT_EMIT_LOC_STRINGS)
// plus App/Resources/translations.es.json. Spanish (es) is required for every key.
// Usage: node scripts/strings.mjs --write | --check   (run after an xcodebuild build into build/DerivedData)
import { readFileSync, writeFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join } from "node:path";

const ROOT = new URL("..", import.meta.url).pathname;
const DD = join(ROOT, "build/DerivedData/Build/Intermediates.noindex");
const CATALOG = join(ROOT, "App/Resources/Localizable.xcstrings");
const ES = join(ROOT, "App/Resources/translations.es.json");

function walk(d, out = []) {
  if (!existsSync(d)) return out;
  for (const e of readdirSync(d)) {
    const p = join(d, e);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (p.endsWith(".stringsdata") && /KeelMac\.build/.test(p) && !/Tests\.build/.test(p)) out.push(p);
  }
  return out;
}
const files = walk(DD);
if (!files.length) { console.error("strings: no .stringsdata found; build the app first"); process.exit(2); }
const keys = new Map();
for (const f of files) {
  const j = JSON.parse(readFileSync(f, "utf8"));
  for (const e of j.tables?.Localizable ?? []) if (!keys.has(e.key)) keys.set(e.key, e.comment || "");
}
const es = existsSync(ES) ? JSON.parse(readFileSync(ES, "utf8")) : {};
const missing = [...keys.keys()].filter((k) => !(k in es)).sort();
const unused = Object.keys(es).filter((k) => !keys.has(k)).sort();

const strings = {};
for (const k of [...keys.keys()].sort()) {
  const entry = {};
  if (keys.get(k)) entry.comment = keys.get(k);
  if (k in es) entry.localizations = { es: { stringUnit: { state: "translated", value: es[k] } } };
  entry.extractionState = "manual";
  strings[k] = entry;
}
const catalog = JSON.stringify({ sourceLanguage: "en", strings, version: "1.0" }, null, 2) + "\n";

const mode = process.argv[2] || "--check";
if (mode === "--write") {
  writeFileSync(CATALOG, catalog);
  console.log(`strings: wrote ${keys.size} keys (${missing.length} without Spanish)`);
}
if (missing.length) { console.log("missing es:\n  " + missing.join("\n  ")); }
if (unused.length) { console.log("unused translations (ok, informational):\n  " + unused.join("\n  ")); }
if (mode === "--check") {
  const current = existsSync(CATALOG) ? readFileSync(CATALOG, "utf8") : "";
  if (current !== catalog) { console.error("strings: Localizable.xcstrings is out of date. Run node scripts/strings.mjs --write"); process.exit(1); }
  if (missing.length) process.exit(1);
  console.log(`strings: ${keys.size} keys, all translated to es`);
}
