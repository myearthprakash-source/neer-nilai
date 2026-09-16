// Neer Nilai service worker: network first, cache fallback, so the app opens offline
// and updates as soon as the phone is online. Version is stamped by build.js.
const CACHE = "neer-nilai-__VERSION__";
const SHELL = [
  "./", "./index.html", "./manifest.webmanifest",
  "./officer/", "./officer/index.html", "./officer/manifest.webmanifest",
  "./icons/icon-192.png", "./icons/icon-512.png", "./icons/icon-maskable-512.png",
];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== self.location.origin) return; // Supabase, fonts, CDN: untouched
  e.respondWith(
    fetch(e.request)
      .then((res) => { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(e.request, copy)); return res; })
      .catch(() => caches.match(e.request, { ignoreSearch: true }).then((hit) =>
        hit || caches.match(url.pathname.includes("/officer") ? "./officer/index.html" : "./index.html"))),
  );
});
