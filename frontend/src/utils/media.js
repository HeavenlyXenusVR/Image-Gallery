const preloadedMedia = new Set();
const preloadQueue = [];
let activePreloads = 0;
const MAX_PRELOADS = 2;
const MAX_SEEN_PRELOADS = 700;

export function isPerfLiteRuntime() {
  if (typeof document === "undefined") return false;
  return document.documentElement.classList.contains("perf-lite");
}

function defaultThumbWidth() {
  return isPerfLiteRuntime() ? 360 : 640;
}

function scheduleIdle(callback) {
  if (typeof window === "undefined") return;
  if ("requestIdleCallback" in window) {
    window.requestIdleCallback(callback, { timeout: 1600 });
  } else {
    window.setTimeout(callback, 80);
  }
}

function pumpPreloadQueue() {
  if (typeof Image === "undefined") return;
  while (activePreloads < MAX_PRELOADS && preloadQueue.length) {
    const src = preloadQueue.shift();
    activePreloads += 1;
    const image = new Image();
    image.decoding = "async";
    image.loading = "eager";
    image.onload = image.onerror = () => {
      activePreloads = Math.max(0, activePreloads - 1);
      scheduleIdle(pumpPreloadQueue);
    };
    image.src = src;
  }
}

export function thumbUrl(item, width = defaultThumbWidth()) {
  if (!item || item.locked) return "";
  if (item.thumb_url) return item.thumb_url;
  if (item.media_kind === "image" && item.preview_url) return item.preview_url;
  if (item.media_kind === "image" && item.id) return `/api/media/${item.id}/thumb?w=${width}`;
  return "";
}

export function replaceMedia(rows, updated) {
  if (!updated) return rows;
  return rows.map((item) => Number(item.id) === Number(updated.id) ? updated : item);
}

export function preloadMediaAssets(items, options = {}) {
  if (typeof Image === "undefined") return;
  const perfLite = isPerfLiteRuntime();
  const limit = Math.max(0, Math.min(Number(options.limit || (perfLite ? 2 : 6)), perfLite ? 3 : 12));
  for (const item of (items || []).slice(0, limit)) {
    if (item?.media_kind === "video") continue;
    const src = thumbUrl(item, options.width || defaultThumbWidth());
    if (!src || preloadedMedia.has(src)) continue;
    preloadedMedia.add(src);
    preloadQueue.push(src);
  }
  if (preloadedMedia.size > MAX_SEEN_PRELOADS) {
    for (const src of preloadedMedia) {
      preloadedMedia.delete(src);
      if (preloadedMedia.size <= Math.floor(MAX_SEEN_PRELOADS * 0.7)) break;
    }
  }
  scheduleIdle(pumpPreloadQueue);
}
