const TOKEN_KEY = "image_gallery_token";
const USER_KEY = "image_gallery_user";
const API_CACHE_TTL = 30_000;

const memoryCache = new Map();

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
    if (!prefix || key.startsWith(prefix)) memoryCache.delete(key);
  }
}

export function apiUrl(path) {
  if (/^https?:\/\//i.test(path)) return path;
  const normalized = path.startsWith("/") ? path : `/${path}`;
  return `${window.IMAGE_GALLERY_API_ORIGIN || ""}${normalized}`;
}

export async function apiFetch(path, options = {}) {
  const headers = new Headers(options.headers || {});
  const token = options.token ?? readToken();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (options.body && !(options.body instanceof FormData) && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  const response = await fetch(apiUrl(path), { ...options, headers });
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
  const ttl = options.ttl ?? API_CACHE_TTL;
  const token = options.token ?? readToken();
  const cacheKey = `${path}|${token ? "auth" : "anon"}`;
  const cached = memoryCache.get(cacheKey);
  const now = Date.now();
  if (cached && cached.expires > now) return cached.value;
  const value = await apiFetch(path, options);
  if (ttl > 0 && (!options.method || options.method === "GET")) {
    memoryCache.set(cacheKey, { value, expires: now + ttl });
  }
  return value;
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
