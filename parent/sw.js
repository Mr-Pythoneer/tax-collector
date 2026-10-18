// Network first: the app always asks the server for its files, so it's never out of date, and
// falls back to the copies kept here when the phone is offline or the server is slow to answer.
// The relay's API (/v1/) is never cached.
const CACHE = "tc-parent-2";

// Keep in step with FILES in server/lib/static.mjs.
const PRECACHE = [
  "/",
  "/app.css",
  "/manifest.webmanifest",
  "/js/app.js",
  "/js/ui.js",
  "/js/format.js",
  "/js/phone.js",
  "/js/db.js",
  "/js/linkcrypto.js",
  "/js/screens/common.js",
  "/js/screens/computers.js",
  "/js/screens/pair.js",
  "/js/screens/status.js",
  "/js/screens/lock.js",
  "/js/screens/tasks.js",
  "/js/screens/repeats.js",
  "/js/screens/apps.js",
  "/js/screens/settings.js",
  "/js/screens/more.js",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
  "/icons/maskable-512.png",
  "/icons/apple-touch-icon.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(PRECACHE)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin || url.pathname.startsWith("/v1/")) return;
  event.respondWith(networkFirst(request, url));
});

async function networkFirst(request, url) {
  const cache = await caches.open(CACHE);
  // Only the app's page is kept as "/": opening /manifest.webmanifest as a page mustn't replace it.
  const key = request.mode === "navigate" ? (url.pathname === "/" ? "/" : null) : url.pathname;
  const network = fetch(request).then(async (response) => {
    if (key && response.ok && response.type === "basic") await cache.put(key, response.clone());
    return response;
  });
  network.catch(() => {}); // answered from the cache instead
  // A slow network shouldn't keep a parent staring at a blank screen.
  const timeout = new Promise((resolve) => setTimeout(resolve, 4000, null));
  try {
    const first = await Promise.race([network, timeout]);
    if (first) return first;
    const cached = await cache.match(key ?? url.pathname);
    return cached ?? (await network);
  } catch {
    const cached = await cache.match(key ?? url.pathname);
    return cached ?? Response.error();
  }
}
