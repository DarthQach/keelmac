// Generates the static pages in public/ from one template per page and the EN/ES strings below.
// Usage: node build.mjs   (then node check.mjs, then wrangler deploy)
import { writeFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";

const ROOT = new URL("./public", import.meta.url).pathname;
const REPO = "https://github.com/DarthQach/keelmac";
const COFFEE = "https://buymeacoffee.com/keelmac";
const releases = JSON.parse(readFileSync(new URL("./releases.json", import.meta.url), "utf8"));
const latest = releases[0];
const DOWNLOAD = latest ? latest.dmgURL : `${REPO}/releases/latest`;
const shot = (name) => existsSync(join(ROOT, "shots", `${name}.png`));

const mark = (size = 34) => `<svg width="${size}" height="${Math.round(size * 20 / 34)}" viewBox="0 0 34 20" aria-hidden="true"><circle cx="17" cy="10" r="8" fill="none" stroke="currentColor" stroke-width="2"/><line x1="1" y1="10" x2="33" y2="10" stroke="currentColor" stroke-width="2"/></svg>`;

const T = {
  en: {
    lang: "en", prefix: "", other: "/es/", otherName: "Español",
    title: "KeelMac: keep your Mac fast and roomy",
    description: "Free, open-source Mac app to see what fills your disk, clean safely with a preview, uninstall apps completely and watch your Mac from the menu bar.",
    skip: "Skip to content", safety: "Safety", faq: "FAQ", download: "Download",
    h1: "Keep your Mac above the load line.",
    lede: "KeelMac shows what fills your disk, cleans only what is safe to clean, and writes down everything it touches. Free, open source, and it never phones home.",
    cta: "Download for macOS", copy: "Copy", copied: "Copied", copyLabel: "Copy the Homebrew command",
    req: "macOS 14 Sonoma or later, Apple silicon and Intel.",
    score: "Your Mac is in good shape.", of: "82 of 100", used: "382&nbsp;GB used of 494&nbsp;GB", margin: "38&nbsp;GB above the load line",
    gaugeLabel: "382 GB used of 494 GB, 38 GB above the load line",
    caption: "The load line marks 85% full. Below it, macOS has room for updates, swap and snapshots.",
    toolsH: "Five tools you used to install separately, in one app that stays out of the way.",
    features: [
      ["storage", "See where the space went", "Scan the whole disk in under a minute and drill into a treemap or a sunburst. Find large files you haven’t opened in a year, and see what “System Data” really is."],
      ["cleanup", "Clean with a preview, every time", "Caches, logs, browser caches, old iPhone backups, installers in Downloads, and the developer leftovers generic cleaners miss: DerivedData, old DeviceSupport, simulators, npm, pnpm, Homebrew, Gradle. You see every path before anything moves."],
      ["menubar", "Watch it live from the menu bar", "CPU, memory pressure, disk, network, battery and temperature, refreshed every two seconds. Open it to see the last hour and the five processes working hardest."],
      ["maintenance", "Uninstall apps completely, and keep up with maintenance", "Drag an app in to remove it with its preferences, caches and containers. Run the classic maintenance tasks, each showing the exact command it runs."],
    ],
    safetyH: "How KeelMac keeps your files safe",
    rules: [
      "Every cleanup starts as a preview. Nothing outside the preview is touched.",
      "Items go to the Trash first. Permanent delete is a setting you turn on yourself.",
      "System folders, other users’ homes, iCloud Drive, Photos and Mail are protected in code.",
      "Your whitelist is checked on every delete, including admin tasks.",
      "Every action is written to an operation log you can read and export.",
    ],
    logCaption: "Operation log", path: "Path", size: "Size", result: "Result", trashed: "Moved to Trash", skippedSafari: "Skipped, Safari is open",
    freeH: "Free, with no catch",
    free1: "No subscription, no account, no telemetry. The only network request KeelMac makes is the update check. The code is on GitHub under the GPL-3.0 licence, and cleanup rules are a JSON file anyone can improve.",
    free2: `If it saved you an afternoon, you can <a href="${COFFEE}">buy me a coffee</a>.`,
    faqH: "Questions",
    faqs: [
      ["Does KeelMac speed up my Mac by freeing RAM?", "No. macOS manages memory well on its own. KeelMac shows memory pressure so you can see when an app is the problem, and lets you quit it."],
      ["Why does it ask for Full Disk Access?", "Many caches and logs live in folders macOS protects. Without access KeelMac still works, but it skips those folders and tells you which ones."],
      ["What does the helper do?", "A few tasks, like rebuilding the Spotlight index, need administrator rights. The helper can only run the named tasks listed in the app, and checks every path again before touching it."],
      ["Is it on the Mac App Store?", "No. The App Store sandbox doesn’t allow an app to clean caches across your Library. Download it here or with Homebrew."],
      ["Is my data sent anywhere?", "No. KeelMac has no account and no analytics. It only checks this site for updates."],
    ],
    footer: "KeelMac is free software under the GPL-3.0 licence.", releasesL: "Release notes", privacyL: "Privacy", issue: "Report an issue",
    privacyTitle: "Privacy", privacyBody: `
<p>KeelMac runs entirely on your Mac. It has no account, no analytics and no telemetry.</p>
<h2>What leaves your Mac</h2>
<p>Only the update check: once a day (if automatic updates are on) KeelMac downloads <code>appcast.xml</code> from this site to see whether a new version exists. Sparkle’s anonymous system profile is turned off. This site’s host, Cloudflare, sees the request like any web request.</p>
<h2>What stays on your Mac</h2>
<p>Scan results, the operation log, weekly snapshots and settings are stored in <code>~/Library/Application Support/KeelMac</code> and in KeelMac’s preferences. Delete the app and that folder to remove everything.</p>
<h2>File contents</h2>
<p>KeelMac reads file names, sizes and dates. It reads file contents only when you search for duplicates, to compare files byte for byte, and never sends them anywhere.</p>
<h2>Contact</h2>
<p>Questions or a privacy concern: <a href="${REPO}/issues">open an issue on GitHub</a>.</p>`,
    releasesTitle: "Release notes", downloadVersion: (v) => `Download ${v}`,
    notFound: "That page doesn’t exist.", home: "Go to the home page",
  },
  es: {
    lang: "es", prefix: "/es", other: "/", otherName: "English",
    title: "KeelMac: tu Mac rápida y con espacio",
    description: "App gratuita y de código abierto para Mac: mira qué llena tu disco, limpia con vista previa, desinstala apps por completo y vigila tu Mac desde la barra de menús.",
    skip: "Ir al contenido", safety: "Seguridad", faq: "Preguntas", download: "Descargar",
    h1: "Mantén tu Mac por encima de la línea de carga.",
    lede: "KeelMac te muestra qué llena tu disco, limpia solo lo que es seguro limpiar y anota todo lo que toca. Gratis, de código abierto y sin rastreo.",
    cta: "Descargar para macOS", copy: "Copiar", copied: "Copiado", copyLabel: "Copiar el comando de Homebrew",
    req: "macOS 14 Sonoma o posterior, Apple silicon e Intel.",
    score: "Tu Mac está en buena forma.", of: "82 de 100", used: "382&nbsp;GB usados de 494&nbsp;GB", margin: "38&nbsp;GB por encima de la línea de carga",
    gaugeLabel: "382 GB usados de 494 GB, 38 GB por encima de la línea de carga",
    caption: "La línea de carga marca el 85&nbsp;% de ocupación. Por debajo, macOS tiene espacio para actualizaciones, memoria virtual e instantáneas.",
    toolsH: "Cinco herramientas que antes instalabas por separado, en una app que no estorba.",
    features: [
      ["storage", "Mira a dónde se fue el espacio", "Escanea el disco en menos de un minuto y explóralo como mapa o como anillos. Encuentra archivos grandes que no abres desde hace un año y descubre qué es en realidad “Datos del sistema”."],
      ["cleanup", "Limpia con vista previa, siempre", "Cachés, registros, cachés del navegador, respaldos viejos del iPhone, instaladores en Descargas y la basura de desarrollo que otros limpiadores no ven: DerivedData, DeviceSupport, simuladores, npm, pnpm, Homebrew, Gradle. Ves cada ruta antes de mover nada."],
      ["menubar", "Vigila todo desde la barra de menús", "CPU, presión de memoria, disco, red, batería y temperatura cada dos segundos. Ábrela para ver la última hora y los cinco procesos que más trabajan."],
      ["maintenance", "Desinstala apps por completo y mantén tu Mac al día", "Arrastra una app para quitarla con sus preferencias, cachés y contenedores. Corre las tareas de mantenimiento clásicas viendo el comando exacto que ejecutan."],
    ],
    safetyH: "Cómo protege KeelMac tus archivos",
    rules: [
      "Cada limpieza empieza como vista previa. Nada fuera de ella se toca.",
      "Todo va primero a la Papelera. Borrar para siempre es un ajuste que activas tú.",
      "Las carpetas del sistema, las cuentas de otros usuarios, iCloud Drive, Fotos y Mail están protegidas en el código.",
      "Tu lista de exclusiones se revisa en cada borrado, también en las tareas de administrador.",
      "Cada acción queda en un registro que puedes leer y exportar.",
    ],
    logCaption: "Registro de operaciones", path: "Ruta", size: "Tamaño", result: "Resultado", trashed: "Movido a la Papelera", skippedSafari: "Omitido, Safari está abierto",
    freeH: "Gratis, sin trampa",
    free1: "Sin suscripción, sin cuenta, sin telemetría. La única conexión que hace KeelMac es para buscar actualizaciones. El código está en GitHub con licencia GPL-3.0, y las reglas de limpieza son un archivo JSON que cualquiera puede mejorar.",
    free2: `Si te ahorró una tarde, puedes <a href="${COFFEE}">invitarme un café</a>.`,
    faqH: "Preguntas",
    faqs: [
      ["¿KeelMac acelera mi Mac liberando RAM?", "No. macOS administra bien la memoria por sí solo. KeelMac muestra la presión de memoria para que veas cuándo una app es el problema, y te deja cerrarla."],
      ["¿Por qué pide acceso total al disco?", "Muchas cachés y registros viven en carpetas que macOS protege. Sin acceso KeelMac sigue funcionando, pero omite esas carpetas y te dice cuáles."],
      ["¿Qué hace el asistente?", "Algunas tareas, como reconstruir el índice de Spotlight, necesitan permisos de administrador. El asistente solo puede ejecutar las tareas con nombre que ves en la app, y revisa cada ruta otra vez antes de tocarla."],
      ["¿Está en la Mac App Store?", "No. El aislamiento de la App Store no permite limpiar cachés en toda tu Biblioteca. Descárgala aquí o con Homebrew."],
      ["¿Envía mis datos a algún lado?", "No. KeelMac no tiene cuenta ni analíticas. Solo consulta este sitio para buscar actualizaciones."],
    ],
    footer: "KeelMac es software libre con licencia GPL-3.0.", releasesL: "Novedades", privacyL: "Privacidad", issue: "Reportar un problema",
    privacyTitle: "Privacidad", privacyBody: `
<p>KeelMac funciona por completo en tu Mac. No tiene cuenta, ni analíticas, ni telemetría.</p>
<h2>Qué sale de tu Mac</h2>
<p>Solo la búsqueda de actualizaciones: una vez al día (si las actualizaciones automáticas están activas) KeelMac descarga <code>appcast.xml</code> de este sitio para ver si hay una versión nueva. El perfil anónimo del sistema de Sparkle está desactivado. El proveedor de este sitio, Cloudflare, ve la solicitud como cualquier visita web.</p>
<h2>Qué se queda en tu Mac</h2>
<p>Los resultados de escaneo, el registro de operaciones, las instantáneas semanales y los ajustes se guardan en <code>~/Library/Application Support/KeelMac</code> y en las preferencias de KeelMac. Borra la app y esa carpeta para eliminarlo todo.</p>
<h2>Contenido de archivos</h2>
<p>KeelMac lee nombres, tamaños y fechas de archivos. Solo lee el contenido cuando buscas duplicados, para comparar archivos byte por byte, y nunca lo envía a ningún lado.</p>
<h2>Contacto</h2>
<p>Dudas o un problema de privacidad: <a href="${REPO}/issues">abre un issue en GitHub</a>.</p>`,
    releasesTitle: "Novedades", downloadVersion: (v) => `Descargar ${v}`,
    notFound: "Esa página no existe.", home: "Ir al inicio",
  },
};

function head(t, title, path) {
  return `<!doctype html>
<html lang="${t.lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<meta name="description" content="${t.description}">
<meta name="theme-color" content="#faf9f6" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#15120f" media="(prefers-color-scheme: dark)">
<link rel="icon" href="/icon.png">
<link rel="alternate" hreflang="en" href="${path.replace(/^\/es/, "") || "/"}">
<link rel="alternate" hreflang="es" href="/es${path.replace(/^\/es/, "")}">
<meta property="og:title" content="${title}">
<meta property="og:description" content="${t.description}">
<meta property="og:image" content="/icon.png">
<link rel="preload" href="/fonts/public-sans-latin-wght-normal.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="/styles.css">
</head>
<body>
<a class="skip" href="#main">${t.skip}</a>
<header class="site-header"><div class="wrap">
<a class="brand" href="${t.prefix}/" translate="no">${mark()}KeelMac</a>
<nav class="nav" aria-label="Main">
<a href="${t.prefix}/#safety">${t.safety}</a><a href="${t.prefix}/#faq">${t.faq}</a><a href="${REPO}">GitHub</a>
<a class="btn btn-primary" href="${t.prefix}/#download">${t.download}</a>
</nav>
</div></header>
<main id="main">
`;
}

function foot(t) {
  return `</main>
<footer class="site-footer"><div class="wrap">
<span>${t.footer}</span>
<nav aria-label="Footer"><a href="${t.prefix}/releases/">${t.releasesL}</a><a href="${t.prefix}/privacy/">${t.privacyL}</a><a href="${REPO}/issues">${t.issue}</a><a href="${t.other}" hreflang="${t.lang === "en" ? "es" : "en"}">${t.otherName}</a></nav>
</div></footer>
<script>
document.querySelectorAll("[data-copy]").forEach(function (b) {
  b.addEventListener("click", function () {
    navigator.clipboard.writeText(b.getAttribute("data-copy")).then(function () {
      var label = b.textContent; b.textContent = b.getAttribute("data-copied");
      var status = b.parentNode.querySelector("[data-copy-status]"); if (status) status.textContent = b.getAttribute("data-copied");
      setTimeout(function () { b.textContent = label; }, 1500);
    });
  });
});
</script>
</body>
</html>
`;
}

function gauge(t) {
  return `<div class="gauge" role="img" aria-label="${t.gaugeLabel}">
<div class="score">${t.score}</div>
<div class="muted num">${t.of}</div>
<div class="row"><strong>Macintosh HD</strong><span class="muted num">${t.used}</span></div>
<div class="hull"><div class="water"></div></div>
<div class="mark"><span class="tick"></span>${mark(44).replace('width="44"', 'width="44"')}</div>
<div class="margin-line num">${t.margin}</div>
</div>`;
}

function home(t) {
  const features = t.features.map(([key, h, p]) => `<div class="feature">
<div class="feature-copy"><h3>${h}</h3><p>${p}</p></div>
${shot(key) ? `<div class="feature-shot"><img src="/shots/${key}.png" alt="${h}" loading="lazy" width="1600" height="1058"></div>` : ""}
</div>`).join("\n");
  return head(t, t.title, t.prefix + "/") + `<section class="hero"><div class="wrap">
<div class="hero-copy">
<h1>${t.h1}</h1>
<p class="lede">${t.lede}</p>
<div id="download" class="cta-row">
<a class="btn btn-primary" href="${DOWNLOAD}">${t.cta}</a>
<div class="brew"><code translate="no">brew install --cask keelmac</code><button type="button" data-copy="brew install --cask keelmac" data-copied="${t.copied}" aria-label="${t.copyLabel}">${t.copy}</button><span class="sr-only" aria-live="polite" data-copy-status></span></div>
</div>
<p class="req">${t.req}</p>
</div>
<figure class="hero-figure">
${shot("dashboard") ? `<img src="/shots/dashboard.png" alt="${t.gaugeLabel}" width="1600" height="1058" fetchpriority="high">` : gauge(t)}
<figcaption>${t.caption}</figcaption>
</figure>
</div></section>
<section class="band"><div class="wrap section">
<h2>${t.toolsH}</h2>
<div class="features">
${features}
</div>
</div></section>
<section id="safety"><div class="wrap section split">
<div>
<h2>${t.safetyH}</h2>
<ul class="rules">${t.rules.map((r) => `<li>${r}</li>`).join("")}</ul>
</div>
<div>${shot("log") ? `<img src="/shots/log.png" alt="${t.logCaption}" loading="lazy" style="width:100%;height:auto;border-radius:10px;box-shadow:0 0 0 1px oklch(0.23 0.014 70 / .10)">` : gauge(t)}</div>
</div></section>
<section class="free"><div class="wrap section">
<div class="prose">
<h2 style="margin-top:0">${t.freeH}</h2>
<p>${t.free1}</p>
<p>${t.free2}</p>
</div>
</div></section>
<section id="faq"><div class="wrap section">
<h2>${t.faqH}</h2>
<div class="faq">${t.faqs.map(([q, a]) => `<details><summary>${q}</summary><p>${a}</p></details>`).join("\n")}</div>
</div></section>
` + foot(t);
}

function privacy(t) {
  return head(t, `${t.privacyTitle} · KeelMac`, t.prefix + "/privacy/") + `<div class="wrap"><div class="page-head"><h1>${t.privacyTitle}</h1></div><div class="prose section" style="padding-top:24px">${t.privacyBody}</div></div>` + foot(t);
}

function releasesPage(t) {
  const items = releases.map((r) => `<article style="border-top:1px solid var(--border);padding:24px 0">
<h2 style="margin:0 0 4px">KeelMac ${r.version}</h2>
<p class="muted num" style="margin-bottom:12px">${new Date(r.date).toLocaleDateString(t.lang === "es" ? "es-MX" : "en-US", { year: "numeric", month: "long", day: "numeric" })}</p>
<ul>${(r.notes[t.lang] || r.notes.en).map((n) => `<li>${n}</li>`).join("")}</ul>
<p><a class="btn btn-primary" href="${r.dmgURL}">${t.downloadVersion(r.version)}</a></p>
</article>`).join("\n");
  return head(t, `${t.releasesTitle} · KeelMac`, t.prefix + "/releases/") + `<div class="wrap"><div class="page-head"><h1>${t.releasesTitle}</h1></div><div class="prose section" style="padding-top:24px">${items}</div></div>` + foot(t);
}

function notFound(t) {
  return head(t, "Not found · KeelMac", "/") + `<div class="wrap section"><h1 style="font-size:32px">${t.notFound}</h1><p style="margin-top:16px"><a href="/">${t.home}</a></p></div>` + foot(t);
}

function write(rel, html) {
  const p = join(ROOT, rel);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, html);
}

for (const t of [T.en, T.es]) {
  const base = t.lang === "en" ? "" : "es/";
  write(`${base}index.html`, home(t));
  write(`${base}privacy/index.html`, privacy(t));
  write(`${base}releases/index.html`, releasesPage(t));
}
write("404.html", notFound(T.en));
write("_headers", `/*\n  X-Content-Type-Options: nosniff\n  Referrer-Policy: strict-origin-when-cross-origin\n  Permissions-Policy: interest-cohort=()\n/appcast.xml\n  Content-Type: application/rss+xml; charset=utf-8\n  Cache-Control: public, max-age=300\n/fonts/*\n  Cache-Control: public, max-age=31536000, immutable\n`);
console.log(`site: wrote 7 pages, ${releases.length} release(s)`);
