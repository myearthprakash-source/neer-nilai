// Builds docs/ (GitHub Pages) from src/app.html.
//   node build.js
// Outputs: docs/index.html (operator), docs/officer/index.html (officer), docs/sw.js, manifests.
const fs = require("fs");
const path = require("path");

const root = __dirname;
const src = fs.readFileSync(path.join(root, "src", "app.html"), "utf8");
const version = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 12);

function page(prefix, title) {
  return `<!doctype html>
<html lang="ta">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#1D6FB4">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<meta name="apple-mobile-web-app-title" content="${title}">
<link rel="manifest" href="./manifest.webmanifest">
<link rel="icon" href="${prefix}icons/icon-192.png">
<link rel="apple-touch-icon" href="${prefix}icons/icon-192.png">
${src.replace("<title>Neer Nilai</title>", `<title>${title}</title>`)}
</head>
</html>
`;
}

function manifest(name, shortName, startUrl, iconPrefix) {
  return JSON.stringify({
    name, short_name: shortName, description: "Panchayat water delivery monitoring",
    start_url: startUrl, scope: startUrl, display: "standalone", orientation: "portrait",
    background_color: "#F3F6F4", theme_color: "#1D6FB4", lang: "ta",
    icons: [
      { src: `${iconPrefix}icons/icon-192.png`, sizes: "192x192", type: "image/png", purpose: "any" },
      { src: `${iconPrefix}icons/icon-512.png`, sizes: "512x512", type: "image/png", purpose: "any" },
      { src: `${iconPrefix}icons/icon-maskable-512.png`, sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
  }, null, 2) + "\n";
}

const docs = path.join(root, "docs");
fs.mkdirSync(path.join(docs, "officer"), { recursive: true });
fs.writeFileSync(path.join(docs, "index.html"), page("./", "Neer Nilai"));
fs.writeFileSync(path.join(docs, "officer", "index.html"), page("../", "Neer Nilai Officer"));
fs.writeFileSync(path.join(docs, "manifest.webmanifest"), manifest("Neer Nilai", "Neer Nilai", "./", "./"));
fs.writeFileSync(path.join(docs, "officer", "manifest.webmanifest"), manifest("Neer Nilai Officer", "NN Officer", "./", "../"));

const sw = fs.readFileSync(path.join(root, "src", "sw.js"), "utf8").replace("__VERSION__", version);
fs.writeFileSync(path.join(docs, "sw.js"), sw);

// Keep the old web/ path out of the way; nothing else to do.
console.log("built docs/ version", version);
