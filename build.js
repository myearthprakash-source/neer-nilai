// Builds docs/ (GitHub Pages) from src/app.html.
//   node build.js
// Demo (sample data kept on the phone):   docs/index.html (tank operator), docs/review/ (panchayat officer), docs/officer/ (block/district)
// Live (Supabase), only when supabase/live.public.json exists:   docs/live/, docs/live/review/, docs/live/officer/
//   live.public.json = { "SUPABASE_URL": "https://<ref>.supabase.co", "SUPABASE_ANON_KEY": "<anon / publishable key>" }
//   Both values are public by design (they ship in the page); the database is protected by its functions and row-level security.
const fs = require("fs");
const path = require("path");

const root = __dirname;
const src = fs.readFileSync(path.join(root, "src", "app.html"), "utf8");
const swSrc = fs.readFileSync(path.join(root, "src", "sw.js"), "utf8");
const version = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 12);
const CONFIG_LINE = 'const CONFIG = { SUPABASE_URL: "", SUPABASE_ANON_KEY: "" };';
if (!src.includes(CONFIG_LINE)) throw new Error("CONFIG line not found in src/app.html");

function page(prefix, title, config) {
  const body = config ? src.replace(CONFIG_LINE, `const CONFIG = ${JSON.stringify({ SUPABASE_URL: config.SUPABASE_URL, SUPABASE_ANON_KEY: config.SUPABASE_ANON_KEY })};`) : src;
  return `<!doctype html>
<html lang="ta">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#1D6FB4">
<meta name="color-scheme" content="light">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<meta name="apple-mobile-web-app-title" content="${title}">
<link rel="manifest" href="./manifest.webmanifest">
<link rel="icon" href="${prefix}icons/icon-192.png">
<link rel="apple-touch-icon" href="${prefix}icons/icon-192.png">
${body.replace("<title>Neer Nilai</title>", `<title>${title}</title>`)}
</head>
</html>
`;
}

function manifest(name, shortName, iconPrefix) {
  return JSON.stringify({
    name, short_name: shortName, description: "Daily water supply monitoring for panchayat tanks (GLR and OHT)",
    start_url: "./", scope: "./", display: "standalone", orientation: "portrait",
    background_color: "#F5F7F8", theme_color: "#1D6FB4", lang: "ta",
    icons: [
      { src: `${iconPrefix}icons/icon-192.png`, sizes: "192x192", type: "image/png", purpose: "any" },
      { src: `${iconPrefix}icons/icon-512.png`, sizes: "512x512", type: "image/png", purpose: "any" },
      { src: `${iconPrefix}icons/icon-maskable-512.png`, sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
  }, null, 2) + "\n";
}

// One variant = three pages + manifests + service worker in `dir`. `up` is the path from dir back to docs/ (for icons).
function variant(dir, up, names, config) {
  for (const sub of ["", "officer", "review"]) fs.mkdirSync(path.join(dir, sub), { recursive: true });
  fs.writeFileSync(path.join(dir, "index.html"), page(up, names.op, config));
  fs.writeFileSync(path.join(dir, "review", "index.html"), page("../" + up, names.rv, config));
  fs.writeFileSync(path.join(dir, "officer", "index.html"), page("../" + up, names.of, config));
  fs.writeFileSync(path.join(dir, "manifest.webmanifest"), manifest(names.op, names.opShort, up));
  fs.writeFileSync(path.join(dir, "review", "manifest.webmanifest"), manifest(names.rv, names.rvShort, "../" + up));
  fs.writeFileSync(path.join(dir, "officer", "manifest.webmanifest"), manifest(names.of, names.ofShort, "../" + up));
  fs.writeFileSync(path.join(dir, "sw.js"), swSrc.replace("__VERSION__", version).replace("__VARIANT__", config ? "live" : "demo").replaceAll("__ICONS__", up));
}

const docs = path.join(root, "docs");
fs.mkdirSync(path.join(docs, "icons"), { recursive: true });
fs.rmSync(path.join(docs, "cards"), { recursive: true, force: true });   // QR cards were dropped: sign-in is phone + PIN

variant(docs, "./", { op: "Neer Nilai Demo", opShort: "NN Demo", rv: "Neer Nilai Review Demo", rvShort: "NN Review Demo", of: "Neer Nilai Officer Demo", ofShort: "NN Officer Demo" }, null);

const cfgPath = path.join(root, "supabase", "live.public.json");
if (fs.existsSync(cfgPath)) {
  const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
  if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(cfg.SUPABASE_URL || "") || !cfg.SUPABASE_ANON_KEY) throw new Error("supabase/live.public.json needs SUPABASE_URL and SUPABASE_ANON_KEY");
  variant(path.join(docs, "live"), "../", { op: "Neer Nilai", opShort: "Neer Nilai", rv: "Neer Nilai Review", rvShort: "NN Review", of: "Neer Nilai Officer", ofShort: "NN Officer" }, cfg);
  console.log("built docs/ (demo) and docs/live/ (live:", cfg.SUPABASE_URL + ") version", version);
} else {
  fs.rmSync(path.join(docs, "live"), { recursive: true, force: true });
  console.log("built docs/ (demo only; add supabase/live.public.json for docs/live/) version", version);
}
