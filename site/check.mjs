// Static checks for the site: every page has lang, title, viewport, and only internal links that resolve.
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join } from "node:path";
const root = new URL("./public", import.meta.url).pathname;
const pages = [];
(function walk(d) { for (const e of readdirSync(d)) { const p = join(d, e); statSync(p).isDirectory() ? walk(p) : p.endsWith(".html") && pages.push(p); } })(root);
let bad = 0;
for (const p of pages) {
  const h = readFileSync(p, "utf8");
  for (const [re, msg] of [[/<html lang="(en|es)">/, "lang"], [/<title>[^<]+<\/title>/, "title"], [/name="viewport"/, "viewport"]]) if (!re.test(h)) { console.log(`${p}: missing ${msg}`); bad++; }
  for (const m of h.matchAll(/href="(\/[^"#]*)/g)) {
    const t = m[1];
    const f = t.endsWith("/") ? join(root, t, "index.html") : join(root, t);
    if (!existsSync(f)) { console.log(`${p}: broken link ${t}`); bad++; }
  }
}
console.log(`site check: ${pages.length} pages, ${bad} problem(s)`);
process.exit(bad ? 1 : 0);
