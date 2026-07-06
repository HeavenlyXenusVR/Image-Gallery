// Minimal, conservative PWA service worker.
//
// Scope is intentionally the whole site ("/"), served from the root so it can control
// navigations to client-routed pages like /media/123 and /users/alice (see
// app/routers/pages.py's /service-worker.js route for why it isn't under /static/react/).
//
// It never touches API requests or cross-origin requests (media/API can live on a
// different tunnel/CDN origin than the page) — it only helps the app shell and its
// built JS/CSS/image assets load instantly and survive brief offline blips.
const CACHE_VERSION = "gallery-shell-v1";

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(
      keys.filter((key) => key !== CACHE_VERSION).map((key) => caches.delete(key)),
    )).then(() => self.clients.claim()),
  );
});

function isCacheableAsset(url) {
  return url.pathname.startsWith("/static/react/assets/")
    || url.pathname.startsWith("/static/react/pwa-")
    || url.pathname === "/static/react/apple-touch-icon.png"
    || url.pathname === "/favicon.ico";
}

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith("/api/")) return;

  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request).catch(() => caches.match("/").then((cached) => cached || Response.error())),
    );
    return;
  }

  if (isCacheableAsset(url)) {
    event.respondWith(
      caches.open(CACHE_VERSION).then(async (cache) => {
        const cached = await cache.match(request);
        const networkFetch = fetch(request).then((response) => {
          if (response.ok) cache.put(request, response.clone());
          return response;
        }).catch(() => cached);
        return cached || networkFetch;
      }),
    );
  }
});
