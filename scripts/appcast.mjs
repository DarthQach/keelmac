#!/usr/bin/env node
// Writes site/public/appcast.xml (Sparkle 2) from site/releases.json, newest first.
// A release entry: { version, build, date, dmgURL, length, edSignature, minimumSystemVersion, notes: { en: [], es: [] } }
// Usage: node scripts/appcast.mjs [--add version build dmgPath dmgURL edSignature notesEn...]
import { readFileSync, writeFileSync, statSync } from "node:fs";
const ROOT = new URL("..", import.meta.url).pathname;
const RELEASES = ROOT + "site/releases.json";
const SITE = "https://keelmac.flowrunnerapp.workers.dev";
const releases = JSON.parse(readFileSync(RELEASES, "utf8"));

const args = process.argv.slice(2);
if (args[0] === "--add") {
  const [, version, build, dmgPath, dmgURL, edSignature, ...notes] = args;
  const entry = { version, build, date: new Date().toISOString(), dmgURL, length: statSync(dmgPath).size, edSignature,
    minimumSystemVersion: "14.0", notes: { en: notes.length ? notes : [`KeelMac ${version}.`], es: notes.length ? notes : [`KeelMac ${version}.`] } };
  const i = releases.findIndex((r) => r.version === version);
  if (i >= 0) releases[i] = entry; else releases.unshift(entry);
  writeFileSync(RELEASES, JSON.stringify(releases, null, 2) + "\n");
}

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const items = releases.map((r) => `    <item>
      <title>KeelMac ${esc(r.version)}</title>
      <pubDate>${new Date(r.date).toUTCString()}</pubDate>
      <sparkle:version>${esc(r.build)}</sparkle:version>
      <sparkle:shortVersionString>${esc(r.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${esc(r.minimumSystemVersion || "14.0")}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${SITE}/releases/</sparkle:releaseNotesLink>
      <enclosure url="${esc(r.dmgURL)}" length="${r.length}" type="application/octet-stream" sparkle:edSignature="${esc(r.edSignature)}"/>
    </item>`).join("\n");

const xml = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>KeelMac</title>
    <link>${SITE}/</link>
    <description>KeelMac updates</description>
    <language>en</language>
${items}
  </channel>
</rss>
`;
writeFileSync(ROOT + "site/public/appcast.xml", xml);
console.log(`appcast: ${releases.length} release(s)`);
