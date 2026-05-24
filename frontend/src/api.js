const TOKEN_KEY = "image_gallery_token";
const USER_KEY = "image_gallery_user";
const API_CACHE_TTL = 30_000;
const API_CACHE_STALE_TTL = 5 * 60_000;
const API_CACHE_VERSION = "v5";
const API_CACHE_STORE_PREFIX = "image_gallery_api_cache:";
const MAX_STORED_CACHE_BYTES = 700_000;
const REMOTE_ORIGIN_KEY = "image_gallery_remote_origin";
const REMOTE_ORIGIN_TTL = 60_000;
const REMOTE_ORIGIN_STALE_TTL = 15 * 60_000;
const API_FETCH_TIMEOUT_MS = 25_000;
const REMOTE_CONFIG_TIMEOUT_MS = 8_000;

const memoryCache = new Map();
const inFlightFetches = new Map();
let remoteOriginPromise = null;
let remoteOriginRefreshAfter = 0;
let remoteConfig = null;

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
  const response = await fetchWithRemoteRetry(path, options, headers);
  const contentType = response.headers.get("content-type") || "";
  const isJson = contentType.includes("application/json");
  const payload = isJson ? await response.json().catch(() => null) : await response.text();
  if (!response.ok) {
    const error = new Error(errorMessage(payload, response.status));
    error.status = response.status;
    error.payload = payload;
    throw error;
  }
  return payload;
}

function errorMessage(payload, status) {
  const raw = payload?.detail || payload?.message || payload;
  if (!raw) return `Request failed (${status})`;
  if (Array.isArray(raw)) {
    return raw.map((item) => item?.msg || item?.message || JSON.stringify(item)).join("; ");
  }
  if (typeof raw === "object") {
    return raw.msg || raw.message || JSON.stringify(raw);
  }
  return String(raw);
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
  if (!isRemoteStaticHost()) return currentApiOrigin();
  if (currentApiOrigin() && remoteOriginRefreshAfter > Date.now()) return currentApiOrigin();
  if (!remoteOriginPromise) {
    remoteOriginPromise = loadRemoteOrigin().finally(() => {
      remoteOriginPromise = null;
    });
  }
  return remoteOriginPromise;
}

async function refreshRemoteOrigin() {
  if (!isRemoteStaticHost()) return currentApiOrigin();
  remoteOriginPromise = loadRemoteOrigin({ force: true }).finally(() => {
    remoteOriginPromise = null;
  });
  return remoteOriginPromise;
}

async function loadRemoteOrigin({ force = false } = {}) {
  const cached = readRemoteOriginCache();
  if (!force && cached?.origin && cached.updatedAt && Date.now() - cached.updatedAt < REMOTE_ORIGIN_TTL) {
    applyRemoteOrigin(cached);
    return cached.origin;
  }
  try {
    const response = await fetchWithTimeout(`${remoteConfigUrl()}?t=${Date.now()}`, { cache: "no-store" }, REMOTE_CONFIG_TIMEOUT_MS);
    if (!response.ok) throw new Error(`Remote config failed (${response.status})`);
    const text = await response.text();
    const config = parseRemoteConfig(text);
    const origin = validApiOrigin(config.gallery_url || config.api_url);
    if (origin) {
      const entry = { origin, localUrls: normalizeLocalUrls(config.local_urls), updatedAt: Date.now() };
      applyRemoteOrigin(entry);
      writeRemoteOriginCache(entry);
      return origin;
    }
    remoteConfig = config || null;
  } catch (_error) {
    if (cached?.origin && (!cached.updatedAt || Date.now() - cached.updatedAt < REMOTE_ORIGIN_STALE_TTL)) {
      applyRemoteOrigin(cached);
      return cached.origin;
    }
  }
  clearRemoteOriginCache();
  return "";
}

async function fetchWithRemoteRetry(path, options, headers) {
  const target = await resolveApiUrl(path);
  options = { ...options, __path: path };
  try {
    const response = await fetchWithTimeout(target, { ...options, headers }, options.timeoutMs || API_FETCH_TIMEOUT_MS);
    if (shouldRefreshRemoteAfterStatus(response.status, options)) {
      const retryTarget = await retryTargetFor(path, target, options);
      if (retryTarget && retryTarget !== target) {
        return fetchWithTimeout(retryTarget, { ...options, headers }, options.timeoutMs || API_FETCH_TIMEOUT_MS);
      }
    }
    return response;
  } catch (error) {
    const retryTarget = await retryTargetFor(path, target, options);
    if (retryTarget && retryTarget !== target) {
      return fetchWithTimeout(retryTarget, { ...options, headers }, options.timeoutMs || API_FETCH_TIMEOUT_MS);
    }
    throw error;
  }
}

async function retryTargetFor(path, failedTarget, options) {
  if (!canRetryWithFreshRemote(options)) return "";
  const failedOrigin = originFromUrl(failedTarget) || currentApiOrigin();
  await refreshRemoteOrigin();
  const refreshed = apiUrl(path);
  if (refreshed && refreshed !== failedTarget) return refreshed;
  return fallbackApiUrl(path, failedOrigin);
}

function shouldRefreshRemoteAfterStatus(status, options) {
  if (!canRetryWithFreshRemote(options)) return false;
  return status === 404 || status === 405 || status === 502 || status === 503 || status === 504 || (status >= 520 && status <= 526);
}

function canRetryWithFreshRemote(options) {
  const method = String(options.method || "GET").toUpperCase();
  if (!isRemoteStaticHost()) return false;
  if (method === "GET" || method === "HEAD") return true;
  const path = String(options.__path || "");
  if (method === "POST" && isSafeRemoteRetryPost(path)) return true;
  return false;
}

function isSafeRemoteRetryPost(path) {
  return /^\/api\/auth\/(login|register|resend-verification)/.test(path);
}

function fallbackApiUrl(path, failedOrigin) {
  const origin = localOriginFallback(failedOrigin);
  if (!origin) return "";
  const normalized = path.startsWith("/") ? path : `/${path}`;
  return `${origin}${normalized}`;
}

function localOriginFallback(failedOrigin) {
  const localUrls = normalizeLocalUrls(remoteConfig?.local_urls);
  for (const origin of localUrls) {
    if (!origin || origin === failedOrigin) continue;
    if (window.location.protocol === "https:" && !/^http:\/\/(localhost|127\.0\.0\.1|\[::1\])(?::|$)/i.test(origin)) continue;
    return origin;
  }
  return "";
}

function applyRemoteOrigin(entry) {
  const origin = String(entry?.origin || "").replace(/\/+$/, "");
  const current = currentApiOrigin();
  window.IMAGE_GALLERY_API_ORIGIN = origin;
  remoteOriginRefreshAfter = Date.now() + REMOTE_ORIGIN_TTL;
  remoteConfig = { ...(remoteConfig || {}), local_urls: normalizeLocalUrls(entry?.localUrls || entry?.local_urls) };
  if (origin && current && current !== origin) clearApiCache();
}

function readRemoteOriginCache() {
  const raw = readStorageValue(REMOTE_ORIGIN_KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    if (parsed?.origin) {
      return {
        origin: String(parsed.origin).replace(/\/+$/, ""),
        localUrls: normalizeLocalUrls(parsed.localUrls || parsed.local_urls),
        updatedAt: Number(parsed.updatedAt || 0),
      };
    }
  } catch (_error) {
    return { origin: raw.replace(/\/+$/, ""), localUrls: [], updatedAt: 0 };
  }
  return null;
}

function writeRemoteOriginCache(entry) {
  try {
    localStorage.setItem(REMOTE_ORIGIN_KEY, JSON.stringify(entry));
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

function clearRemoteOriginCache() {
  window.IMAGE_GALLERY_API_ORIGIN = "";
  remoteOriginRefreshAfter = 0;
  try {
    localStorage.removeItem(REMOTE_ORIGIN_KEY);
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

function parseRemoteConfig(text) {
  const raw = String(text || "").trim();
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch (_error) {
    const extracted = extractFirstJsonObject(raw);
    if (extracted) {
      try {
        return JSON.parse(extracted);
      } catch (_innerError) {
        // Fall through to field-level salvage below.
      }
    }
    return salvageRemoteConfig(raw);
  }
}

function extractFirstJsonObject(raw) {
  const start = raw.indexOf("{");
  if (start < 0) return "";
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < raw.length; index += 1) {
    const ch = raw[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') inString = true;
    else if (ch === "{") depth += 1;
    else if (ch === "}") {
      depth -= 1;
      if (depth === 0) return raw.slice(start, index + 1);
    }
  }
  return "";
}

function salvageRemoteConfig(raw) {
  const pick = (name) => {
    const match = raw.match(new RegExp(`"${name}"\\s*:\\s*"([^"]*)"`));
    return match ? match[1] : "";
  };
  let localUrls = [];
  const localMatch = raw.match(/"local_urls"\s*:\s*(\[[\s\S]*?\])/);
  if (localMatch) {
    try {
      const parsed = JSON.parse(localMatch[1]);
      if (Array.isArray(parsed)) localUrls = parsed;
    } catch (_error) {
      localUrls = [];
    }
  }
  return {
    gallery_url: pick("gallery_url"),
    api_url: pick("api_url"),
    status: pick("status"),
    local_urls: localUrls,
    updated_at: pick("updated_at"),
  };
}

function normalizeLocalUrls(urls) {
  if (!Array.isArray(urls)) return [];
  return urls.map((url) => validApiOrigin(url)).filter(Boolean);
}

function validApiOrigin(value) {
  const raw = String(value || "").trim();
  if (!raw) return "";
  try {
    const parsed = new URL(raw, window.location.href);
    if (!["http:", "https:"].includes(parsed.protocol)) return "";
    const host = parsed.hostname.toLowerCase();
    const isLocal = host === "localhost" || host === "127.0.0.1" || host === "::1" || /^10\./.test(host) || /^192\.168\./.test(host) || /^172\.(1[6-9]|2\d|3[01])\./.test(host);
    if (window.location.protocol === "https:" && parsed.protocol !== "https:" && !isLocal) return "";
    return parsed.origin.replace(/\/+$/, "");
  } catch (_error) {
    return "";
  }
}

async function fetchWithTimeout(url, options = {}, timeoutMs = API_FETCH_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), Math.max(1000, Number(timeoutMs) || API_FETCH_TIMEOUT_MS));
  try {
    return await fetch(url, { ...options, signal: options.signal || controller.signal });
  } finally {
    window.clearTimeout(timer);
  }
}

function originFromUrl(url) {
  try {
    return new URL(url, window.location.href).origin.replace(/\/+$/, "");
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
