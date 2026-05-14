const TOKEN_KEY = "image_gallery_token";
const USER_KEY = "image_gallery_user";
const API_CACHE_TTL = 30_000;
const API_CACHE_STALE_TTL = 5 * 60_000;
const API_CACHE_VERSION = "v2";
const API_CACHE_STORE_PREFIX = "image_gallery_api_cache:";
const MAX_STORED_CACHE_BYTES = 700_000;
const REMOTE_ORIGIN_KEY = "image_gallery_remote_origin";

const memoryCache = new Map();
const inFlightFetches = new Map();
let remoteOriginPromise = null;

export function readToken() {
  try {
    return localStorage.getItem(TOKEN_KEY) || "";
  } catch (_error) {
    return "";
  }
}

export function writeToken(token) {
  try {
    if (token) localStorage.setItem(TOKEN_KEY, token);
    else localStorage.removeItem(TOKEN_KEY);
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

export function readStoredUser() {
  try {
    const raw = localStorage.getItem(USER_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch (_error) {
    return null;
  }
}

export function writeStoredUser(user) {
  try {
    if (user) localStorage.setItem(USER_KEY, JSON.stringify(user));
    else localStorage.removeItem(USER_KEY);
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

export function clearApiCache(prefix = "") {
  for (const key of Array.from(memoryCache.keys())) {
    if (!prefix || key.includes(`|${prefix}`)) memoryCache.delete(key);
  }
  for (const storage of [safeStorage(sessionStorage), safeStorage(localStorage)]) {
    if (!storage) continue;
    for (let index = storage.length - 1; index >= 0; index -= 1) {
      const key = storage.key(index);
      if (!key?.startsWith(API_CACHE_STORE_PREFIX)) continue;
      if (!prefix || key.includes(`|${prefix}`)) storage.removeItem(key);
    }
  }
}

export function apiUrl(path) {
  if (/^https?:\/\//i.test(path)) return path;
  const normalized = path.startsWith("/") ? path : `/${path}`;
  return `${currentApiOrigin()}${normalized}`;
}

export async function apiFetch(path, options = {}) {
  const headers = new Headers(options.headers || {});
  const token = options.token ?? readToken();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (!headers.has("Accept")) headers.set("Accept", "application/json");
  if (options.body && !(options.body instanceof FormData) && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  const response = await fetch(await resolveApiUrl(path), { ...options, headers });
  const contentType = response.headers.get("content-type") || "";
  const isJson = contentType.includes("application/json");
  const payload = isJson ? await response.json().catch(() => null) : await response.text();
  if (!response.ok) {
    const message = payload?.detail || payload?.message || payload || `Request failed (${response.status})`;
    const error = new Error(message);
    error.status = response.status;
    error.payload = payload;
    throw error;
  }
  return payload;
}

export async function cachedApiFetch(path, options = {}) {
  const method = String(options.method || "GET").toUpperCase();
  if (method !== "GET") return apiFetch(path, options);
  const ttl = options.ttl ?? API_CACHE_TTL;
  const staleTtl = options.staleTtl ?? API_CACHE_STALE_TTL;
  const token = options.token ?? readToken();
  const storage = options.storage === "local" ? safeStorage(localStorage) : safeStorage(sessionStorage);
  const cacheKey = `${API_CACHE_VERSION}|${path}|${token ? "auth" : "anon"}`;
  const now = Date.now();

  const cached = memoryCache.get(cacheKey) || readStoredCache(storage, cacheKey);
  if (cached) {
    memoryCache.set(cacheKey, cached);
    if (cached.expires > now) return cached.value;
    if (cached.staleUntil > now && options.allowStale !== false) {
      revalidateCache(cacheKey, path, options, ttl, staleTtl, storage);
      return cached.value;
    }
  }

  return revalidateCache(cacheKey, path, options, ttl, staleTtl, storage);
}

export function prefetchApi(path, options = {}) {
  cachedApiFetch(path, { ...options, allowStale: false }).catch(() => {});
}

export function toQuery(params) {
  const query = new URLSearchParams();
  Object.entries(params).forEach(([key, value]) => {
    if (value === undefined || value === null || value === "") return;
    query.set(key, String(value));
  });
  const serialized = query.toString();
  return serialized ? `?${serialized}` : "";
}

export async function resolveApiUrl(path) {
  if (/^https?:\/\//i.test(path)) return path;
  await ensureRemoteOrigin();
  return apiUrl(path);
}

function currentApiOrigin() {
  return String(window.IMAGE_GALLERY_API_ORIGIN || "").replace(/\/+$/, "");
}

function isRemoteStaticHost() {
  return Boolean(window.IMAGE_GALLERY_REMOTE_MODE) || window.location.hostname.endsWith("github.io");
}

function remoteConfigUrl() {
  if (window.IMAGE_GALLERY_CONFIG_URL) return window.IMAGE_GALLERY_CONFIG_URL;
  const basename = String(window.IMAGE_GALLERY_BASENAME || "").replace(/\/+$/, "");
  if (basename) return `${basename}/live-config.json`;
  return "live-config.json";
}

async function ensureRemoteOrigin() {
  if (currentApiOrigin() || !isRemoteStaticHost()) return currentApiOrigin();
  if (!remoteOriginPromise) {
    remoteOriginPromise = loadRemoteOrigin().finally(() => {
      remoteOriginPromise = null;
    });
  }
  return remoteOriginPromise;
}

async function loadRemoteOrigin() {
  const cached = readStorageValue(REMOTE_ORIGIN_KEY);
  if (cached) {
    window.IMAGE_GALLERY_API_ORIGIN = cached;
    return cached;
  }
  try {
    const response = await fetch(`${remoteConfigUrl()}?t=${Date.now()}`, { cache: "no-store" });
    if (!response.ok) return "";
    const config = await response.json();
    const origin = String(config.gallery_url || config.api_url || "").replace(/\/+$/, "");
    if (origin) {
      window.IMAGE_GALLERY_API_ORIGIN = origin;
      writeStorageValue(REMOTE_ORIGIN_KEY, origin);
    }
    return origin;
  } catch (_error) {
    return "";
  }
}

function revalidateCache(cacheKey, path, options, ttl, staleTtl, storage) {
  if (inFlightFetches.has(cacheKey)) return inFlightFetches.get(cacheKey);
  const promise = apiFetch(path, options)
    .then((value) => {
      if (ttl > 0) {
        const entry = {
          value,
          expires: Date.now() + ttl,
          staleUntil: Date.now() + ttl + Math.max(0, staleTtl),
        };
        memoryCache.set(cacheKey, entry);
        writeStoredCache(storage, cacheKey, entry);
      }
      return value;
    })
    .finally(() => inFlightFetches.delete(cacheKey));
  inFlightFetches.set(cacheKey, promise);
  return promise;
}

function readStorageValue(key) {
  try {
    return localStorage.getItem(key) || "";
  } catch (_error) {
    return "";
  }
}

function writeStorageValue(key, value) {
  try {
    if (value) localStorage.setItem(key, value);
    else localStorage.removeItem(key);
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

function safeStorage(storage) {
  try {
    const probe = "__image_gallery_cache_probe__";
    storage.setItem(probe, "1");
    storage.removeItem(probe);
    return storage;
  } catch (_error) {
    return null;
  }
}

function readStoredCache(storage, cacheKey) {
  if (!storage) return null;
  try {
    const raw = storage.getItem(API_CACHE_STORE_PREFIX + cacheKey);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (!parsed || parsed.staleUntil <= Date.now()) {
      storage.removeItem(API_CACHE_STORE_PREFIX + cacheKey);
      return null;
    }
    return parsed;
  } catch (_error) {
    return null;
  }
}

function writeStoredCache(storage, cacheKey, entry) {
  if (!storage) return;
  try {
    const raw = JSON.stringify(entry);
    if (raw.length > MAX_STORED_CACHE_BYTES) return;
    storage.setItem(API_CACHE_STORE_PREFIX + cacheKey, raw);
  } catch (_error) {
    pruneStoredCache(storage);
  }
}

function pruneStoredCache(storage) {
  try {
    const cacheKeys = [];
    for (let index = 0; index < storage.length; index += 1) {
      const key = storage.key(index);
      if (key?.startsWith(API_CACHE_STORE_PREFIX)) cacheKeys.push(key);
    }
    cacheKeys.slice(0, Math.ceil(cacheKeys.length / 3)).forEach((key) => storage.removeItem(key));
  } catch (_error) {
    // Storage quota cleanup is best-effort.
  }
}
