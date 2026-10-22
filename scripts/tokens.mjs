#!/usr/bin/env node
// Mirrors design/tokens.css into iOS asset-catalog colour sets (Any + Dark appearances).
// Usage: node scripts/tokens.mjs --write   (generate colour sets)
//        node scripts/tokens.mjs --check   (exit 1 if any colour set drifted from tokens.css)
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";

const ROOT = new URL("..", import.meta.url).pathname;
const CSS = join(ROOT, "design/tokens.css");
const CATALOG = join(ROOT, "App/Resources/Assets.xcassets");

// asset name -> css custom property
const MAP = {
  bg: "--bg", surface: "--surface", surfaceMuted: "--surface-muted",
  border: "--border", borderStrong: "--border-strong",
  fg: "--fg", fgMuted: "--fg-muted",
  AccentColor: "--accent", accentHover: "--accent-hover", onAccent: "--on-accent", accentSoft: "--accent-soft", accentText: "--accent-text",
  controlAccent: "--control-accent",
  water: "--water", waterEdge: "--water-edge", hullInk: "--hull-ink",
  success: "--success", warning: "--warning", danger: "--danger", dangerSolid: "--danger-solid", onDanger: "--on-danger",
  warningSoft: "--warning-soft", warningInk: "--warning-ink", sidebar: "--sidebar",
  kindMedia: "--kind-media", kindArchive: "--kind-archive", kindModel: "--kind-model", onKind: "--on-kind",
};

const css = readFileSync(CSS, "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
const tokens = {};
for (const m of css.matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) if (!(m[1] in tokens)) tokens[m[1]] = m[2].trim();

function splitLD(v) {
  const m = v.match(/^light-dark\(([\s\S]*)\)$/);
  if (!m) return [v, v];
  let d = 0;
  for (let i = 0; i < m[1].length; i++) {
    const c = m[1][i];
    if (c === "(") d++; else if (c === ")") d--; else if (c === "," && d === 0) return [m[1].slice(0, i).trim(), m[1].slice(i + 1).trim()];
  }
  throw new Error("bad light-dark " + v);
}
function oklchToRgb(s) {
  const m = s.match(/oklch\(\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\)/);
  if (!m) throw new Error("not oklch: " + s);
  const [L, C, H] = [+m[1], +m[2], +m[3]];
  const a = C * Math.cos((H * Math.PI) / 180), b = C * Math.sin((H * Math.PI) / 180);
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.291485548 * b;
  const l = l_ ** 3, mm = m_ ** 3, ss = s_ ** 3;
  const lin = [
    4.0767416621 * l - 3.3077115913 * mm + 0.2309699292 * ss,
    -1.2684380046 * l + 2.6097574011 * mm - 0.3413193965 * ss,
    -0.0041960863 * l - 0.7034186147 * mm + 1.707614701 * ss,
  ];
  return lin.map((x) => {
    const c = Math.min(1, Math.max(0, x));
    return c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055;
  });
}
const hex = (rgb) => "0x" + rgb.map((c) => Math.round(c * 255).toString(16).padStart(2, "0").toUpperCase()).join("").replace(/(..)(..)(..)/, "$1,0x$2,0x$3");
function component(rgb) {
  const [r, g, b] = rgb.map((c) => "0x" + Math.round(c * 255).toString(16).padStart(2, "0").toUpperCase());
  return { "color-space": "srgb", components: { red: r, green: g, blue: b, alpha: "1.000" } };
}
function colorset(name) {
  let v = tokens[MAP[name]];
  if (!v) throw new Error("missing token " + MAP[name]);
  const vm = v.match(/^var\((--[\w-]+)\)$/);
  if (vm) v = tokens[vm[1]];
  const [light, dark] = splitLD(v).map(oklchToRgb);
  return {
    colors: [
      { idiom: "universal", color: component(light) },
      { idiom: "universal", appearances: [{ appearance: "luminosity", value: "dark" }], color: component(dark) },
    ],
    info: { author: "xcode", version: 1 },
  };
}

const mode = process.argv[2] || "--check";
let drift = 0;
if (mode === "--write") {
  mkdirSync(CATALOG, { recursive: true });
  writeFileSync(join(CATALOG, "Contents.json"), JSON.stringify({ info: { author: "xcode", version: 1 } }, null, 2) + "\n");
}
for (const name of Object.keys(MAP)) {
  const dir = join(CATALOG, `${name}.colorset`);
  const json = JSON.stringify(colorset(name), null, 2) + "\n";
  if (mode === "--write") {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "Contents.json"), json);
  } else {
    const p = join(dir, "Contents.json");
    if (!existsSync(p) || readFileSync(p, "utf8") !== json) { console.log(`drift: ${name}`); drift++; }
  }
}
if (mode === "--write") console.log(`wrote ${Object.keys(MAP).length} colour sets`);
else if (drift) { console.error(`tokens: ${drift} colour set(s) differ from design/tokens.css. Run node scripts/tokens.mjs --write`); process.exit(1); }
else console.log(`tokens: ${Object.keys(MAP).length} colour sets match design/tokens.css`);
