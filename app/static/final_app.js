const API_BASE = "/api";
const REMOTE_MODE = window.location.hostname.endsWith("github.io");
const CONFIG_FILE = "live-config.json";
const TOKEN_KEY = "image_gallery_token";
const USER_KEY = "image_gallery_user";
const SITE_BACKGROUND_KEY = "image_gallery_site_background";
const REMOTE_ORIGIN_KEY = "image_gallery_remote_origin";
const GALLERY_VIEW_KEY = "image_gallery_view";
const SAVED_VIEWS_KEY = "image_gallery_saved_views";
const MAX_UPLOAD_BYTES = 500 * 1024 * 1024;
const GALLERY_PAGE_SIZE = 15;
const LOW_POWER_GALLERY_PAGE_SIZE = 12;
const COMPARE_SELECTION_LIMIT = 4;
const LIVE_CHECK_INTERVAL_MS = 15000;
const LOW_POWER_LIVE_CHECK_INTERVAL_MS = 45000;
const SITE_BACKGROUND_REFRESH_MS = 5 * 60 * 1000;
const SEARCH_DEBOUNCE_MS = 250;
const API_REQUEST_TIMEOUT_MS = 30000;
const LIVE_CHECK_MIN_GAP_MS = 5000;
const GALLERY_ASSET_PRELOAD_LIMIT = 10;
const LOW_POWER_GALLERY_ASSET_PRELOAD_LIMIT = 4;
const GALLERY_ASSET_PRELOAD_CACHE_LIMIT = 240;
const DEFAULT_USER_SETTINGS = {
  theme_mode: "system",
  accent_color: "#37c9a7",
  grid_density: "comfortable",
  default_sort: "new",
  items_per_page: GALLERY_PAGE_SIZE,
  autoplay_previews: false,
  muted_previews: true,
  reduce_motion: false,
  open_original_in_new_tab: false,
  blur_video_previews: false,
  profile_show_uploads: true,
  profile_show_collections: true,
  profile_show_friends: true,
  profile_show_follow_counts: true,
  profile_layout: "spotlight",
  profile_banner_style: "gradient",
  profile_card_style: "glass",
  profile_stat_style: "tiles",
  profile_content_focus: "balanced",
  profile_hero_alignment: "split",
  profile_show_joined_date: true,
};
const ACCOUNT_NAVIGATION = {
  signedOutUsernameTarget: "auth",
  signedInUsernameTarget: "profile",
  sidebarProfileTarget: "profile",
  settingsTarget: "settings",
};
const rawFetch = window.fetch.bind(window);
const storageFallback = new Map();

let apiOrigin = "";
let token = readStore(TOKEN_KEY);
let currentUser = readJsonStore(USER_KEY);
let categories = [];
let mediaItems = [];
let collectionsState = [];
let galleryMode = "main";
let galleryPage = 1;
let galleryHasNext = false;
let galleryLoading = false;
let latestLiveSnapshot = null;
let activeDetail = null;
let selectedCollectionMediaId = null;
let selectedReportMediaId = null;
let registerMode = false;
let uploadInFlight = false;
let uploadStartedAt = 0;
let uploadAiBusy = false;
let uploadAiAnalysis = null;
let activeProfileUsername = "";
let galleryViewRestored = false;
let toastTimer = 0;
let compareSelection = new Set();
let slideshowIndex = 0;
let slideshowTimer = 0;
let slideshowPlaying = false;
let slideshowItemsOverride = null;
let detailZoom = 1;
let detailRotation = 0;
const revealedAdultMedia = new Set();
let localBackendUrls = [];
let remoteConfigRefreshPromise = null;
let currentPage = "discover";
let routeSyncInProgress = false;
let activeCollectionId = null;
let collectionsMineMode = false;
let profilePageData = null;
let profileCustomizeOpen = false;
let friendPanelState = { incoming: [], outgoing: [], friends: [] };
let studioPageState = { items: [], totals: { views: 0, downloads: 0, likes: 0 } };
let siteBackgroundTimer = 0;
let revealObserver = null;
let detectedLowPowerDevice = null;
let galleryLoadController = null;
let galleryRequestId = 0;
let liveCheckInFlight = null;
let lastLiveCheckAt = 0;
let galleryAssetPreloadHandle = 0;
const galleryAssetPreloadCache = new Set();
const PAGE_ROUTES = {
  discover: "/",
  following: "/following",
  liked: "/liked",
  collections: "/collections",
  users: "/users",
  friends: "/friends",
  studio: "/studio",
  profile: "/profile",
};

const $ = (id) => document.getElementById(id);

function safeEl(id) {
  return document.getElementById(id);
}

function galleryPageSize() {
  const explicit = currentUser?.user_settings?.items_per_page;
  const fallback = isLowPowerMode() ? LOW_POWER_GALLERY_PAGE_SIZE : GALLERY_PAGE_SIZE;
  const raw = Number(explicit || fallback);
  const max = isLowPowerMode() ? 24 : 60;
  return Math.max(isLowPowerMode() ? 9 : 15, Math.min(raw || fallback, max));
}

function isLowPowerDevice() {
  if (detectedLowPowerDevice !== null) return detectedLowPowerDevice;
  const nav = typeof navigator !== "undefined" ? navigator : {};
  const conn = nav.connection || nav.mozConnection || nav.webkitConnection;
  const cores = Number(nav.hardwareConcurrency || 0);
  const memory = Number(nav.deviceMemory || 0);
  detectedLowPowerDevice = Boolean(
    prefersReducedMotion()
    || conn?.saveData
    || (cores && cores <= 4)
    || (memory && memory <= 4)
  );
  return detectedLowPowerDevice;
}

function isLowPowerMode() {
  return Boolean(document.body?.classList.contains("panel-low-power") || document.body?.dataset.reduceMotion === "1" || isLowPowerDevice());
}

function debounce(fn, delay = 160) {
  let timer = 0;
  return (...args) => {
    clearTimeout(timer);
    timer = window.setTimeout(() => fn(...args), delay);
  };
}

function applyRuntimePerformanceMode() {
  const lowPower = isLowPowerDevice() || userSettings().reduce_motion;
  document.body?.classList.toggle("panel-low-power", Boolean(lowPower));
  document.body?.classList.toggle("panel-full-effects", !lowPower);
}

function on(id, eventName, handler) {
  const el = safeEl(id);
  if (el) el.addEventListener(eventName, handler);
  return el;
}

function setTextIfPresent(id, value) {
  const el = safeEl(id);
  if (el) el.textContent = value;
}

function showIfPresent(id, visible) {
  const el = safeEl(id);
  if (el) el.hidden = !visible;
}

function setDisabledIfPresent(id, disabled) {
  const el = safeEl(id);
  if (el) el.disabled = Boolean(disabled);
}

function prefersReducedMotion() {
  return document.body?.dataset.reduceMotion === "1" || window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches;
}

function ensureRevealObserver() {
  if (revealObserver || prefersReducedMotion() || typeof IntersectionObserver === "undefined") return revealObserver;
  revealObserver = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add("is-visible");
      revealObserver?.unobserve(entry.target);
    }
  }, { threshold: 0.16, rootMargin: "0px 0px -8% 0px" });
  return revealObserver;
}

function motionTargets(root = document) {
  if (!root?.querySelectorAll) return [];
  return root.querySelectorAll([
    ".discover-hero-shell",
    ".page-hero",
    ".sidebar-block",
    ".stats-grid",
    ".account-card",
    ".sidebar-note",
    ".media-card",
    ".page-panel",
    ".collection-card",
    ".saved-view-card",
    ".studio-item",
    ".user-card",
    ".profile-showcase",
    ".profile-insight-card",
    ".profile-section-card",
    ".upload-queue-item",
  ].join(","));
}

function enhanceMotion(root = document) {
  const targets = Array.from(motionTargets(root));
  if (!targets.length) return;
  if (prefersReducedMotion() || isLowPowerMode()) {
    targets.forEach((node) => {
      node.classList.remove("reveal-ready");
      node.classList.add("is-visible");
      node.style.removeProperty("--reveal-delay");
    });
    return;
  }
  const observer = ensureRevealObserver();
  targets.forEach((node, index) => {
    if (node.dataset.motionReady === "1") return;
    node.dataset.motionReady = "1";
    node.classList.add("reveal-ready");
    node.style.setProperty("--reveal-delay", `${Math.min(index, 10) * 36}ms`);
    observer?.observe(node);
  });
}

function showToast(message, kind = "info") {
  const region = safeEl("toast-region");
  if (!region) return;
  region.textContent = message || "";
  region.dataset.kind = kind;
  region.hidden = !message;
  clearTimeout(toastTimer);
  if (message) toastTimer = setTimeout(() => { region.hidden = true; }, 3200);
}

function getStorageCandidates() {
  const stores = [];
  try { if (window.localStorage) stores.push(window.localStorage); } catch (_err) {}
  try { if (window.sessionStorage) stores.push(window.sessionStorage); } catch (_err) {}
  return stores;
}

function readStore(key) {
  for (const store of getStorageCandidates()) {
    try {
      const value = store.getItem(key);
      if (value !== null && value !== undefined) return value;
    } catch (_err) {}
  }
  return storageFallback.get(key) || "";
}

function writeStore(key, value) {
  const normalized = String(value || "");
  if (normalized) storageFallback.set(key, normalized);
  else storageFallback.delete(key);
  for (const store of getStorageCandidates()) {
    try {
      if (normalized) store.setItem(key, normalized);
      else store.removeItem(key);
    } catch (_err) {}
  }
}

function readJsonStore(key) {
  try { return JSON.parse(readStore(key) || "null"); } catch (_err) { return null; }
}

function readSavedViews() {
  const views = readJsonStore(SAVED_VIEWS_KEY);
  return Array.isArray(views) ? views : [];
}

function writeSavedViews(views) {
  writeStore(SAVED_VIEWS_KEY, JSON.stringify(Array.isArray(views) ? views : []));
}

function normalizeRemoteOrigin(value) {
  let normalized = String(value || "").trim();
  if (!normalized) return "";
  if (!/^https?:\/\//i.test(normalized)) normalized = `https://${normalized}`;
  try {
    const url = new URL(normalized);
    return `${url.protocol}//${url.host}`;
  } catch (_err) {
    normalized = normalized.replace(/\/+$/, "");
    normalized = normalized.replace(/\/(?:index\.html?)$/i, "");
    normalized = normalized.replace(/\/api$/i, "");
    return normalized;
  }
}

function setApiOrigin(value, persist = true) {
  apiOrigin = normalizeRemoteOrigin(value);
  if (persist) writeStore(REMOTE_ORIGIN_KEY, apiOrigin);
  return apiOrigin;
}

function buildStaticUrl(path) {
  try {
    return new URL(path, window.location.href).toString();
  } catch (_err) {
    return path;
  }
}

async function copyText(value, successMessage = "Copied.") {
  const text = String(value || "");
  if (!text) return false;
  try {
    await navigator.clipboard.writeText(text);
  } catch (_err) {
    const temp = document.createElement("input");
    temp.value = text;
    document.body.appendChild(temp);
    temp.select();
    document.execCommand("copy");
    temp.remove();
  }
  showToast(successMessage, "success");
  return true;
}

function apiUrl(path) {
  const normalized = path.startsWith("/") ? path : `${API_BASE}/${path}`;
  return `${apiOrigin}${normalized}`;
}

function normalizeApiAssetUrl(value) {
  const raw = String(value || "").trim();
  if (!raw) return raw;
  if (!REMOTE_MODE || !apiOrigin) return raw;
  try {
    const parsed = new URL(raw, window.location.href);
    const currentOrigin = new URL(apiOrigin);
    const knownBackendHost = (
      parsed.hostname.endsWith(".trycloudflare.com")
      || parsed.hostname.endsWith(".pinggy-free.link")
      || parsed.hostname.endsWith(".serveousercontent.com")
      || parsed.hostname.endsWith(".lhr.life")
    );
    if (
      parsed.pathname.startsWith("/api/")
      && (knownBackendHost || parsed.origin === window.location.origin || parsed.origin === currentOrigin.origin)
    ) {
      return `${apiOrigin}${parsed.pathname}${parsed.search}${parsed.hash}`;
    }
  } catch (_err) {}
  return raw;
}

function normalizeApiLinkedUrls(value) {
  if (Array.isArray(value)) return value.map((item) => normalizeApiLinkedUrls(item));
  if (!value || typeof value !== "object") return value;
  const normalized = {};
  for (const [key, item] of Object.entries(value)) {
    if (item && typeof item === "object") {
      normalized[key] = normalizeApiLinkedUrls(item);
      continue;
    }
    if (typeof item === "string" && ["url", "download_url", "user_avatar_url", "avatar_url", "cover_url"].includes(key)) {
      normalized[key] = normalizeApiAssetUrl(item);
      continue;
    }
    normalized[key] = item;
  }
  return normalized;
}

function appendQueryParam(url, key, value) {
  const raw = String(url || "").trim();
  if (!raw || !key) return raw;
  try {
    const parsed = new URL(raw, window.location.href);
    parsed.searchParams.set(String(key), String(value));
    return parsed.toString();
  } catch (_err) {
    const joiner = raw.includes("?") ? "&" : "?";
    return `${raw}${joiner}${encodeURIComponent(String(key))}=${encodeURIComponent(String(value))}`;
  }
}

function syncStoredUserUrls() {
  if (!currentUser) return;
  currentUser = normalizeApiLinkedUrls(currentUser);
  writeStore(USER_KEY, JSON.stringify(currentUser));
}

async function refreshRemoteBackendConfig({ force = false } = {}) {
  if (!REMOTE_MODE) return true;
  if (!force && apiOrigin) {
    syncStoredUserUrls();
    return true;
  }
  if (remoteConfigRefreshPromise) return remoteConfigRefreshPromise;
  remoteConfigRefreshPromise = (async () => {
    const response = await rawFetch(`${buildStaticUrl(CONFIG_FILE)}?t=${Date.now()}`, { cache: "no-store" });
    if (!response.ok) throw new Error(`Config HTTP ${response.status}`);
    const config = await response.json();
    localBackendUrls = normalizeLocalUrls(config.local_urls);
    setApiOrigin(config.gallery_url || "", true);
    if (!apiOrigin) throw new Error("live-config.json has no gallery_url");
    syncStoredUserUrls();
    if (currentUser) {
      renderAuth();
      fillSettingsForm();
    }
    return true;
  })();
  try {
    return await remoteConfigRefreshPromise;
  } finally {
    remoteConfigRefreshPromise = null;
  }
}

function withRequestTimeout(options = {}, timeoutMs = API_REQUEST_TIMEOUT_MS) {
  if (options.signal || !window.AbortController || timeoutMs <= 0) return { options, cleanup: () => {} };
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), timeoutMs);
  return {
    options: { ...options, signal: controller.signal },
    cleanup: () => window.clearTimeout(timer),
  };
}

async function apiFetch(path, options = {}, attempt = 0) {
  const headers = new Headers(options.headers || {});
  if (token) headers.set("Authorization", `Bearer ${token}`);
  let response;
  const timeout = withRequestTimeout(options);
  try {
    response = await fetch(apiUrl(path), { ...timeout.options, headers });
  } catch (err) {
    if (err?.name === "AbortError" && options.signal) throw err;
    if (REMOTE_MODE && attempt === 0) {
      try {
        await refreshRemoteBackendConfig({ force: true });
        return apiFetch(path, options, attempt + 1);
      } catch (_refreshErr) {}
    }
    const error = new Error(err?.name === "AbortError" ? "Backend request timed out." : `Backend unreachable: ${err.message || err}`);
    error.status = 0;
    throw error;
  } finally {
    timeout.cleanup();
  }
  const text = await response.text();
  let data = {};
  try { data = text ? JSON.parse(text) : {}; } catch (_err) { data = { detail: text || "Invalid server response" }; }
  data = normalizeApiLinkedUrls(data);
  if (REMOTE_MODE && attempt === 0 && response.status >= 500) {
    try {
      await refreshRemoteBackendConfig({ force: true });
      return apiFetch(path, options, attempt + 1);
    } catch (_refreshErr) {}
  }
  if (!response.ok) {
    const error = new Error(data.detail || data.message || "Request failed");
    error.status = response.status;
    throw error;
  }
  return data;
}

async function apiBlobFetch(path, options = {}, attempt = 0) {
  const headers = new Headers(options.headers || {});
  if (token) headers.set("Authorization", `Bearer ${token}`);
  let response;
  const timeout = withRequestTimeout(options, 60000);
  try {
    response = await fetch(apiUrl(path), { ...timeout.options, headers });
  } catch (err) {
    if (err?.name === "AbortError" && options.signal) throw err;
    if (REMOTE_MODE && attempt === 0) {
      try {
        await refreshRemoteBackendConfig({ force: true });
        return apiBlobFetch(path, options, attempt + 1);
      } catch (_refreshErr) {}
    }
    const error = new Error(err?.name === "AbortError" ? "Backend file request timed out." : `Backend unreachable: ${err.message || err}`);
    error.status = 0;
    throw error;
  } finally {
    timeout.cleanup();
  }
  if (REMOTE_MODE && attempt === 0 && response.status >= 500) {
    try {
      await refreshRemoteBackendConfig({ force: true });
      return apiBlobFetch(path, options, attempt + 1);
    } catch (_refreshErr) {}
  }
  if (!response.ok) {
    let detail = "Request failed";
    try {
      const data = await response.json();
      detail = data.detail || data.message || detail;
    } catch (_err) {}
    const error = new Error(detail);
    error.status = response.status;
    throw error;
  }
  return response;
}

function apiUpload(path, body, onProgress) {
  return new Promise((resolve, reject) => {
    const attemptUpload = async (attempt = 0) => {
      const xhr = new XMLHttpRequest();
      xhr.open("POST", apiUrl(path));
      if (token) xhr.setRequestHeader("Authorization", `Bearer ${token}`);
      xhr.upload.addEventListener("loadstart", () => {
        onProgress?.({ loaded: 0, total: 0, percent: 0, phase: "starting" });
      });
      xhr.upload.addEventListener("progress", (event) => {
        if (!event.lengthComputable) {
          onProgress?.({ loaded: event.loaded || 0, total: 0, percent: 0, phase: "uploading" });
          return;
        }
        onProgress?.({
          loaded: event.loaded,
          total: event.total,
          percent: Math.max(0, Math.min(100, Math.round((event.loaded / event.total) * 100))),
          phase: "uploading",
        });
      });
      xhr.upload.addEventListener("load", () => {
        onProgress?.({ loaded: 0, total: 0, percent: 100, phase: "processing" });
      });
      xhr.addEventListener("load", async () => {
        let data = {};
        try { data = xhr.responseText ? JSON.parse(xhr.responseText) : {}; } catch (_err) { data = { detail: xhr.responseText || "Invalid server response" }; }
        data = normalizeApiLinkedUrls(data);
        if (REMOTE_MODE && attempt === 0 && xhr.status >= 500) {
          try {
            await refreshRemoteBackendConfig({ force: true });
            return attemptUpload(attempt + 1);
          } catch (_refreshErr) {}
        }
        if (xhr.status >= 200 && xhr.status < 300) resolve(data);
        else {
          const error = new Error(data.detail || data.message || "Upload failed");
          error.status = xhr.status;
          reject(error);
        }
      });
      xhr.addEventListener("error", async () => {
        if (REMOTE_MODE && attempt === 0) {
          try {
            await refreshRemoteBackendConfig({ force: true });
            return attemptUpload(attempt + 1);
          } catch (_refreshErr) {}
        }
        const error = new Error("Backend unreachable during upload.");
        error.status = 0;
        reject(error);
      });
      xhr.addEventListener("abort", () => {
        const error = new Error("Upload was cancelled.");
        error.status = 0;
        reject(error);
      });
      xhr.send(body);
    };
    attemptUpload();
  });
}

function filenameFromDisposition(disposition, fallback = "download") {
  const match = String(disposition || "").match(/filename\*=UTF-8''([^;]+)|filename="?([^";]+)"?/i);
  const raw = decodeURIComponent(match?.[1] || match?.[2] || fallback);
  return raw.replace(/[\\/\0]/g, "_").slice(0, 180) || fallback;
}

function setNotice(id, message, kind = "error") {
  const el = $(id);
  el.textContent = message || "";
  el.hidden = !message;
  el.classList.toggle("error", Boolean(message) && kind === "error");
  el.classList.toggle("success", Boolean(message) && kind === "success");
}

function formatBytes(bytes) {
  const value = Number(bytes || 0);
  if (value >= 1024 * 1024 * 1024) return `${(value / 1024 / 1024 / 1024).toFixed(1)} GB`;
  if (value >= 1024 * 1024) return `${(value / 1024 / 1024).toFixed(1)} MB`;
  if (value >= 1024) return `${(value / 1024).toFixed(1)} KB`;
  return `${value} B`;
}

function mbToBytes(value) {
  const number = Number(value || 0);
  return number > 0 ? Math.round(number * 1024 * 1024) : 0;
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[char]));
}

function normalizedPublicUrl(value, { allowBlob = false } = {}) {
  const raw = String(value || "").trim();
  if (!raw) return "";
  try {
    const url = new URL(raw, window.location.href);
    if (["http:", "https:"].includes(url.protocol)) return url.toString();
    if (allowBlob && url.protocol === "blob:") return url.toString();
  } catch (_err) {}
  return "";
}

function avatarRevisionFromPath(value) {
  const raw = String(value || "").trim();
  return raw.startsWith("avatar-db://") ? raw.slice("avatar-db://".length).trim() : "";
}

function avatarUrlForRecord(record, {
  urlKey = "avatar_url",
  pathKey = "avatar_path",
  fileIdKey = "avatar_file_id",
  idKey = "id",
} = {}) {
  const direct = normalizedPublicUrl(record?.[urlKey]);
  if (direct) return direct;
  const userId = record?.[idKey];
  if (!userId || !record?.[pathKey]) return "";
  const revision = record?.[fileIdKey] || avatarRevisionFromPath(record?.[pathKey]);
  const base = apiUrl(`/api/users/${userId}/avatar`);
  return normalizedPublicUrl(revision ? appendQueryParam(base, "v", revision) : base);
}

function safeUrl(value, options = {}) {
  return escapeHtml(normalizedPublicUrl(value, options));
}

function safeHexColor(value, fallback = "#37c9a7") {
  const raw = String(value || "").trim();
  return /^#[0-9a-fA-F]{6}$/.test(raw) ? raw.toLowerCase() : fallback;
}

function safeClassToken(value, fallback = "default") {
  const raw = String(value || "").trim().toLowerCase();
  return /^[a-z0-9_-]+$/.test(raw) ? raw : fallback;
}

function normalizeLocalUrls(values) {
  const seen = new Set();
  return (Array.isArray(values) ? values : [])
    .map((value) => normalizedPublicUrl(value).replace(/\/$/, ""))
    .filter((value) => {
      if (!value || seen.has(value)) return false;
      seen.add(value);
      return true;
    });
}

function renderBackendHelp(err) {
  const title = safeEl("empty-title");
  const message = safeEl("empty-message");
  const status = safeEl("connection-status");
  const detail = err?.message || String(err || "Backend unavailable");
  const links = localBackendUrls.length
    ? `<div class="empty-links">${localBackendUrls.map((url) => (
      `<a href="${escapeHtml(url)}/" target="_blank" rel="noreferrer">${escapeHtml(url)}</a>`
    )).join("")}</div>`
    : "";
  if (title) title.textContent = REMOTE_MODE ? "Public backend is offline" : "Backend unavailable";
  if (message) {
    message.innerHTML = REMOTE_MODE
      ? `The GitHub Pages tunnel is not connected right now. Open a local gallery URL instead.${links}`
      : `Backend connection failed: ${escapeHtml(detail)}${links}`;
  }
  if (status) {
    status.textContent = "No backend";
    status.dataset.state = "error";
    status.title = detail;
  }
  setTextIfPresent("result-count", REMOTE_MODE ? "Public backend offline. Local gallery links are ready below." : detail);
  showIfPresent("empty-state", true);
}

function renderAuth() {
  $("auth-open").classList.toggle("avatar", Boolean(currentUser));
  $("auth-open").classList.toggle("tiny", Boolean(currentUser));
  $("auth-open").classList.toggle("is-account-avatar", Boolean(currentUser));
  if (currentUser) {
    renderButtonAvatar("auth-open", currentUser, currentUser.display_name || currentUser.username || "IG");
    $("auth-open").title = `Open @${currentUser.username}`;
    $("auth-open").setAttribute("aria-label", `Open @${currentUser.username}`);
  } else {
    $("auth-open").textContent = "Login";
    $("auth-open").title = "Login";
    $("auth-open").setAttribute("aria-label", "Login");
    $("auth-open").style.borderColor = "";
  }
  $("logout").hidden = !currentUser;
  $("settings-open").hidden = !currentUser;
  $("studio-open").hidden = !currentUser;
  showIfPresent("profile-open", Boolean(currentUser));
  showIfPresent("friends-open", Boolean(currentUser));
  $("account-card").hidden = !currentUser;
  if (currentUser) {
    $("account-name").textContent = currentUser.display_name || currentUser.username;
    $("account-name").title = `Open @${currentUser.username}`;
    $("account-avatar").title = `Open @${currentUser.username}`;
    const emailNote = currentUser.email && !currentUser.email_verified
      ? " Email verification is pending; enter the emailed code in settings."
      : currentUser.email_verified
        ? " Email verified."
        : "";
    $("account-bio").textContent = currentUser.age_verified
      ? `${currentUser.bio || "Age verified. Your settings apply only to this account."}${emailNote}`
      : `${currentUser.bio || "Verify age in settings to unlock 18+ posts."}${emailNote}`;
    $("resend-email-verification").hidden = !currentUser.email || currentUser.email_verified;
    renderAvatar("account-avatar", currentUser);
  }
  applyAccountSettings();
  applyDesmondVisibility();
  renderTopbarPageState();
  renderPageSidebar();
}

function isSiteOwner() {
  return Boolean(currentUser?.site_owner);
}

function isDesmondUser() {
  return isSiteOwner();
}

function applyDesmondVisibility() {
  const canSeePrivateData = isSiteOwner();
  const status = safeEl("connection-status");
  const stats = document.querySelector(".stats-grid");
  if (status) status.hidden = false;
  if (stats) stats.hidden = !canSeePrivateData;
}

function categoryDisplayName(categoryName, subcategoryName = "") {
  const main = String(categoryName || "").trim();
  const sub = String(subcategoryName || "").trim();
  if (!main) return sub || "Unsorted";
  return sub ? `${main} / ${sub}` : main;
}

function categoryDisplayFromItem(item) {
  return categoryDisplayName(item?.category_name, item?.subcategory_name);
}

function categoryById(id) {
  return categories.find((item) => String(item.id) === String(id));
}

function categoryByName(name) {
  const target = String(name || "").trim().toLowerCase();
  if (!target) return null;
  return categories.find((item) => String(item.name || "").trim().toLowerCase() === target) || null;
}

function subcategoryByName(categoryId, name) {
  const target = String(name || "").trim().toLowerCase();
  if (!target) return null;
  return (subcategoriesForCategory(categoryId) || []).find((item) => String(item.name || "").trim().toLowerCase() === target) || null;
}

function isLegacyLeafCategory(category) {
  const retired = new Set(["aria blaze (solo)", "dazzlings"]);
  return retired.has(String(category?.name || "").trim().toLowerCase()) && Number(category?.media_count || 0) === 0;
}

function subcategoriesForCategory(categoryId) {
  return categoryById(categoryId)?.subcategories || [];
}

function populateSubcategorySelect(selectId, categoryId, { includeCreate = false, selectedValue = "", emptyLabel = "No subcategory" } = {}) {
  const select = safeEl(selectId);
  if (!select) return;
  const options = categoryId
    ? subcategoriesForCategory(categoryId)
    : categories.flatMap((category) => (category.subcategories || []).map((subcategory) => ({
      ...subcategory,
      _label: `${category.name} / ${subcategory.name}`,
    })));
  const selected = String(selectedValue || "");
  select.innerHTML = `<option value="">${escapeHtml(emptyLabel)}</option>`
    + options.map((subcategory) => `<option value="${subcategory.id}">${escapeHtml(subcategory._label || subcategory.name)}</option>`).join("")
    + (includeCreate ? `<option value="__new__">Create new subcategory</option>` : "");
  select.value = options.some((subcategory) => String(subcategory.id) === selected) ? selected : (selected === "__new__" ? "__new__" : "");
}

function openAgeDialog(message = "") {
  if (!currentUser) return $("auth-dialog").showModal();
  setNotice("age-error", message);
  $("age-dialog").showModal();
}

function canRevealAdult(item) {
  return !item?.is_adult || (currentUser?.age_verified && item?.url);
}

function adultBadge(item) {
  if (!item?.is_adult) return "";
  return `<span class="adult-badge">18+</span>`;
}

function analysisSourceLabel(source) {
  if (source === "local-clip") return "Local vision";
  if (source === "ollama") return "Ollama vision";
  if (source === "openai") return "AI";
  return "Smart fallback";
}

function renderPreview(item, size = "card") {
  const isAdult = Boolean(item.is_adult);
  const revealed = revealedAdultMedia.has(Number(item.id));
  const locked = isAdult && !canRevealAdult(item);
  const blur = isAdult && !revealed && !locked;
  const placeholderText = locked ? "18+ Verify Age" : "Click To Reveal";
  const previewVariant = size === "mini" || size === "card" ? "mini" : "detail";
  const cardPreview = size === "card";
  const lowPower = isLowPowerMode();
  const previewBaseUrl = item.media_kind === "image" ? (item.preview_url || item.url) : item.url;
  const previewUrl = normalizedPublicUrl(item.media_kind === "image" ? appendQueryParam(previewBaseUrl, "size", previewVariant) : previewBaseUrl);
  const body = locked
    ? `<div class="locked-preview"><strong>18+</strong><span>Verify age to view</span></div>`
    : !previewUrl
      ? `<div class="locked-preview"><strong>Preview unavailable</strong><span>Open the post for details</span></div>`
    : item.media_kind === "video"
      ? `<video src="${escapeHtml(previewUrl)}" ${userSettings().muted_previews || lowPower ? "muted" : ""} ${userSettings().autoplay_previews && !lowPower ? "autoplay loop" : ""} playsinline preload="${lowPower ? "none" : "metadata"}"></video>`
      : `<img src="${escapeHtml(previewUrl)}" alt="${escapeHtml(item.title)}" loading="${cardPreview ? "lazy" : "eager"}" decoding="async" fetchpriority="${cardPreview ? "low" : "auto"}" draggable="false" />`;
  return `
    <span class="${blur ? "adult-blur" : ""}">${body}</span>
    ${isAdult && !revealed ? `<span class="adult-overlay">${placeholderText}</span>` : ""}
  `;
}

function rememberGalleryPreload(url) {
  if (!url || galleryAssetPreloadCache.has(url)) return false;
  galleryAssetPreloadCache.add(url);
  while (galleryAssetPreloadCache.size > GALLERY_ASSET_PRELOAD_CACHE_LIMIT) {
    const oldest = galleryAssetPreloadCache.values().next().value;
    galleryAssetPreloadCache.delete(oldest);
  }
  return true;
}

function preloadGalleryImage(url) {
  const normalized = normalizedPublicUrl(url);
  if (!normalized || !rememberGalleryPreload(normalized)) return;
  const image = new Image();
  image.decoding = "async";
  image.fetchPriority = "low";
  image.src = normalized;
  if (typeof image.decode === "function") image.decode().catch(() => {});
}

function scheduleGalleryAssetPrecache(items = mediaItems) {
  if (!Array.isArray(items) || !items.length || navigator.connection?.saveData) return;
  if (galleryAssetPreloadHandle) {
    if (window.cancelIdleCallback) window.cancelIdleCallback(galleryAssetPreloadHandle);
    else window.clearTimeout(galleryAssetPreloadHandle);
    galleryAssetPreloadHandle = 0;
  }
  const limit = isLowPowerMode() ? LOW_POWER_GALLERY_ASSET_PRELOAD_LIMIT : GALLERY_ASSET_PRELOAD_LIMIT;
  const snapshot = items.slice(0, limit).filter((item) => item && canRevealAdult(item));
  const run = () => {
    galleryAssetPreloadHandle = 0;
    for (const item of snapshot) {
      if (item.media_kind === "image") {
        const previewBase = item.preview_url || item.url;
        preloadGalleryImage(appendQueryParam(previewBase, "size", "mini"));
      }
      preloadGalleryImage(avatarUrlForRecord(item, { urlKey: "user_avatar_url", pathKey: "user_avatar_path", fileIdKey: "user_avatar_file_id", idKey: "user_id" }));
    }
  };
  galleryAssetPreloadHandle = window.requestIdleCallback
    ? window.requestIdleCallback(run, { timeout: 1600 })
    : window.setTimeout(run, 180);
}

function userSettings() {
  return { ...DEFAULT_USER_SETTINGS, ...(currentUser?.user_settings || {}) };
}

function renderAvatar(id, user) {
  const el = $(id);
  if (!el) return;
  const name = user?.display_name || user?.username || "IG";
  const avatarUrl = avatarUrlForRecord(user)
    || avatarUrlForRecord(user, { urlKey: "user_avatar_url", pathKey: "user_avatar_path", fileIdKey: "user_avatar_file_id", idKey: "user_id" })
    || avatarUrlForRecord(user, { urlKey: "user_avatar_url", pathKey: "user_avatar_path", fileIdKey: "user_avatar_file_id", idKey: "id" });
  if (avatarUrl) {
    el.innerHTML = `<img src="${escapeHtml(avatarUrl)}" alt="">`;
  } else {
    el.textContent = name.slice(0, 2).toUpperCase();
  }
  el.style.borderColor = safeHexColor(user?.profile_color, safeHexColor(userSettings().accent_color, "#37c9a7"));
}

function renderButtonAvatar(id, user, fallbackLabel = "IG") {
  const el = safeEl(id);
  if (!el) return;
  const name = user?.display_name || user?.username || fallbackLabel;
  const avatarUrl = avatarUrlForRecord(user)
    || avatarUrlForRecord(user, { urlKey: "user_avatar_url", pathKey: "user_avatar_path", fileIdKey: "user_avatar_file_id", idKey: "user_id" })
    || avatarUrlForRecord(user, { urlKey: "user_avatar_url", pathKey: "user_avatar_path", fileIdKey: "user_avatar_file_id", idKey: "id" });
  if (avatarUrl) {
    el.innerHTML = `<img src="${escapeHtml(avatarUrl)}" alt="">`;
  } else {
    el.textContent = name.slice(0, 2).toUpperCase();
  }
  el.style.borderColor = safeHexColor(user?.profile_color, safeHexColor(userSettings().accent_color, "#37c9a7"));
}

function applyAccountSettings() {
  const prefs = userSettings();
  document.documentElement.style.setProperty("--accent", prefs.accent_color || "#37c9a7");
  document.body.dataset.theme = prefs.theme_mode || "system";
  document.body.dataset.density = prefs.grid_density || "comfortable";
  document.body.dataset.reduceMotion = prefs.reduce_motion ? "1" : "0";
  document.body.dataset.blurVideos = prefs.blur_video_previews ? "1" : "0";
  applyRuntimePerformanceMode();
  if (currentUser && $("sort-filter").value === "new") $("sort-filter").value = prefs.default_sort || "new";
}

function applySiteBackground(background, { persist = true } = {}) {
  const backgroundUrl = normalizedPublicUrl(background?.url);
  if (!backgroundUrl) return;
  const withBust = `${backgroundUrl}${backgroundUrl.includes("?") ? "&" : "?"}bg=${background.id || Date.now()}`;
  const preload = new Image();
  preload.decoding = "async";
  preload.onload = () => {
    document.documentElement.style.setProperty("--site-background-image", `url("${withBust}")`);
    document.body.dataset.backgroundReady = "1";
    const payload = { ...background, appliedAt: Date.now() };
    if (persist) writeStore(SITE_BACKGROUND_KEY, JSON.stringify(payload));
  };
  preload.src = withBust;
}

function scheduleSiteBackgroundRefresh(delay = SITE_BACKGROUND_REFRESH_MS) {
  clearTimeout(siteBackgroundTimer);
  siteBackgroundTimer = window.setTimeout(() => {
    refreshSiteBackground({ force: true });
  }, Math.max(1000, delay));
}

async function refreshSiteBackground({ force = false } = {}) {
  if (isLowPowerMode()) {
    document.documentElement.style.setProperty("--site-background-image", "none");
    document.body.dataset.backgroundReady = "0";
    return;
  }
  const cached = readJsonStore(SITE_BACKGROUND_KEY);
  const cachedAge = Date.now() - Number(cached?.appliedAt || 0);
  if (!force && cached?.url && cachedAge < SITE_BACKGROUND_REFRESH_MS) {
    applySiteBackground(cached, { persist: false });
    scheduleSiteBackgroundRefresh(SITE_BACKGROUND_REFRESH_MS - cachedAge);
    return;
  }
  const excludeId = Number(cached?.id || 0) || 0;
  try {
    const data = await apiFetch(`/api/site/background${excludeId ? `?exclude=${excludeId}` : ""}`);
    if (data?.background?.url) {
      applySiteBackground(data.background);
      scheduleSiteBackgroundRefresh((Number(data.refresh_after_seconds) || 300) * 1000);
      return;
    }
  } catch (_err) {}
  scheduleSiteBackgroundRefresh();
}

function galleryHeadingMeta() {
  if (currentPage === "following" || galleryMode === "following") {
    return {
      eyebrow: "Following",
      title: "Follow Feed",
      description: "Latest posts from the people you follow, laid out as its own feed instead of being mixed into discovery.",
    };
  }
  if (currentPage === "liked" || galleryMode === "liked") {
    return {
      eyebrow: "Liked",
      title: "Saved Likes",
      description: "A dedicated stream of posts you already liked, so it feels like a real space and not a side toggle.",
    };
  }
  return {
    eyebrow: "Discover",
    title: "Fresh Drops",
    description: "New uploads, filters, saved views, and feed tools live here.",
  };
}

function renderGalleryHeading() {
  const meta = galleryHeadingMeta();
  setTextIfPresent("page-eyebrow", meta.eyebrow);
  setTextIfPresent("page-title", meta.title);
}

function activeTopbarPage() {
  if (currentPage === "following" || galleryMode === "following") return "following";
  if (currentPage === "liked" || galleryMode === "liked") return "liked";
  if (currentPage === "discover") return "discover";
  return currentPage;
}

function renderPageSidebar() {
  const pageSidebar = safeEl("page-sidebar");
  const discoverSidebar = document.querySelectorAll(".discover-sidebar-block");
  const discoverVisible = ["discover", "following", "liked"].includes(currentPage);
  discoverSidebar.forEach((node) => { node.hidden = !discoverVisible; });
  enhanceMotion(document);
  if (!pageSidebar) return;
  const commitSidebar = (markup = "") => {
    pageSidebar.innerHTML = markup;
    enhanceMotion(pageSidebar);
  };
  if (discoverVisible) {
    const meta = galleryHeadingMeta();
    commitSidebar(`
      <section class="sidebar-note">
        <h3>${escapeHtml(meta.title)}</h3>
        <p class="muted">${escapeHtml(meta.description)}</p>
      </section>
      <section class="sidebar-note">
        <h3>Quick Status</h3>
        <p class="muted">${escapeHtml(latestLiveSnapshot?.media_active ? `${latestLiveSnapshot.media_active} active posts reported by the backend.` : "Run Checks if the gallery feels stale or partially loaded.")}</p>
      </section>
    `);
    return;
  }
  if (currentPage === "collections") {
    commitSidebar(`
      <section class="sidebar-note">
        <h3>${collectionsMineMode ? "My Collections" : "Community Collections"}</h3>
        <p class="muted">${collectionsMineMode ? "Private and public sets you own appear here with editing space beside them." : "Browse public sets, pick one, and inspect its media rail without leaving the page."}</p>
      </section>
      <section class="sidebar-note">
        <h3>Loaded</h3>
        <p class="muted">${collectionsState.length} collection${collectionsState.length === 1 ? "" : "s"} currently loaded.</p>
      </section>
    `);
    return;
  }
  if (currentPage === "users") {
    commitSidebar(`
      <section class="sidebar-note">
        <h3>Directory Tips</h3>
        <p class="muted">Search by username, display name, bio, or profile headline. Open any profile inline from the results grid.</p>
      </section>
    `);
    return;
  }
  if (currentPage === "friends") {
    commitSidebar(`
      <section class="sidebar-note">
        <h3>Relationship Snapshot</h3>
        <p class="muted">${friendPanelState.friends.length} friends, ${friendPanelState.incoming.length} incoming request${friendPanelState.incoming.length === 1 ? "" : "s"}, ${friendPanelState.outgoing.length} outgoing.</p>
      </section>
    `);
    return;
  }
  if (currentPage === "studio") {
    commitSidebar(`
      <section class="sidebar-note">
        <h3>Creator Totals</h3>
        <p class="muted">${studioPageState.items.length} posts, ${studioPageState.totals.views} views, ${studioPageState.totals.downloads} downloads, ${studioPageState.totals.likes} likes.</p>
      </section>
    `);
    return;
  }
  if (currentPage === "profile") {
    const user = profilePageData?.user || {};
    commitSidebar(`
      <section class="sidebar-note">
        <h3>${escapeHtml(user.display_name || user.username || "Profile")}</h3>
        <p class="muted">${escapeHtml(user.profile_headline || user.bio || "Expanded profile view with layout and banner styling.")}</p>
      </section>
      <section class="sidebar-note">
        <h3>Public Stats</h3>
        <p class="muted">${Number(user.media_count || 0)} posts, ${Number(user.follower_count || 0)} followers, ${Number(user.friend_count || 0)} friends.</p>
      </section>
    `);
    return;
  }
  commitSidebar("");
}

function renderTopbarPageState() {
  const buttons = {
    discover: safeEl("discover-open"),
    collections: safeEl("collections-open"),
    users: safeEl("users-open"),
    following: safeEl("following-feed"),
    friends: safeEl("friends-open"),
    liked: safeEl("liked-feed"),
    studio: safeEl("studio-open"),
    profile: safeEl("profile-open"),
  };
  const active = activeTopbarPage();
  Object.entries(buttons).forEach(([page, button]) => {
    if (!button) return;
    button.classList.toggle("is-active", page === active);
  });
}

function routeTo(path, { replace = false } = {}) {
  if (REMOTE_MODE || routeSyncInProgress || !path) return;
  const normalized = path === "/" ? "/" : path.replace(/\/+$/, "");
  const current = location.pathname === "/" ? "/" : location.pathname.replace(/\/+$/, "");
  if (current === normalized && !location.hash) return;
  history[replace ? "replaceState" : "pushState"]({ galleryRoute: true, path: normalized }, "", normalized);
}

function routeForPage(page) {
  if (page === "profile" && activeProfileUsername) return `/users/${encodeURIComponent(activeProfileUsername)}`;
  return PAGE_ROUTES[page] || "/";
}

function setCurrentPage(page, options = {}) {
  const { updateRoute = true, replaceRoute = false } = options;
  currentPage = page;
  if (page !== "profile") activeProfileUsername = "";
  document.body.dataset.page = page;
  const pages = {
    discover: safeEl("discover-page"),
    collections: safeEl("collections-page"),
    users: safeEl("users-page"),
    friends: safeEl("friends-page"),
    studio: safeEl("studio-page"),
    profile: safeEl("profile-page"),
  };
  const discoverVisible = ["discover", "following", "liked"].includes(page);
  if (pages.discover) pages.discover.hidden = !discoverVisible;
  if (pages.collections) pages.collections.hidden = page !== "collections";
  if (pages.users) pages.users.hidden = page !== "users";
  if (pages.friends) pages.friends.hidden = page !== "friends";
  if (pages.studio) pages.studio.hidden = page !== "studio";
  if (pages.profile) pages.profile.hidden = page !== "profile";
  if (page !== "profile" && location.hash.startsWith("#user/")) {
    history.replaceState(null, "", location.pathname + location.search);
  }
  if (updateRoute) routeTo(routeForPage(page), { replace: replaceRoute });
  renderGalleryHeading();
  renderTopbarPageState();
  renderPageSidebar();
  enhanceMotion(safeEl(`${page}-page`) || document);
}


function setRegisterMode(enabled) {
  registerMode = Boolean(enabled);
  setNotice("auth-error", "");
  $("auth-title").textContent = registerMode ? "Create Account" : "Login";
  $("auth-submit").textContent = registerMode ? "Create Account" : "Login";
  $("auth-toggle").textContent = registerMode ? "I already have an account" : "Create Account";
  showIfPresent("display-name-wrap", registerMode);
  showIfPresent("email-wrap", registerMode);
  const password = safeEl("auth-password");
  if (password) password.autocomplete = registerMode ? "new-password" : "current-password";
}

async function submitAuth(event) {
  event.preventDefault();
  setNotice("auth-error", "");
  const submit = safeEl("auth-submit");
  setDisabledIfPresent("auth-submit", true);
  try {
    const payload = {
      username: $("auth-username").value.trim(),
      password: $("auth-password").value,
    };
    if (registerMode) {
      payload.display_name = $("auth-display-name").value.trim() || payload.username;
      payload.email = $("auth-email").value.trim() || null;
    }
    const data = await apiFetch(registerMode ? "/api/auth/register" : "/api/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    token = data.token || "";
    currentUser = data.user || null;
    writeStore(TOKEN_KEY, token);
    writeStore(USER_KEY, JSON.stringify(currentUser));
    renderAuth();
    fillSettingsForm();
    $("auth-dialog").close();
    $("auth-form").reset();
    if (data.email_error) {
      setNotice("settings-error", `Account created, but email was not sent: ${data.email_error}`, "error");
      setTextIfPresent("account-bio", `Email verification could not be sent: ${data.email_error}`);
    }
    await refreshAll();
  } catch (err) {
    setNotice("auth-error", err.message);
  } finally {
    if (submit) submit.disabled = false;
  }
}

function fillSettingsForm() {
  if (!currentUser) return;
  const prefs = userSettings();
  const setValue = (id, value) => { const el = safeEl(id); if (el) el.value = value ?? ""; };
  const setChecked = (id, value) => { const el = safeEl(id); if (el) el.checked = Boolean(value); };
  setValue("settings-display-name", currentUser.display_name || currentUser.username || "");
  setValue("settings-email", currentUser.email || "");
  setValue("settings-profile-color", currentUser.profile_color || prefs.accent_color || "#37c9a7");
  setValue("settings-website", currentUser.website_url || "");
  setValue("settings-location", currentUser.location_label || "");
  setValue("settings-profile-headline", currentUser.profile_headline || "");
  setValue("settings-featured-tags", (currentUser.featured_tags || []).join(", "));
  setValue("settings-bio", currentUser.bio || "");
  setChecked("settings-public-profile", currentUser.public_profile !== false);
  setChecked("settings-show-liked-count", currentUser.show_liked_count !== false);
  setChecked("settings-show-collections", currentUser.show_collections !== false);
  setChecked("settings-show-uploads", currentUser.show_recent_uploads !== false);
  setChecked("settings-show-friends", currentUser.show_friends !== false);
  setValue("pref-theme-mode", prefs.theme_mode || "system");
  setValue("pref-accent-color", prefs.accent_color || "#37c9a7");
  setValue("pref-grid-density", prefs.grid_density || "comfortable");
  setValue("pref-default-sort", prefs.default_sort || "new");
  setValue("pref-items-per-page", galleryPageSize());
  setValue("pref-profile-layout", prefs.profile_layout || "spotlight");
  setValue("pref-profile-banner-style", prefs.profile_banner_style || "gradient");
  setValue("pref-profile-card-style", prefs.profile_card_style || "glass");
  setValue("pref-profile-stat-style", prefs.profile_stat_style || "tiles");
  setValue("pref-profile-content-focus", prefs.profile_content_focus || "balanced");
  setValue("pref-profile-hero-alignment", prefs.profile_hero_alignment || "split");
  setChecked("pref-autoplay-previews", prefs.autoplay_previews);
  setChecked("pref-muted-previews", prefs.muted_previews !== false);
  setChecked("pref-reduce-motion", prefs.reduce_motion);
  setChecked("pref-open-original", prefs.open_original_in_new_tab);
  setChecked("pref-blur-video-previews", prefs.blur_video_previews);
  setChecked("pref-profile-show-joined-date", prefs.profile_show_joined_date !== false);
  setChecked("pref-profile-show-follow-counts", prefs.profile_show_follow_counts !== false);
  setTextIfPresent("settings-email-status", currentUser.email ? (currentUser.email_verified ? "Email verified" : "Email verification pending") : "No email set");
  setTextIfPresent("settings-age-status", currentUser.age_verified ? "Verified" : "Not verified");
  const preview = safeEl("settings-avatar-preview");
  if (preview?.dataset.objectUrl) {
    URL.revokeObjectURL(preview.dataset.objectUrl);
    delete preview.dataset.objectUrl;
  }
  if (safeEl("settings-avatar-file")) $("settings-avatar-file").value = "";
  renderAvatar("settings-avatar-preview", currentUser);
}

async function submitSettings(event) {
  event.preventDefault();
  if (!currentUser) return $("auth-dialog").showModal();
  setNotice("settings-error", "");
  try {
    const profilePayload = {
      display_name: $("settings-display-name").value.trim() || currentUser.username,
      bio: $("settings-bio").value.trim() || null,
      website_url: $("settings-website").value.trim() || null,
      location_label: $("settings-location").value.trim() || null,
      profile_headline: $("settings-profile-headline").value.trim() || null,
      featured_tags: $("settings-featured-tags").value.split(",").map((tag) => tag.trim()).filter(Boolean),
      profile_color: $("settings-profile-color").value || "#37c9a7",
      public_profile: $("settings-public-profile").checked,
      show_liked_count: $("settings-show-liked-count").checked,
      show_collections: $("settings-show-collections").checked,
      show_recent_uploads: $("settings-show-uploads").checked,
      show_friends: $("settings-show-friends").checked,
    };
    let data = await apiFetch("/api/me/profile", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(profilePayload),
    });
    currentUser = data.user;
    const settingsPayload = {
      theme_mode: $("pref-theme-mode").value,
      accent_color: $("pref-accent-color").value,
      grid_density: $("pref-grid-density").value,
      default_sort: $("pref-default-sort").value,
      items_per_page: Number($("pref-items-per-page").value || galleryPageSize()),
      profile_layout: $("pref-profile-layout").value,
      profile_banner_style: $("pref-profile-banner-style").value,
      profile_card_style: $("pref-profile-card-style").value,
      profile_stat_style: $("pref-profile-stat-style").value,
      profile_content_focus: $("pref-profile-content-focus").value,
      profile_hero_alignment: $("pref-profile-hero-alignment").value,
      autoplay_previews: $("pref-autoplay-previews").checked,
      muted_previews: $("pref-muted-previews").checked,
      reduce_motion: $("pref-reduce-motion").checked,
      open_original_in_new_tab: $("pref-open-original").checked,
      blur_video_previews: $("pref-blur-video-previews").checked,
      profile_show_joined_date: $("pref-profile-show-joined-date").checked,
      profile_show_uploads: $("settings-show-uploads").checked,
      profile_show_collections: $("settings-show-collections").checked,
      profile_show_friends: $("settings-show-friends").checked,
      profile_show_follow_counts: $("pref-profile-show-follow-counts").checked,
    };
    data = await apiFetch("/api/me/settings", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(settingsPayload),
    });
    currentUser = data.user;
    writeStore(USER_KEY, JSON.stringify(currentUser));
    renderAuth();
    fillSettingsForm();
    setNotice("settings-error", "Saved.", "success");
    await refreshAll();
  } catch (err) {
    setNotice("settings-error", err.message);
  }
}

async function saveEmailAndSendCode() {
  if (!currentUser) return;
  setNotice("settings-error", "");
  try {
    const data = await apiFetch("/api/me/email", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: $("settings-email").value.trim() || null }),
    });
    currentUser = data.user;
    writeStore(USER_KEY, JSON.stringify(currentUser));
    renderAuth();
    fillSettingsForm();
    setTextIfPresent("settings-email-status", data.email_verification_sent ? "Verification code sent." : "Email saved.");
    setNotice("settings-error", data.email_verification_sent ? "Verification code sent." : "Email saved.", "success");
  } catch (err) {
    setNotice("settings-error", err.message);
  }
}

async function verifyEmailCode() {
  if (!currentUser) return;
  const code = $("settings-email-code").value.trim();
  if (!code) return setNotice("settings-error", "Enter the email verification code.");
  try {
    const data = await apiFetch("/api/me/email/verify", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code }),
    });
    currentUser = data.user;
    writeStore(USER_KEY, JSON.stringify(currentUser));
    renderAuth();
    fillSettingsForm();
    setNotice("settings-error", "Email verified.", "success");
  } catch (err) {
    setNotice("settings-error", err.message);
  }
}

async function submitAgeVerification(event) {
  if (event) event.preventDefault();
  if (!currentUser) return $("auth-dialog").showModal();
  const fromSettings = event?.currentTarget?.id === "settings-age-save" || event?.currentTarget?.id === "settings-form";
  const birthdate = (fromSettings ? safeEl("settings-birthdate") : safeEl("age-birthdate"))?.value || safeEl("settings-birthdate")?.value || safeEl("age-birthdate")?.value;
  const confirm_over_18 = Boolean((fromSettings ? safeEl("settings-age-confirm") : safeEl("age-confirm"))?.checked || safeEl("settings-age-confirm")?.checked || safeEl("age-confirm")?.checked);
  const noticeId = fromSettings ? "settings-error" : "age-error";
  try {
    const data = await apiFetch("/api/me/age-verification", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ birthdate, confirm_over_18 }),
    });
    currentUser = data.user;
    writeStore(USER_KEY, JSON.stringify(currentUser));
    renderAuth();
    fillSettingsForm();
    revealedAdultMedia.clear();
    if (safeEl("age-dialog")?.open) $("age-dialog").close();
    setNotice(noticeId, "Age verified.", "success");
    await refreshAll();
  } catch (err) {
    setNotice(noticeId, err.message);
  }
}

function toggleNewCategory() {
  const uploadCategory = safeEl("upload-category");
  const creating = !uploadCategory?.value;
  showIfPresent("new-category-wrap", creating);
  showIfPresent("new-category-kind-wrap", creating);
  showIfPresent("upload-subcategory-wrap", !creating);
  populateSubcategorySelect("upload-subcategory", uploadCategory?.value, {
    includeCreate: !creating,
    selectedValue: safeEl("upload-subcategory")?.value || "",
    emptyLabel: "No subcategory",
  });
  const creatingSubcategory = safeEl("upload-subcategory")?.value === "__new__";
  showIfPresent("new-subcategory-wrap", creating || creatingSubcategory);
  const name = safeEl("new-category-name");
  if (name) name.required = creating;
  const subcategoryName = safeEl("new-subcategory-name");
  if (subcategoryName) subcategoryName.required = creatingSubcategory;
}

function toggleEditSubcategory() {
  const categoryId = safeEl("edit-media-category")?.value || "";
  const current = safeEl("edit-media-subcategory")?.value || "";
  populateSubcategorySelect("edit-media-subcategory", categoryId, {
    includeCreate: Boolean(categoryId),
    selectedValue: current,
    emptyLabel: "No subcategory",
  });
  showIfPresent("edit-new-subcategory-wrap", safeEl("edit-media-subcategory")?.value === "__new__");
  const input = safeEl("edit-new-subcategory-name");
  if (input) input.required = safeEl("edit-media-subcategory")?.value === "__new__";
}

function handleAdultOpen(id) {
  const numericId = Number(id);
  const item = mediaItems.find((entry) => Number(entry.id) === numericId)
    || activeDetail
    || collectionsState.flatMap((collection) => collection.items || []).find((entry) => Number(entry.id) === numericId);
  if (!item?.is_adult) return false;
  if (!currentUser || !currentUser.age_verified || !item.url) {
    openAgeDialog("Verify your age to view this 18+ post.");
    return true;
  }
  if (!revealedAdultMedia.has(numericId)) {
    revealedAdultMedia.add(numericId);
    renderMediaGrid();
    return true;
  }
  return false;
}

async function copyAddress(id) {
  const numericId = Number(id);
  const item = mediaItems.find((entry) => Number(entry.id) === numericId) || activeDetail;
  const url = item?.url || (item?.id ? apiUrl(`/api/media/${item.id}/file`) : "");
  if (!url) return;
  await copyText(url, "Media address copied.");
}

async function downloadMedia(id) {
  const numericId = Number(id);
  const item = mediaItems.find((entry) => Number(entry.id) === numericId) || activeDetail;
  if (!item) return;
  if (item.downloads_enabled === false) return alert("Downloads are disabled for this post.");
  if (item.is_adult && (!currentUser || !currentUser.age_verified)) {
    openAgeDialog("Verify your age before downloading this 18+ post.");
    return;
  }
  try {
    const response = await apiBlobFetch(`/api/media/${numericId}/download`);
    const blob = await response.blob();
    const fallback = item.original_filename || `${(item.title || "download").replace(/\s+/g, "_")}`;
    const filename = filenameFromDisposition(response.headers.get("Content-Disposition"), fallback);
    const objectUrl = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = objectUrl;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    showToast("Download started.", "success");
    setTimeout(() => URL.revokeObjectURL(objectUrl), 1500);
  } catch (err) {
    if (err.status === 403 && item.is_adult) openAgeDialog(err.message);
    else showToast(err.message || "Download failed.", "error");
  }
}

function stopMediaPlayback(root = document) {
  root.querySelectorAll("video, audio").forEach((media) => {
    try {
      media.pause();
      media.currentTime = 0;
      media.removeAttribute("src");
      media.load();
    } catch (_err) {}
  });
}

function closeDetailDialog(options = {}) {
  const { updateRoute = true } = options;
  const dialog = $("detail-dialog");
  stopMediaPlayback(dialog);
  if (dialog.open) dialog.close();
  if (updateRoute && /^\/media\/\d+\/?$/.test(location.pathname)) {
    routeTo(routeForPage(currentPage || "discover"), { replace: false });
  }
}

function applyDetailTransform() {
  const media = safeEl("detail-media")?.querySelector("img, video");
  if (!media) return;
  media.style.transform = `scale(${detailZoom}) rotate(${detailRotation}deg)`;
  media.style.cursor = detailZoom > 1 ? "zoom-out" : "zoom-in";
}

function resetDetailTransform() {
  detailZoom = 1;
  detailRotation = 0;
  applyDetailTransform();
}

function zoomDetail(delta) {
  detailZoom = Math.max(0.5, Math.min(3, Number((detailZoom + delta).toFixed(2))));
  applyDetailTransform();
}

function rotateDetail() {
  detailRotation = (detailRotation + 90) % 360;
  applyDetailTransform();
}

function renderDetailInspector(item) {
  const inspector = safeEl("detail-inspector");
  if (!inspector || !item) return;
  inspector.innerHTML = `
    <dl>
      <div><dt>Filename</dt><dd>${escapeHtml(item.original_filename || "Unknown")}</dd></div>
      <div><dt>Mime</dt><dd>${escapeHtml(item.mime_type || "Unknown")}</dd></div>
      <div><dt>Visibility</dt><dd>${escapeHtml(item.visibility || "public")}</dd></div>
      <div><dt>Views</dt><dd>${Number(item.views || 0)}</dd></div>
      <div><dt>Comments</dt><dd>${Number(item.comment_count || 0)}</dd></div>
      <div><dt>Uploaded</dt><dd>${escapeHtml(String(item.created_at || "").replace("T", " "))}</dd></div>
    </dl>
  `;
}

async function refreshMe() {
  if (!token) return;
  let data;
  try {
    data = await apiFetch("/api/me");
  } catch (err) {
    if (err.status === 401) {
      token = "";
      currentUser = null;
      writeStore(TOKEN_KEY, "");
      writeStore(USER_KEY, "");
      renderAuth();
      return;
    }
    throw err;
  }
  currentUser = data.user;
  writeStore(USER_KEY, JSON.stringify(currentUser));
  renderAuth();
  fillSettingsForm();
}

async function initApiOrigin() {
  const status = safeEl("connection-status");
  if (!REMOTE_MODE) {
    setApiOrigin("", false);
    localBackendUrls = normalizeLocalUrls([window.location.origin, "http://127.0.0.1:8788", "http://localhost:8788"]);
    if (status) status.textContent = "Local";
    applyDesmondVisibility();
    return true;
  }
  const cachedOrigin = readStore(REMOTE_ORIGIN_KEY) || "";
  setApiOrigin(cachedOrigin, false);
  try {
    await refreshRemoteBackendConfig({ force: true });
    if (status) status.textContent = "Live";
    applyDesmondVisibility();
    return true;
  } catch (err) {
    if (cachedOrigin) {
      if (status) {
        status.textContent = "Cached Live";
        status.dataset.state = "warn";
        status.title = `Using cached backend origin because live-config refresh failed: ${err.message || err}`;
      }
      applyDesmondVisibility();
      return true;
    }
    setApiOrigin("", false);
    renderBackendHelp(err);
    applyDesmondVisibility();
    return false;
  }
}

async function refreshAll() {
  await runLiveChecks({ silent: true }).catch(() => {});
  await Promise.all([loadCategories(), isSiteOwner() ? loadStats() : Promise.resolve(), loadTags()]);
  if (!galleryViewRestored) restoreGalleryViewState();
  if (currentPage === "collections") {
    await openCollectionsPage({ mine: collectionsMineMode, preserveSelection: true });
    return;
  }
  if (currentPage === "users") {
    await openUserSearchPage({ preserveQuery: true });
    return;
  }
  if (currentPage === "friends") {
    await openFriendsPage();
    return;
  }
  if (currentPage === "studio") {
    await openStudio();
    return;
  }
  if (currentPage === "profile" && activeProfileUsername) {
    await openProfile(activeProfileUsername);
    return;
  }
  await loadCurrentGalleryPage(galleryMode === "main" ? galleryPage : 1);
}

async function loadTags() {
  const data = await apiFetch("/api/tags");
  const tags = data.tags || [];
  const showCounts = isSiteOwner();
  $("tag-cloud").innerHTML = tags.length ? tags.map((item) => (
    `<button type="button" data-tag="${escapeHtml(item.tag)}">${escapeHtml(item.tag)}${showCounts ? ` <span>${item.count}</span>` : ""}</button>`
  )).join("") : `<span class="muted">${latestLiveSnapshot?.media_active ? "No public tags on loaded posts" : "Checking tags"}</span>`;
}

async function loadCategories() {
  const data = await apiFetch("/api/categories");
  categories = (data.categories || []).filter((category) => !isLegacyLeafCategory(category));
  const filter = $("category-filter");
  const subFilter = safeEl("subcategory-filter");
  const upload = $("upload-category");
  const uploadSubcategory = safeEl("upload-subcategory");
  const edit = safeEl("edit-media-category");
  const editSubcategory = safeEl("edit-media-subcategory");
  const selectedFilter = filter.value;
  const selectedSubFilter = subFilter?.value || "";
  const selectedUpload = upload.value;
  const selectedUploadSubcategory = uploadSubcategory?.value || "";
  const selectedEdit = edit?.value || "";
  const selectedEditSubcategory = editSubcategory?.value || "";
  filter.innerHTML = `<option value="">All categories</option>`;
  if (subFilter) subFilter.innerHTML = `<option value="">All subcategories</option>`;
  upload.innerHTML = `<option value="">Create new category</option>`;
  if (edit) edit.innerHTML = "";
  for (const category of categories) {
    const count = isSiteOwner() ? ` (${category.media_count || 0})` : "";
    filter.insertAdjacentHTML("beforeend", `<option value="${category.id}">${escapeHtml(category.name)}${count}</option>`);
    upload.insertAdjacentHTML("beforeend", `<option value="${category.id}">${escapeHtml(category.name)}</option>`);
    if (edit) edit.insertAdjacentHTML("beforeend", `<option value="${category.id}">${escapeHtml(category.name)}</option>`);
  }
  filter.value = selectedFilter;
  upload.value = selectedUpload || (categories[0]?.id ?? "");
  if (edit) edit.value = selectedEdit || (categories[0]?.id ?? "");
  populateSubcategorySelect("subcategory-filter", filter.value, {
    includeCreate: false,
    selectedValue: selectedSubFilter,
    emptyLabel: filter.value ? "All subcategories" : "All subcategories",
  });
  populateSubcategorySelect("upload-subcategory", upload.value, {
    includeCreate: Boolean(upload.value),
    selectedValue: selectedUploadSubcategory,
    emptyLabel: "No subcategory",
  });
  populateSubcategorySelect("edit-media-subcategory", edit?.value || "", {
    includeCreate: Boolean(edit?.value),
    selectedValue: selectedEditSubcategory,
    emptyLabel: "No subcategory",
  });
  toggleNewCategory();
  toggleEditSubcategory();
}

async function loadStats() {
  const data = await apiFetch("/api/stats");
  const stats = data.stats || {};
  $("stat-media").textContent = stats.media || 0;
  $("stat-likes").textContent = stats.likes || 0;
  $("stat-users").textContent = stats.users || 0;
  $("stat-bytes").textContent = formatBytes(stats.bytes || 0);
}

function galleryFiltersActive() {
  return Boolean(
    safeEl("search")?.value?.trim()
    || safeEl("kind-filter")?.value
    || safeEl("category-filter")?.value
    || safeEl("subcategory-filter")?.value
    || safeEl("uploader-filter")?.value?.trim()
    || safeEl("min-size-filter")?.value
    || safeEl("max-size-filter")?.value
    || safeEl("date-from-filter")?.value
    || safeEl("date-to-filter")?.value
    || (safeEl("adult-filter")?.value && safeEl("adult-filter")?.value !== "show")
  );
}

function galleryViewState() {
  return {
    search: safeEl("search")?.value?.trim() || "",
    kind: safeEl("kind-filter")?.value || "",
    category: safeEl("category-filter")?.value || "",
    subcategory: safeEl("subcategory-filter")?.value || "",
    uploader: safeEl("uploader-filter")?.value?.trim() || "",
    minSize: safeEl("min-size-filter")?.value || "",
    maxSize: safeEl("max-size-filter")?.value || "",
    dateFrom: safeEl("date-from-filter")?.value || "",
    dateTo: safeEl("date-to-filter")?.value || "",
    adult: safeEl("adult-filter")?.value || "show",
    sort: safeEl("sort-filter")?.value || "new",
    page: galleryPage,
  };
}

function saveGalleryViewState() {
  writeStore(GALLERY_VIEW_KEY, JSON.stringify(galleryViewState()));
}

function restoreGalleryViewState() {
  galleryViewRestored = true;
  const params = new URLSearchParams(location.search || "");
  const stored = readJsonStore(GALLERY_VIEW_KEY) || {};
  const state = {
    ...stored,
    search: params.get("q") ?? stored.search,
    kind: params.get("kind") ?? stored.kind,
    category: params.get("category") ?? stored.category,
    subcategory: params.get("subcategory") ?? stored.subcategory,
    uploader: params.get("uploader") ?? stored.uploader,
    minSize: params.get("minSize") ?? stored.minSize,
    maxSize: params.get("maxSize") ?? stored.maxSize,
    dateFrom: params.get("from") ?? stored.dateFrom,
    dateTo: params.get("to") ?? stored.dateTo,
    adult: params.get("adult") ?? stored.adult,
    sort: params.get("sort") ?? stored.sort,
    page: params.get("page") ?? stored.page,
  };
  if (safeEl("search")) $("search").value = state.search || "";
  if (safeEl("kind-filter")) $("kind-filter").value = state.kind || "";
  if (safeEl("category-filter")) $("category-filter").value = state.category || "";
  if (safeEl("subcategory-filter")) $("subcategory-filter").value = state.subcategory || "";
  if (safeEl("uploader-filter")) $("uploader-filter").value = state.uploader || "";
  if (safeEl("min-size-filter")) $("min-size-filter").value = state.minSize || "";
  if (safeEl("max-size-filter")) $("max-size-filter").value = state.maxSize || "";
  if (safeEl("date-from-filter")) $("date-from-filter").value = state.dateFrom || "";
  if (safeEl("date-to-filter")) $("date-to-filter").value = state.dateTo || "";
  if (safeEl("adult-filter")) $("adult-filter").value = state.adult || "show";
  if (safeEl("sort-filter")) $("sort-filter").value = state.sort || userSettings().default_sort || "new";
  galleryPage = Math.max(1, Number(state.page || 1));
}

function clearGalleryFilters() {
  if (safeEl("search")) $("search").value = "";
  if (safeEl("kind-filter")) $("kind-filter").value = "";
  if (safeEl("category-filter")) $("category-filter").value = "";
  if (safeEl("subcategory-filter")) $("subcategory-filter").value = "";
  if (safeEl("uploader-filter")) $("uploader-filter").value = "";
  if (safeEl("min-size-filter")) $("min-size-filter").value = "";
  if (safeEl("max-size-filter")) $("max-size-filter").value = "";
  if (safeEl("date-from-filter")) $("date-from-filter").value = "";
  if (safeEl("date-to-filter")) $("date-to-filter").value = "";
  if (safeEl("adult-filter")) $("adult-filter").value = "show";
  if (safeEl("sort-filter")) $("sort-filter").value = "new";
  galleryPage = 1;
  saveGalleryViewState();
  loadMedia(1, { scrollToTop: true });
}

function renderActiveFilters() {
  const wrap = safeEl("active-filters");
  if (!wrap) return;
  const state = galleryViewState();
  const category = categories.find((item) => String(item.id) === String(state.category));
  const subcategory = state.subcategory
    ? (state.category
      ? subcategoriesForCategory(state.category).find((item) => String(item.id) === String(state.subcategory))
      : categories.flatMap((item) => item.subcategories || []).find((item) => String(item.id) === String(state.subcategory)))
    : null;
  const chips = [];
  if (state.search) chips.push(["search", `Search: ${state.search}`]);
  if (state.kind) chips.push(["kind", `Type: ${state.kind === "image" ? "Images/GIFs" : "Videos"}`]);
  if (state.category) chips.push(["category", `Category: ${category?.name || state.category}`]);
  if (state.subcategory) chips.push(["subcategory", `Subcategory: ${subcategory?.name || state.subcategory}`]);
  if (state.uploader) chips.push(["uploader", `Uploader: ${state.uploader}`]);
  if (state.minSize) chips.push(["minSize", `Min: ${state.minSize} MB`]);
  if (state.maxSize) chips.push(["maxSize", `Max: ${state.maxSize} MB`]);
  if (state.dateFrom) chips.push(["dateFrom", `From: ${state.dateFrom}`]);
  if (state.dateTo) chips.push(["dateTo", `To: ${state.dateTo}`]);
  if (state.adult && state.adult !== "show") chips.push(["adult", state.adult === "only" ? "Only 18+" : "Hide 18+"]);
  if (state.sort && state.sort !== "new") chips.push(["sort", `Sort: ${$("sort-filter").selectedOptions?.[0]?.textContent || state.sort}`]);
  wrap.hidden = chips.length === 0;
  wrap.innerHTML = chips.map(([key, label]) => `<button type="button" data-clear-filter="${key}">${escapeHtml(label)} <span aria-hidden="true">x</span></button>`).join("")
    + (chips.length ? `<button type="button" data-clear-filter="all" class="clear-all">Clear All</button>` : "");
}

async function shareCurrentView() {
  const params = new URLSearchParams();
  const state = galleryViewState();
  if (state.search) params.set("q", state.search);
  if (state.kind) params.set("kind", state.kind);
  if (state.category) params.set("category", state.category);
  if (state.subcategory) params.set("subcategory", state.subcategory);
  if (state.uploader) params.set("uploader", state.uploader);
  if (state.minSize) params.set("minSize", state.minSize);
  if (state.maxSize) params.set("maxSize", state.maxSize);
  if (state.dateFrom) params.set("from", state.dateFrom);
  if (state.dateTo) params.set("to", state.dateTo);
  if (state.adult && state.adult !== "show") params.set("adult", state.adult);
  if (state.sort && state.sort !== "new") params.set("sort", state.sort);
  if (state.page > 1) params.set("page", String(state.page));
  const url = `${location.origin}${location.pathname}${params.toString() ? `?${params}` : ""}`;
  await copyText(url, "Current gallery view copied.");
}

function describeGalleryState(state) {
  const pieces = [];
  const category = categories.find((item) => String(item.id) === String(state.category));
  const subcategory = state.subcategory
    ? categories.flatMap((item) => item.subcategories || []).find((item) => String(item.id) === String(state.subcategory))
    : null;
  if (state.search) pieces.push(`"${state.search}"`);
  if (state.kind) pieces.push(state.kind === "image" ? "images" : "videos");
  if (state.category) pieces.push(category?.name || `category ${state.category}`);
  if (state.subcategory) pieces.push(subcategory?.name || `subcategory ${state.subcategory}`);
  if (state.uploader) pieces.push(`by ${state.uploader}`);
  if (state.minSize || state.maxSize) pieces.push(`${state.minSize || 0}-${state.maxSize || "any"} MB`);
  if (state.dateFrom || state.dateTo) pieces.push(`${state.dateFrom || "any"} to ${state.dateTo || "now"}`);
  if (state.adult && state.adult !== "show") pieces.push(state.adult === "only" ? "18+ only" : "18+ hidden");
  pieces.push((state.sort || "new").replace(/^./, (char) => char.toUpperCase()));
  return pieces.join(" · ");
}

function defaultSavedViewName(state) {
  const description = describeGalleryState(state);
  return description ? description.slice(0, 80) : "Fresh Drops";
}

function renderSavedViews() {
  const list = safeEl("saved-views-list");
  if (!list) return;
  const views = readSavedViews();
  list.innerHTML = views.length ? views.map((view) => `
    <article class="saved-view-card">
      <div>
        <h3>${escapeHtml(view.name || "Saved View")}</h3>
        <p class="muted">${escapeHtml(describeGalleryState(view.state || {}))}</p>
      </div>
      <div class="saved-view-actions">
        <button type="button" data-apply-saved-view="${escapeHtml(view.id)}">Apply</button>
        <button type="button" data-share-saved-view="${escapeHtml(view.id)}">Share</button>
        <button type="button" data-delete-saved-view="${escapeHtml(view.id)}">Delete</button>
      </div>
    </article>
  `).join("") : `<p class="muted">No saved views yet. Save a filter setup to jump back to it later.</p>`;
  enhanceMotion(list);
}

function openSavedViewsDialog() {
  const state = galleryViewState();
  const input = safeEl("saved-view-name");
  if (input && !input.value.trim()) input.value = defaultSavedViewName(state);
  renderSavedViews();
  safeEl("saved-views-dialog")?.showModal();
}

function applyGalleryState(state = {}) {
  if (safeEl("search")) $("search").value = state.search || "";
  if (safeEl("kind-filter")) $("kind-filter").value = state.kind || "";
  if (safeEl("category-filter")) $("category-filter").value = state.category || "";
  populateSubcategorySelect("subcategory-filter", state.category || "", {
    includeCreate: false,
    selectedValue: state.subcategory || "",
    emptyLabel: "All subcategories",
  });
  if (safeEl("uploader-filter")) $("uploader-filter").value = state.uploader || "";
  if (safeEl("min-size-filter")) $("min-size-filter").value = state.minSize || "";
  if (safeEl("max-size-filter")) $("max-size-filter").value = state.maxSize || "";
  if (safeEl("date-from-filter")) $("date-from-filter").value = state.dateFrom || "";
  if (safeEl("date-to-filter")) $("date-to-filter").value = state.dateTo || "";
  if (safeEl("adult-filter")) $("adult-filter").value = state.adult || "show";
  if (safeEl("sort-filter")) $("sort-filter").value = state.sort || "new";
  galleryPage = Math.max(1, Number(state.page || 1));
  saveGalleryViewState();
  loadMedia(galleryPage, { scrollToTop: true });
}

async function saveCurrentView(event) {
  if (event) event.preventDefault();
  const state = galleryViewState();
  const input = safeEl("saved-view-name");
  const name = (input?.value || defaultSavedViewName(state)).trim().slice(0, 80) || "Saved View";
  const views = readSavedViews();
  views.unshift({
    id: globalThis.crypto?.randomUUID?.() || String(Date.now()),
    name,
    state,
    created_at: new Date().toISOString(),
  });
  writeSavedViews(views.slice(0, 24));
  if (input) input.value = "";
  renderSavedViews();
  showToast("View saved.", "success");
}

async function shareSavedView(id) {
  const view = readSavedViews().find((item) => item.id === id);
  if (!view) return;
  const state = view.state || {};
  const params = new URLSearchParams();
  if (state.search) params.set("q", state.search);
  if (state.kind) params.set("kind", state.kind);
  if (state.category) params.set("category", state.category);
  if (state.subcategory) params.set("subcategory", state.subcategory);
  if (state.uploader) params.set("uploader", state.uploader);
  if (state.minSize) params.set("minSize", state.minSize);
  if (state.maxSize) params.set("maxSize", state.maxSize);
  if (state.dateFrom) params.set("from", state.dateFrom);
  if (state.dateTo) params.set("to", state.dateTo);
  if (state.adult && state.adult !== "show") params.set("adult", state.adult);
  if (state.sort && state.sort !== "new") params.set("sort", state.sort);
  if (Number(state.page) > 1) params.set("page", String(state.page));
  const url = `${location.origin}${location.pathname}${params.toString() ? `?${params}` : ""}`;
  await copyText(url, "Saved view link copied.");
}

function deleteSavedView(id) {
  writeSavedViews(readSavedViews().filter((view) => view.id !== id));
  renderSavedViews();
}

function setEmptyState(title, message, visible = true) {
  setTextIfPresent("empty-title", title);
  setTextIfPresent("empty-message", message);
  showIfPresent("empty-state", visible);
}

function updateGalleryPagination() {
  const pagination = safeEl("gallery-pagination");
  if (!pagination) return;
  const hasAnyPaging = galleryPage > 1 || galleryHasNext;
  pagination.hidden = galleryLoading || !hasAnyPaging;
  setTextIfPresent("gallery-page-status", `Page ${galleryPage}`);
  setDisabledIfPresent("gallery-prev", galleryPage <= 1);
  setDisabledIfPresent("gallery-next", !galleryHasNext);
}

function renderGallerySkeleton(count = 8) {
  const grid = safeEl("gallery-grid");
  if (!grid) return;
  const skeletonCount = isLowPowerMode() ? Math.min(count, 4) : count;
  grid.innerHTML = Array.from({ length: skeletonCount }).map((_, index) => `
    <article class="media-card skeleton-card" style="--delay:${index * 45}ms">
      <div class="skeleton-preview"></div>
      <div class="media-info">
        <div class="skeleton-line strong"></div>
        <div class="skeleton-line"></div>
        <div class="skeleton-actions"><span></span><span></span><span></span></div>
      </div>
    </article>
  `).join("");
  if (!isLowPowerMode()) enhanceMotion(grid);
}

async function loadMedia(page = galleryPage, { scrollToTop = false } = {}) {
  if (["following", "liked"].includes(currentPage)) setCurrentPage("discover");
  galleryLoadController?.abort();
  galleryLoadController = typeof AbortController !== "undefined" ? new AbortController() : null;
  const requestId = ++galleryRequestId;
  galleryMode = "main";
  galleryPage = Math.max(1, Number(page) || 1);
  renderGalleryHeading();
  renderTopbarPageState();
  renderPageSidebar();
  saveGalleryViewState();
  renderActiveFilters();
  galleryLoading = true;
  setTextIfPresent("result-count", `Loading page ${galleryPage}`);
  showIfPresent("empty-state", false);
  renderGallerySkeleton();
  updateGalleryPagination();
  const params = new URLSearchParams();
  if ($("kind-filter").value) params.set("media_kind", $("kind-filter").value);
  if ($("category-filter").value) params.set("category_id", $("category-filter").value);
  if (safeEl("subcategory-filter")?.value) params.set("subcategory_id", $("subcategory-filter").value);
  if ($("search").value.trim()) params.set("q", $("search").value.trim());
  if (safeEl("uploader-filter")?.value.trim()) params.set("uploader", $("uploader-filter").value.trim());
  if (mbToBytes(safeEl("min-size-filter")?.value)) params.set("min_size", String(mbToBytes($("min-size-filter").value)));
  if (mbToBytes(safeEl("max-size-filter")?.value)) params.set("max_size", String(mbToBytes($("max-size-filter").value)));
  if (safeEl("date-from-filter")?.value) params.set("date_from", $("date-from-filter").value);
  if (safeEl("date-to-filter")?.value) params.set("date_to", $("date-to-filter").value);
  if (safeEl("adult-filter")?.value && $("adult-filter").value !== "show") params.set("adult", $("adult-filter").value);
  params.set("sort", $("sort-filter").value);
  const pageSize = galleryPageSize();
  params.set("limit", pageSize + 1);
  params.set("offset", (galleryPage - 1) * pageSize);
  try {
    const data = await apiFetch(`/api/media?${params}`, galleryLoadController ? { signal: galleryLoadController.signal } : {});
    if (requestId !== galleryRequestId) return;
    const rows = data.media || [];
    galleryHasNext = rows.length > pageSize;
    mediaItems = rows.slice(0, pageSize);
    renderMediaGrid();
    scheduleGalleryAssetPrecache(mediaItems);
    if (scrollToTop) safeEl("gallery-grid")?.scrollIntoView({ behavior: isLowPowerMode() ? "auto" : "smooth", block: "start" });
  } catch (err) {
    if (err.name === "AbortError" || requestId !== galleryRequestId) return;
    mediaItems = [];
    galleryHasNext = false;
    $("gallery-grid").innerHTML = "";
    setTextIfPresent("result-count", err.message || "Gallery failed to load");
    setEmptyState("Gallery check needed", "The gallery could not load posts. Use Checks or Refresh to test the live backend.");
  } finally {
    if (requestId === galleryRequestId) {
      galleryLoading = false;
      updateGalleryPagination();
    }
  }
}

function focusGalleryOnNewestUploads() {
  const search = safeEl("search");
  const kind = safeEl("kind-filter");
  const category = safeEl("category-filter");
  const subcategory = safeEl("subcategory-filter");
  const sort = safeEl("sort-filter");
  if (search) search.value = "";
  if (kind) kind.value = "";
  if (category) category.value = "";
  if (subcategory) subcategory.value = "";
  if (sort) sort.value = "new";
  galleryPage = 1;
  saveGalleryViewState();
  renderActiveFilters();
}

function galleryItemById(id) {
  const numericId = Number(id);
  return mediaItems.find((entry) => Number(entry.id) === numericId)
    || (activeDetail && Number(activeDetail.id) === numericId ? activeDetail : null);
}

function updateCompareUi() {
  const tray = safeEl("compare-tray");
  const count = compareSelection.size;
  showIfPresent("compare-tray", count > 0);
  setTextIfPresent("compare-count", `${count} selected`);
  setDisabledIfPresent("compare-open", count < 2);
  setDisabledIfPresent("compare-tray-open", count < 2);
  setDisabledIfPresent("selection-slideshow", count < 1);
  setDisabledIfPresent("selection-like", count < 1);
  setDisabledIfPresent("selection-save", count < 1);
  setDisabledIfPresent("selection-collect", count < 1);
  if (tray) tray.title = count < 2 ? "Select at least two posts to compare." : "Open compare board.";
  document.querySelectorAll("[data-compare]").forEach((button) => {
    const selected = compareSelection.has(Number(button.dataset.compare));
    button.textContent = selected ? "Selected" : "Compare";
    button.setAttribute("aria-pressed", selected ? "true" : "false");
    button.closest(".media-card")?.classList.toggle("is-compared", selected);
  });
}

function toggleCompareSelection(id) {
  const numericId = Number(id);
  if (!numericId) return;
  if (compareSelection.has(numericId)) {
    compareSelection.delete(numericId);
  } else {
    compareSelection.add(numericId);
  }
  updateCompareUi();
}

function clearCompareSelection() {
  compareSelection.clear();
  updateCompareUi();
}

function compareItems() {
  return Array.from(compareSelection).map(galleryItemById).filter(Boolean);
}

function selectCurrentPage() {
  mediaItems.forEach((item) => {
    compareSelection.add(Number(item.id));
  });
  updateCompareUi();
  showToast(`${compareSelection.size} post${compareSelection.size === 1 ? "" : "s"} selected.`, "success");
}

function updateMediaItem(updated) {
  if (!updated?.id) return;
  mediaItems = mediaItems.map((entry) => Number(entry.id) === Number(updated.id) ? updated : entry);
  if (activeDetail && Number(activeDetail.id) === Number(updated.id)) activeDetail = updated;
}

async function bulkToggleSelection(endpoint, payloadKey, nextValue, successMessage) {
  if (!currentUser) return $("auth-dialog").showModal();
  const items = compareItems();
  if (!items.length) return;
  for (const item of items) {
    const data = await apiFetch(`/api/media/${item.id}/${endpoint}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ [payloadKey]: nextValue }),
    });
    updateMediaItem(data.media);
  }
  renderMediaGrid();
  showToast(successMessage, "success");
}

function openSelectedCollectionPicker() {
  const ids = compareItems().map((item) => item.id);
  if (!ids.length) return;
  openCollectionPicker(ids);
}

function renderCompareBoard() {
  const grid = safeEl("compare-grid");
  if (!grid) return;
  const allItems = compareItems();
  const items = allItems.slice(0, COMPARE_SELECTION_LIMIT);
  grid.innerHTML = items.length ? items.map((item) => `
    <article class="compare-card">
      <button class="mini-media" type="button" data-open="${item.id}">
        ${renderPreview(item, "mini")}
      </button>
      <h3>${adultBadge(item)}${escapeHtml(item.title)}</h3>
      <dl>
        <div><dt>Creator</dt><dd>${escapeHtml(item.display_name || item.username || "Unknown")}</dd></div>
        <div><dt>Category</dt><dd>${escapeHtml(categoryDisplayFromItem(item))}</dd></div>
        <div><dt>Type</dt><dd>${escapeHtml(item.media_kind || "media")}</dd></div>
        <div><dt>Size</dt><dd>${formatBytes(item.file_size)}</dd></div>
        <div><dt>Likes</dt><dd>${Number(item.like_count || 0)}</dd></div>
        <div><dt>Downloads</dt><dd>${Number(item.downloads || 0)}</dd></div>
      </dl>
      <div class="tag-row">${(item.tags || []).slice(0, 8).map((tag) => `<span>${escapeHtml(tag)}</span>`).join("")}</div>
      <div class="card-actions">
        <button type="button" data-open="${item.id}">Open</button>
        <button type="button" data-compare-remove="${item.id}">Remove</button>
      </div>
    </article>
  `).join("") + (allItems.length > COMPARE_SELECTION_LIMIT ? `<p class="muted">Showing the first ${COMPARE_SELECTION_LIMIT} selected posts in compare mode.</p>` : "") : `<p class="muted">Select posts from the gallery to compare them here.</p>`;
}

function openCompareBoard() {
  if (compareSelection.size < 2) {
    showToast("Select at least two posts to compare.", "error");
    return;
  }
  renderCompareBoard();
  safeEl("compare-dialog")?.showModal();
}

function topCounts(items, getter, limit = 5) {
  const counts = new Map();
  items.forEach((item) => {
    const values = getter(item);
    (Array.isArray(values) ? values : [values]).filter(Boolean).forEach((value) => {
      const label = String(value);
      counts.set(label, (counts.get(label) || 0) + 1);
    });
  });
  return Array.from(counts.entries())
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, limit)
    .map(([label, count]) => ({ label, count }));
}

function renderInsightBars(items) {
  const max = Math.max(1, ...items.map((item) => item.count));
  return items.length ? items.map((item) => `
    <div class="insight-bar">
      <span>${escapeHtml(item.label)}</span>
      <meter min="0" max="${max}" value="${item.count}"></meter>
      <strong>${item.count}</strong>
    </div>
  `).join("") : `<p class="muted">Nothing to chart on this page.</p>`;
}

function openInsights() {
  const view = safeEl("insights-view");
  if (!view) return;
  const items = mediaItems;
  const totals = items.reduce((acc, item) => {
    acc.likes += Number(item.like_count || 0);
    acc.downloads += Number(item.downloads || 0);
    acc.views += Number(item.views || 0);
    acc.bytes += Number(item.file_size || 0);
    acc.videos += item.media_kind === "video" ? 1 : 0;
    acc.adult += item.is_adult ? 1 : 0;
    return acc;
  }, { likes: 0, downloads: 0, views: 0, bytes: 0, videos: 0, adult: 0 });
  const images = Math.max(0, items.length - totals.videos);
  view.innerHTML = `
    <section class="insight-summary">
      <div><strong>${items.length}</strong><span>On page</span></div>
      <div><strong>${images}</strong><span>Images/GIFs</span></div>
      <div><strong>${totals.videos}</strong><span>Videos</span></div>
      <div><strong>${formatBytes(totals.bytes)}</strong><span>Loaded size</span></div>
      <div><strong>${totals.likes}</strong><span>Likes</span></div>
      <div><strong>${totals.downloads}</strong><span>Downloads</span></div>
    </section>
    <section class="insight-grid">
      <article>
        <h3>Top Tags</h3>
        ${renderInsightBars(topCounts(items, (item) => item.tags || []))}
      </article>
      <article>
        <h3>Top Categories</h3>
        ${renderInsightBars(topCounts(items, (item) => categoryDisplayFromItem(item)))}
      </article>
      <article>
        <h3>Top Creators</h3>
        ${renderInsightBars(topCounts(items, (item) => item.display_name || item.username))}
      </article>
      <article>
        <h3>Safety Mix</h3>
        ${renderInsightBars([{ label: "Standard", count: items.length - totals.adult }, { label: "18+", count: totals.adult }])}
      </article>
    </section>
  `;
  safeEl("insights-dialog")?.showModal();
}

function currentSlideshowItems() {
  return (slideshowItemsOverride || mediaItems).filter((item) => item?.url && canRevealAdult(item));
}

function stopSlideshow() {
  clearInterval(slideshowTimer);
  slideshowTimer = 0;
  slideshowPlaying = false;
  setTextIfPresent("slideshow-play", "Play");
}

function closeSlideshow() {
  stopSlideshow();
  slideshowItemsOverride = null;
  safeEl("slideshow-dialog")?.close();
}

function renderSlideshowSlide() {
  const items = currentSlideshowItems();
  const stage = safeEl("slideshow-stage");
  if (!stage) return;
  if (!items.length) {
    stage.innerHTML = `<div class="empty-state"><h2>No playable posts</h2><p>Use the current page with visible images or videos, or verify age for 18+ posts.</p></div>`;
    setTextIfPresent("slideshow-title", "Slideshow");
    setTextIfPresent("slideshow-meta", "");
    stopSlideshow();
    return;
  }
  slideshowIndex = Math.max(0, Math.min(slideshowIndex, items.length - 1));
  const item = items[slideshowIndex];
  const mediaUrl = normalizedPublicUrl(item.url);
  stage.innerHTML = !mediaUrl
    ? `<div class="empty-state"><h2>Preview unavailable</h2><p>This post does not have a safe preview URL right now.</p></div>`
    : item.media_kind === "video"
      ? `<video src="${escapeHtml(mediaUrl)}" controls autoplay playsinline ${userSettings().muted_previews ? "muted" : ""}></video>`
      : `<img src="${escapeHtml(mediaUrl)}" alt="${escapeHtml(item.title)}" />`;
  setTextIfPresent("slideshow-title", item.title || "Slideshow");
  setTextIfPresent("slideshow-meta", `${slideshowIndex + 1} of ${items.length} · ${categoryDisplayFromItem(item)} · ${formatBytes(item.file_size)}`);
}

function moveSlideshow(direction) {
  const items = currentSlideshowItems();
  if (!items.length) return;
  slideshowIndex = (slideshowIndex + direction + items.length) % items.length;
  renderSlideshowSlide();
}

function startSlideshow() {
  const delay = Number(safeEl("slideshow-delay")?.value || 4000);
  stopSlideshow();
  slideshowPlaying = true;
  setTextIfPresent("slideshow-play", "Pause");
  slideshowTimer = setInterval(() => moveSlideshow(1), Math.max(1200, delay));
}

function toggleSlideshowPlay() {
  if (slideshowPlaying) stopSlideshow();
  else startSlideshow();
}

function openSlideshow(sourceItems = null) {
  slideshowItemsOverride = Array.isArray(sourceItems) ? sourceItems : null;
  const items = currentSlideshowItems();
  if (!items.length) {
    slideshowItemsOverride = null;
    showToast("No visible media on this page for slideshow.", "error");
    return;
  }
  slideshowIndex = 0;
  renderSlideshowSlide();
  safeEl("slideshow-dialog")?.showModal();
}

function renderMediaGrid() {
  const grid = $("gallery-grid");
  grid.innerHTML = "";
  const fragment = document.createDocumentFragment();
  const visibleIds = new Set(mediaItems.map((item) => Number(item.id)));
  compareSelection = new Set(Array.from(compareSelection).filter((id) => visibleIds.has(Number(id))));
  const start = mediaItems.length ? ((galleryPage - 1) * galleryPageSize()) + 1 : 0;
  const end = start + mediaItems.length - 1;
  $("result-count").textContent = mediaItems.length
    ? `Page ${galleryPage} · showing ${start}-${end}${galleryHasNext ? "+" : ""}`
    : galleryFiltersActive()
      ? `${galleryMode === "liked" ? "No saved likes" : galleryMode === "following" ? "No following posts" : "No posts match this view"}`
      : latestLiveSnapshot?.media_active
        ? `${Number(latestLiveSnapshot.media_active)} posts live · refresh if they do not appear`
        : "Checking for posts";
  if (!mediaItems.length) {
    if (galleryMode === "following") {
      setEmptyState("Nothing from follows yet", "Follow uploaders to build a paged feed here.");
    } else if (galleryMode === "liked") {
      setEmptyState("No liked posts yet", "Like posts to keep them in this paged view.");
    } else if (galleryFiltersActive()) {
      setEmptyState("No matches", "Try clearing search, category, or media-type filters.");
    } else if (latestLiveSnapshot?.media_active) {
      setEmptyState("Posts are live", "The backend reports posts are available. Refresh or run Checks if this page stays empty.", false);
    } else {
      setEmptyState("Gallery loading", "Checking the live backend before showing an empty gallery.", false);
    }
  } else {
    showIfPresent("empty-state", false);
  }
  renderActiveFilters();
  updateGalleryPagination();
  for (const item of mediaItems) {
    const card = document.createElement("article");
    const selectedForCompare = compareSelection.has(Number(item.id));
    const accent = safeHexColor(item.profile_color, "#37c9a7");
    const avatarUrl = avatarUrlForRecord(item, { urlKey: "user_avatar_url", pathKey: "user_avatar_path", fileIdKey: "user_avatar_file_id", idKey: "user_id" });
    card.className = `media-card${item.is_adult ? " adult-card" : ""}${selectedForCompare ? " is-compared" : ""}`;
    card.dataset.open = item.id;
    card.innerHTML = `
      <button class="media-preview" type="button" data-open="${item.id}">${renderPreview(item)}</button>
      <div class="media-info">
        <div class="media-kicker-row">
          <span class="media-kicker">${escapeHtml(categoryDisplayFromItem(item))}</span>
          <span class="media-kicker subtle">${escapeHtml(item.media_kind === "video" ? "Video" : "Image")}</span>
        </div>
        <div class="author-row media-card-head">
          <button type="button" class="avatar tiny" style="border-color:${accent}" data-profile="${escapeHtml(item.username || "")}">${avatarUrl ? `<img src="${escapeHtml(avatarUrl)}" alt="">` : escapeHtml((item.display_name || item.username || "IG").slice(0, 2).toUpperCase())}</button>
          <div class="media-copy">
            <h2>${adultBadge(item)}${escapeHtml(item.title)}</h2>
            <p class="muted">by <button type="button" class="text-button" data-profile="${escapeHtml(item.username || "")}">${escapeHtml(item.display_name || item.username)}</button>${item.visibility && item.visibility !== "public" ? ` · ${escapeHtml(item.visibility)}` : ""}${item.pinned_at ? " · pinned" : ""}</p>
          </div>
        </div>
        <div class="metric-row">
          <span>${item.like_count || 0} likes</span>
          <span>${item.downloads || 0} downloads</span>
          <span>${formatBytes(item.file_size)}</span>
        </div>
        <div class="tag-row compact">${(item.tags || []).slice(0, 4).map((tag) => `<span>${escapeHtml(tag)}</span>`).join("") || `<span>untagged</span>`}</div>
        <div class="card-actions">
          <button type="button" data-compare="${item.id}" aria-pressed="${selectedForCompare ? "true" : "false"}">${selectedForCompare ? "Selected" : "Compare"}</button>
          <button type="button" data-like="${item.id}">${item.liked_by_me ? "Unlike" : "Like"}</button>
          <button type="button" data-bookmark="${item.id}">${item.bookmarked_by_me ? "Saved" : "Save"}</button>
          <button type="button" data-collect="${item.id}">Collect</button>
          <button type="button" data-copy="${item.id}" ${item.url ? "" : "disabled"}>Copy Address</button>
          ${currentUser && Number(item.user_id) === Number(currentUser.id) ? `<button type="button" data-edit-media="${item.id}">Manage</button><button type="button" data-delete-media="${item.id}" class="danger-button">Delete</button>` : ""}
          ${item.downloads_enabled !== false ? `<button type="button" data-download="${item.id}" class="button-link">Download</button>` : `<button type="button" disabled>No downloads</button>`}
        </div>
      </div>
    `;
    fragment.appendChild(card);
  }
  grid.appendChild(fragment);
  updateCompareUi();
  enhanceMotion(grid);
}

async function loadCurrentGalleryPage(page = galleryPage, options = {}) {
  if (galleryMode === "following") return loadFollowingFeed(page, options);
  if (galleryMode === "liked") return loadLikedFeed(page, options);
  return loadMedia(page, options);
}

async function openDetail(id, options = {}) {
  const { updateRoute = true, replaceRoute = false } = options;
  let data;
  try {
    data = await apiFetch(`/api/media/${id}`);
  } catch (err) {
    if (err.status === 403) {
      openAgeDialog(err.message);
      return;
    }
    throw err;
  }
  if (updateRoute) routeTo(`/media/${encodeURIComponent(id)}`, { replace: replaceRoute });
  stopMediaPlayback($("detail-dialog"));
  activeDetail = data.media;
  const item = activeDetail;
  const mediaUrl = normalizedPublicUrl(item.url);
  const avatarUrl = avatarUrlForRecord(item, { urlKey: "user_avatar_url", pathKey: "user_avatar_path", fileIdKey: "user_avatar_file_id", idKey: "user_id" });
  const websiteUrl = normalizedPublicUrl(item.user_website_url);
  $("detail-title").innerHTML = `${adultBadge(item)}${escapeHtml(item.title)}`;
  $("detail-media").innerHTML = !mediaUrl
    ? `<div class="empty-state"><h2>Preview unavailable</h2><p>This post does not have a safe media URL right now.</p></div>`
    : item.media_kind === "video"
      ? `<video src="${escapeHtml(mediaUrl)}" controls autoplay playsinline></video>`
      : `<img src="${escapeHtml(mediaUrl)}" alt="${escapeHtml(item.title)}" />`;
  resetDetailTransform();
  $("detail-meta").textContent = `${categoryDisplayFromItem(item)} by ${item.display_name || item.username} - ${formatBytes(item.file_size)} - ${item.like_count || 0} likes`;
  renderDetailInspector(item);
  $("detail-description").innerHTML = `
    ${avatarUrl ? `<div class="profile-mini"><button type="button" class="avatar" data-profile="${escapeHtml(item.username || "")}"><img src="${escapeHtml(avatarUrl)}" alt=""></button><div><button type="button" class="text-button strong" data-profile="${escapeHtml(item.username || "")}">${escapeHtml(item.display_name || item.username)}</button>${item.user_bio ? `<p>${escapeHtml(item.user_bio)}</p>` : ""}${websiteUrl ? `<a href="${escapeHtml(websiteUrl)}" target="_blank" rel="noopener">Website</a>` : ""}</div></div>` : ""}
    <p>${escapeHtml(item.description || "")}</p>
  `;
  $("detail-tags").innerHTML = (item.tags || []).map((tag) => `<span>${escapeHtml(tag)}</span>`).join("");
  $("detail-like").textContent = item.liked_by_me ? "Unlike" : "Like";
  $("detail-bookmark").textContent = item.bookmarked_by_me ? "Saved" : "Bookmark";
  $("detail-download").href = "#";
  $("detail-download").dataset.download = item.id;
  $("detail-download").toggleAttribute("aria-disabled", item.downloads_enabled === false);
  updateDetailNavButtons();
  renderComments(data.comments || []);
  const commentForm = $("comment-form");
  if (commentForm) commentForm.hidden = item.comments_enabled === false && Number(item.user_id) !== Number(currentUser?.id);
  if (!$("detail-dialog").open) $("detail-dialog").showModal();
}

function currentDetailIndex() {
  if (!activeDetail) return -1;
  return mediaItems.findIndex((entry) => Number(entry.id) === Number(activeDetail.id));
}

function updateDetailNavButtons() {
  const index = currentDetailIndex();
  setDisabledIfPresent("detail-prev", index <= 0);
  setDisabledIfPresent("detail-next", index < 0 || index >= mediaItems.length - 1);
}

async function openAdjacentDetail(direction) {
  const index = currentDetailIndex();
  const next = mediaItems[index + direction];
  if (!next) return;
  if (!handleAdultOpen(next.id)) await openDetail(next.id);
}

function renderComments(comments) {
  $("comments-list").innerHTML = comments.map((comment) => {
    const canDelete = currentUser && (Number(comment.user_id) === Number(currentUser.id) || Number(activeDetail?.user_id) === Number(currentUser.id));
    const avatarUrl = avatarUrlForRecord(comment, { urlKey: "user_avatar_url", pathKey: "user_avatar_path", fileIdKey: "user_avatar_file_id", idKey: "user_id" });
    return `
      <div class="comment">
        <div class="comment-head">
          <div class="avatar tiny">${avatarUrl ? `<img src="${escapeHtml(avatarUrl)}" alt="">` : escapeHtml((comment.display_name || comment.username || "IG").slice(0, 2).toUpperCase())}</div>
          <strong>${escapeHtml(comment.display_name || comment.username)}</strong>
          ${canDelete ? `<button type="button" class="comment-delete" data-delete-comment="${comment.id}">Delete</button>` : ""}
        </div>
        <p>${escapeHtml(comment.body)}</p>
      </div>
    `;
  }).join("");
}

async function deleteComment(id) {
  if (!confirm("Delete this comment?")) return;
  await apiFetch(`/api/comments/${id}`, { method: "DELETE" });
  if (activeDetail) await openDetail(activeDetail.id);
}

async function toggleBookmark(id, bookmarked = null) {
  if (!currentUser) return $("auth-dialog").showModal();
  const item = mediaItems.find((entry) => Number(entry.id) === Number(id)) || activeDetail;
  const nextBookmarked = bookmarked ?? !item?.bookmarked_by_me;
  const data = await apiFetch(`/api/media/${id}/bookmark`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ bookmarked: nextBookmarked }),
  });
  const updated = data.media;
  mediaItems = mediaItems.map((entry) => Number(entry.id) === Number(id) ? updated : entry);
  if (activeDetail && Number(activeDetail.id) === Number(id)) activeDetail = updated;
  renderMediaGrid();
  if (activeDetail && Number(activeDetail.id) === Number(id)) {
    $("detail-bookmark").textContent = updated.bookmarked_by_me ? "Saved" : "Bookmark";
  }
  showToast(updated.bookmarked_by_me ? "Saved to bookmarks." : "Removed from bookmarks.", "success");
}

async function toggleLike(id, liked = null) {
  if (!currentUser) return $("auth-dialog").showModal();
  const item = mediaItems.find((entry) => Number(entry.id) === Number(id)) || activeDetail;
  const nextLiked = liked ?? !item?.liked_by_me;
  const data = await apiFetch(`/api/media/${id}/like`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ liked: nextLiked }),
  });
  const updated = data.media;
  mediaItems = mediaItems.map((entry) => Number(entry.id) === Number(id) ? updated : entry);
  if (activeDetail && Number(activeDetail.id) === Number(id)) activeDetail = updated;
  renderMediaGrid();
  if (activeDetail && Number(activeDetail.id) === Number(id)) {
    $("detail-like").textContent = updated.liked_by_me ? "Unlike" : "Like";
    $("detail-meta").textContent = `${categoryDisplayFromItem(updated)} by ${updated.display_name || updated.username} - ${formatBytes(updated.file_size)} - ${updated.like_count || 0} likes`;
  }
  showToast(updated.liked_by_me ? "Liked." : "Like removed.", "success");
  if (isSiteOwner()) await loadStats().catch(() => {});
}

async function openSurprise() {
  const data = await apiFetch("/api/media/random");
  if (data.media?.id) await openDetail(data.media.id);
}

async function loadCollections(mine = false) {
  const data = await apiFetch(`/api/collections${mine ? "?mine=true" : ""}`);
  collectionsState = data.collections || [];
  renderCollections();
  return collectionsState;
}

function collectionCardMarkup(collection) {
  return `
    <article class="collection-card">
      <button type="button" data-collection-open="${collection.id}" class="collection-cover">
        ${collection.cover_url ? `<img src="${safeUrl(collection.cover_url)}" alt="">` : `<span>${collection.cover_locked ? "18+" : escapeHtml(collection.name.slice(0, 2).toUpperCase())}</span>`}
      </button>
      <div>
        <h3>${escapeHtml(collection.name)}</h3>
        <p class="muted">${escapeHtml(collection.description || "No description")} · ${collection.item_count || 0} posts · ${collection.is_public ? "Public" : "Private"}</p>
        <p class="muted">by ${escapeHtml(collection.display_name || collection.username || "Unknown")}</p>
      </div>
    </article>
  `;
}

function renderCollections() {
  const markup = collectionsState.length
    ? collectionsState.map((collection) => collectionCardMarkup(collection)).join("")
    : `<p class="muted">No collections yet.</p>`;
  if (safeEl("collections-list")) $("collections-list").innerHTML = markup;
  if (safeEl("collections-page-list")) $("collections-page-list").innerHTML = markup;
  if (safeEl("collections-page-subtitle")) {
    $("collections-page-subtitle").textContent = collectionsMineMode
      ? "Your public and private collections live here with an editing rail beside them."
      : "Browse public community-made sets and inspect them in a dedicated detail panel.";
  }
  showIfPresent("collections-page-form", Boolean(currentUser) && collectionsMineMode);
  renderPageSidebar();
  enhanceMotion(safeEl("collections-list"));
  enhanceMotion(safeEl("collections-page-list"));
  enhanceMotion(safeEl("collections-page"));
}

function collectionDetailMarkup(collection, media) {
  return `
    <div class="section-title-row"><h3>${escapeHtml(collection.name)}</h3><span class="muted">${media.length} posts</span></div>
    ${collection.description ? `<p class="muted">${escapeHtml(collection.description)}</p>` : ""}
    <div class="mini-media-grid">${media.length ? media.map((item) => `
      <button class="mini-media" type="button" data-open="${item.id}">
        ${renderPreview(item, "mini")}
        <span>${adultBadge(item)}${escapeHtml(item.title)}</span>
      </button>
    `).join("") : `<p class="muted">This collection is empty.</p>`}</div>
  `;
}

async function openCollectionsPage({ mine = false, preserveSelection = false } = {}) {
  collectionsMineMode = Boolean(mine && currentUser);
  setCurrentPage("collections");
  setNotice("collections-page-error", "");
  if (safeEl("collection-media")) $("collection-media").innerHTML = "";
  if (safeEl("collections-page-detail") && !preserveSelection) {
    $("collections-page-detail").innerHTML = `
      <div class="empty-state page-empty-state">
        <h2>Select a collection</h2>
        <p>Its post rail, visibility, and owner info will appear here.</p>
      </div>
    `;
  }
  await loadCollections(collectionsMineMode);
  const preferredId = preserveSelection ? activeCollectionId : null;
  const firstId = preferredId || collectionsState[0]?.id;
  if (firstId) {
    await openCollection(firstId);
  }
}

async function createCollectionFromInputs({ name, description, isPublic, noticeId }) {
  if (!currentUser) return $("auth-dialog").showModal();
  setNotice(noticeId, "");
  try {
    await apiFetch("/api/collections", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name,
        description,
        is_public: isPublic,
      }),
    });
    activeCollectionId = null;
    showToast("Collection created.", "success");
    await openCollectionsPage({ mine: true, preserveSelection: true });
  } catch (err) {
    setNotice(noticeId, err.message);
  }
}

async function openCollection(id) {
  activeCollectionId = Number(id) || null;
  const data = await apiFetch(`/api/collections/${id}`);
  const media = data.media || [];
  const markup = collectionDetailMarkup(data.collection, media);
  if (safeEl("collection-media")) $("collection-media").innerHTML = markup;
  if (safeEl("collections-page-detail")) $("collections-page-detail").innerHTML = markup;
}

async function openCollectionPicker(mediaId) {
  if (!currentUser) return $("auth-dialog").showModal();
  selectedCollectionMediaId = Array.isArray(mediaId) ? mediaId.map(Number).filter(Boolean) : Number(mediaId);
  setNotice("collection-picker-error", "");
  const collections = await loadCollections(true);
  $("collection-picker-select").innerHTML = collections.map((collection) => (
    `<option value="${collection.id}">${escapeHtml(collection.name)}</option>`
  )).join("");
  if (!collections.length) {
    setNotice("collection-picker-error", "Create a collection first.");
  }
  $("collection-picker-dialog").showModal();
}

async function addToCollection(event) {
  event.preventDefault();
  if (!selectedCollectionMediaId) return;
  const collectionId = $("collection-picker-select").value;
  if (!collectionId) return setNotice("collection-picker-error", "Choose a collection first.");
  try {
    const ids = Array.isArray(selectedCollectionMediaId) ? selectedCollectionMediaId : [selectedCollectionMediaId];
    for (const mediaId of ids) {
      await apiFetch(`/api/collections/${collectionId}/items`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ media_id: Number(mediaId), saved: true }),
      });
    }
    $("collection-picker-dialog").close();
    showToast(ids.length > 1 ? "Selected posts added to collection." : "Added to collection.", "success");
  } catch (err) {
    setNotice("collection-picker-error", err.message);
  }
}

async function openStudio() {
  if (!currentUser) {
    setCurrentPage("studio");
    if (safeEl("studio-page-list")) $("studio-page-list").innerHTML = `<p class="muted">Sign in to manage your uploads and creator tools.</p>`;
    renderPageSidebar();
    return $("auth-dialog").showModal();
  }
  const data = await apiFetch("/api/me/media");
  const items = data.media || [];
  const totals = items.reduce((acc, item) => {
    acc.views += Number(item.views || 0);
    acc.downloads += Number(item.downloads || 0);
    acc.likes += Number(item.like_count || 0);
    return acc;
  }, { views: 0, downloads: 0, likes: 0 });
  studioPageState = { items, totals };
  $("studio-posts").textContent = items.length;
  $("studio-views").textContent = totals.views;
  $("studio-downloads").textContent = totals.downloads;
  $("studio-likes").textContent = totals.likes;
  if (safeEl("studio-page-posts")) $("studio-page-posts").textContent = items.length;
  if (safeEl("studio-page-views")) $("studio-page-views").textContent = totals.views;
  if (safeEl("studio-page-downloads")) $("studio-page-downloads").textContent = totals.downloads;
  if (safeEl("studio-page-likes")) $("studio-page-likes").textContent = totals.likes;
  const markup = items.length ? items.map((item) => `
    <article class="studio-item">
      <button type="button" data-open="${item.id}" class="studio-thumb">
        ${renderPreview(item, "mini")}
      </button>
      <div>
        <h3>${adultBadge(item)}${escapeHtml(item.title)}</h3>
        <p class="muted">${item.views || 0} views · ${item.downloads || 0} downloads · ${item.like_count || 0} likes</p>
      </div>
      <button type="button" data-edit-media="${item.id}">Edit</button>
      <button type="button" data-delete-media="${item.id}">Delete</button>
    </article>
  `).join("") : `<p class="muted">You have not uploaded anything yet.</p>`;
  if (safeEl("studio-list")) $("studio-list").innerHTML = markup;
  if (safeEl("studio-page-list")) $("studio-page-list").innerHTML = markup;
  setCurrentPage("studio");
  renderPageSidebar();
  enhanceMotion(safeEl("studio-page"));
  enhanceMotion(safeEl("studio-dialog"));
}

async function editOwnMedia(id) {
  const item = (await apiFetch(`/api/media/${id}`)).media;
  setNotice("edit-media-error", "");
  $("edit-media-id").value = item.id;
  $("edit-media-title").value = item.title || "";
  $("edit-media-description").value = item.description || "";
  $("edit-media-tags").value = (item.tags || []).join(", ");
  $("edit-media-category").value = item.category_id || categories[0]?.id || "";
  populateSubcategorySelect("edit-media-subcategory", $("edit-media-category").value, {
    includeCreate: true,
    selectedValue: item.subcategory_id || "",
    emptyLabel: "No subcategory",
  });
  $("edit-media-visibility").value = item.visibility || "public";
  $("edit-media-comments-enabled").checked = item.comments_enabled !== false;
  $("edit-media-downloads-enabled").checked = item.downloads_enabled !== false;
  $("edit-media-pinned").checked = Boolean(item.pinned_at);
  $("edit-media-adult").checked = Boolean(item.is_adult);
  if (safeEl("edit-new-subcategory-name")) $("edit-new-subcategory-name").value = "";
  toggleEditSubcategory();
  $("edit-media-dialog").showModal();
}

async function submitEditMedia(event) {
  event.preventDefault();
  const id = $("edit-media-id").value;
  const title = $("edit-media-title").value.trim();
  const categoryId = Number($("edit-media-category").value || categories[0]?.id || 0);
  if (!title) return setNotice("edit-media-error", "Title is required.");
  if (!categoryId) return setNotice("edit-media-error", "Choose a category.");
  try {
    const data = await apiFetch(`/api/media/${id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title,
        description: $("edit-media-description").value.trim() || null,
        category_id: categoryId,
        subcategory_id: $("edit-media-subcategory").value && $("edit-media-subcategory").value !== "__new__" ? Number($("edit-media-subcategory").value) : null,
        subcategory_name: $("edit-media-subcategory").value === "__new__" ? $("edit-new-subcategory-name").value.trim() || null : null,
        tags: $("edit-media-tags").value.split(",").map((tag) => tag.trim()).filter(Boolean),
        is_adult: $("edit-media-adult").checked,
        visibility: $("edit-media-visibility").value,
        comments_enabled: $("edit-media-comments-enabled").checked,
        downloads_enabled: $("edit-media-downloads-enabled").checked,
        pinned: $("edit-media-pinned").checked,
      }),
    });
    mediaItems = mediaItems.map((entry) => Number(entry.id) === Number(id) ? data.media : entry);
    $("edit-media-dialog").close();
    await openStudio();
    await refreshAll();
  } catch (err) {
    setNotice("edit-media-error", err.message);
  }
}

async function restoreOwnMedia(id) {
  await apiFetch(`/api/media/${id}/restore`, { method: "POST" });
  await openStudio();
  await refreshAll();
}

async function loadPagedFeed(path, mode, page = 1, { scrollToTop = false } = {}) {
  galleryLoadController?.abort();
  galleryLoadController = typeof AbortController !== "undefined" ? new AbortController() : null;
  const requestId = ++galleryRequestId;
  galleryMode = mode;
  galleryPage = Math.max(1, Number(page) || 1);
  galleryLoading = true;
  renderGalleryHeading();
  renderTopbarPageState();
  renderPageSidebar();
  setTextIfPresent("result-count", `Loading page ${galleryPage}`);
  showIfPresent("empty-state", false);
  renderGallerySkeleton();
  updateGalleryPagination();
  const params = new URLSearchParams({
    limit: String(galleryPageSize() + 1),
    offset: String((galleryPage - 1) * galleryPageSize()),
  });
  try {
    const data = await apiFetch(`${path}?${params}`, galleryLoadController ? { signal: galleryLoadController.signal } : {});
    if (requestId !== galleryRequestId) return;
    const rows = data.media || [];
    const pageSize = galleryPageSize();
    galleryHasNext = rows.length > pageSize;
    mediaItems = rows.slice(0, pageSize);
    renderMediaGrid();
    scheduleGalleryAssetPrecache(mediaItems);
    if (scrollToTop) safeEl("gallery-grid")?.scrollIntoView({ behavior: isLowPowerMode() ? "auto" : "smooth", block: "start" });
  } catch (err) {
    if (err.name === "AbortError" || requestId !== galleryRequestId) return;
    mediaItems = [];
    galleryHasNext = false;
    $("gallery-grid").innerHTML = "";
    setTextIfPresent("result-count", err.message || "Feed failed to load");
    setEmptyState("Feed check needed", "This feed could not load. Use Checks or Refresh to test the live backend.");
  } finally {
    if (requestId === galleryRequestId) {
      galleryLoading = false;
      updateGalleryPagination();
    }
  }
}

async function loadFollowingFeed(page = 1, options = {}) {
  if (!currentUser) return $("auth-dialog").showModal();
  return loadPagedFeed("/api/feed/following", "following", page, options);
}

async function loadLikedFeed(page = 1, options = {}) {
  if (!currentUser) return $("auth-dialog").showModal();
  return loadPagedFeed("/api/me/likes", "liked", page, options);
}

async function openDiscoverPage() {
  galleryMode = "main";
  setCurrentPage("discover");
  return loadMedia(galleryPage || 1, { scrollToTop: true });
}

async function openFollowingPage() {
  setCurrentPage("following");
  return loadFollowingFeed(1, { scrollToTop: true });
}

async function openLikedPage() {
  setCurrentPage("liked");
  return loadLikedFeed(1, { scrollToTop: true });
}

function friendButtonLabel(status) {
  return {
    self: "You",
    friends: "Friends",
    pending_out: "Requested",
    pending_in: "Accept Request",
  }[status || "none"] || "Add Friend";
}

function userCard(user, { compact = false } = {}) {
  const avatarUrl = avatarUrlForRecord(user);
  const accent = safeHexColor(user.profile_color, "#37c9a7");
  const avatar = avatarUrl
    ? `<img src="${escapeHtml(avatarUrl)}" alt="">`
    : escapeHtml((user.display_name || user.username || "IG").slice(0, 2).toUpperCase());
  return `
    <article class="user-card">
      <button type="button" class="avatar" style="border-color:${accent}" data-profile="${escapeHtml(user.username)}">${avatar}</button>
      <div>
        <h3>${escapeHtml(user.display_name || user.username)}</h3>
        <p class="muted">@${escapeHtml(user.username)}${user.profile_headline ? ` - ${escapeHtml(user.profile_headline)}` : ""}</p>
        ${!compact && user.bio ? `<p>${escapeHtml(user.bio)}</p>` : ""}
        ${!compact ? `<p class="muted">${Number(user.media_count || 0)} posts · ${Number(user.follower_count || 0)} followers</p>` : ""}
      </div>
      <div class="user-card-actions">
        <button type="button" data-profile="${escapeHtml(user.username)}">Profile</button>
        <button type="button" data-follow-user="${user.id}">${user.followed_by_me ? "Unfollow" : "Follow"}</button>
        <button type="button" data-friend-user="${user.id}" ${["self", "friends", "pending_out"].includes(user.friend_status) ? "disabled" : ""}>${friendButtonLabel(user.friend_status)}</button>
      </div>
    </article>
  `;
}

function activeUserSearchInput() {
  return currentPage === "users" ? safeEl("users-page-query") : safeEl("user-search-input");
}

async function openUserSearchPage({ preserveQuery = false } = {}) {
  setCurrentPage("users");
  const input = activeUserSearchInput();
  if (input && !preserveQuery && !input.value.trim()) input.value = "";
  input?.focus();
  await searchUsers();
}

async function searchUsers() {
  const input = activeUserSearchInput();
  const query = input?.value.trim() || "";
  const resultsId = currentPage === "users" ? "users-page-results" : "user-search-results";
  const list = safeEl(resultsId);
  const mirror = resultsId === "users-page-results" ? safeEl("user-search-results") : safeEl("users-page-results");
  if (!query) {
    if (list) list.innerHTML = `<p class="muted">Search by username, display name, bio, or headline.</p>`;
    if (mirror) mirror.innerHTML = list?.innerHTML || "";
    renderPageSidebar();
    return;
  }
  try {
    const data = await apiFetch(`/api/users/search?q=${encodeURIComponent(query)}`);
    const users = data.users || [];
    const markup = users.length ? users.map((user) => userCard(user)).join("") : `<p class="muted">No users found.</p>`;
    if (list) list.innerHTML = markup;
    if (mirror) mirror.innerHTML = markup;
  } catch (err) {
    const markup = `<p class="muted">${escapeHtml(err.message)}</p>`;
    if (list) list.innerHTML = markup;
    if (mirror) mirror.innerHTML = markup;
  }
  renderPageSidebar();
  if (list) enhanceMotion(list);
  if (mirror) enhanceMotion(mirror);
}

async function toggleFollowUser(userId, following = null) {
  if (!currentUser) return $("auth-dialog").showModal();
  const button = document.querySelector(`[data-follow-user="${userId}"]`);
  const next = following ?? !(button?.textContent || "").toLowerCase().includes("unfollow");
  await apiFetch(`/api/users/${userId}/follow`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ following: next }),
  });
  if (activeProfileUsername) await openProfile(activeProfileUsername);
  else if (currentPage === "friends") await loadFriendPanel();
  else await searchUsers();
}

async function sendFriendRequest(userId) {
  if (!currentUser) return $("auth-dialog").showModal();
  const data = await apiFetch(`/api/users/${userId}/friend-request`, { method: "POST" });
  const status = data.status || "pending_out";
  document.querySelectorAll(`[data-friend-user="${userId}"]`).forEach((button) => {
    button.textContent = friendButtonLabel(status);
    button.disabled = ["friends", "pending_out"].includes(status);
  });
  if (activeProfileUsername) await openProfile(activeProfileUsername);
  else if (currentPage === "friends") await loadFriendPanel();
}

async function openProfile(username) {
  if (!username) return;
  const previousUsername = activeProfileUsername;
  const previousData = profilePageData;
  activeProfileUsername = username;
  try {
    const data = await apiFetch(`/api/users/${encodeURIComponent(username)}/profile`);
    profilePageData = data;
    renderProfile(data);
    routeTo(`/users/${encodeURIComponent(username)}`);
    setCurrentPage("profile", { updateRoute: false });
  } catch (err) {
    activeProfileUsername = previousUsername;
    profilePageData = previousData;
    if (location.hash === `#user/${encodeURIComponent(username)}` || location.pathname === `/users/${encodeURIComponent(username)}`) {
      routeTo(routeForPage(currentPage === "profile" ? "discover" : currentPage), { replace: true });
    }
    showToast(err.message || "Profile unavailable.", "error");
    return null;
  }
}

function profileCustomizationMarkup(user) {
  if (!currentUser || currentUser.username !== user.username) return "";
  const prefs = { ...DEFAULT_USER_SETTINGS, ...(currentUser.user_settings || {}), ...(user.user_settings || {}) };
  return `
    <section class="profile-section-card profile-customize-panel">
      <header>
        <div>
          <h3>Profile Customization</h3>
          <p class="muted">Tune how your public profile page looks without leaving the profile tab.</p>
        </div>
        <div class="card-actions">
          <button type="button" data-profile-customize-toggle="1">${profileCustomizeOpen ? "Hide Controls" : "Customize Profile"}</button>
          <button type="button" data-open-settings="1">Account Settings</button>
        </div>
      </header>
      ${profileCustomizeOpen ? `
        <div class="form-grid">
          <label class="field">
            <span>Profile layout</span>
            <select id="profile-page-layout">
              <option value="spotlight" ${prefs.profile_layout === "spotlight" ? "selected" : ""}>Spotlight</option>
              <option value="magazine" ${prefs.profile_layout === "magazine" ? "selected" : ""}>Magazine</option>
              <option value="stack" ${prefs.profile_layout === "stack" ? "selected" : ""}>Stacked</option>
              <option value="split" ${prefs.profile_layout === "split" ? "selected" : ""}>Split Screen</option>
              <option value="mosaic" ${prefs.profile_layout === "mosaic" ? "selected" : ""}>Mosaic</option>
              <option value="timeline" ${prefs.profile_layout === "timeline" ? "selected" : ""}>Timeline</option>
            </select>
          </label>
          <label class="field">
            <span>Header alignment</span>
            <select id="profile-page-hero-alignment">
              <option value="split" ${prefs.profile_hero_alignment === "split" ? "selected" : ""}>Split</option>
              <option value="start" ${prefs.profile_hero_alignment === "start" ? "selected" : ""}>Left aligned</option>
              <option value="center" ${prefs.profile_hero_alignment === "center" ? "selected" : ""}>Centered</option>
            </select>
          </label>
          <label class="field">
            <span>Content focus</span>
            <select id="profile-page-content-focus">
              <option value="balanced" ${prefs.profile_content_focus === "balanced" ? "selected" : ""}>Balanced</option>
              <option value="gallery" ${prefs.profile_content_focus === "gallery" ? "selected" : ""}>Gallery first</option>
              <option value="collections" ${prefs.profile_content_focus === "collections" ? "selected" : ""}>Collections first</option>
              <option value="social" ${prefs.profile_content_focus === "social" ? "selected" : ""}>Social first</option>
            </select>
          </label>
          <label class="field">
            <span>Profile banner</span>
            <select id="profile-page-banner-style">
              <option value="gradient" ${prefs.profile_banner_style === "gradient" ? "selected" : ""}>Gradient</option>
              <option value="mesh" ${prefs.profile_banner_style === "mesh" ? "selected" : ""}>Mesh</option>
              <option value="frame" ${prefs.profile_banner_style === "frame" ? "selected" : ""}>Framed</option>
              <option value="aurora" ${prefs.profile_banner_style === "aurora" ? "selected" : ""}>Aurora</option>
              <option value="spotlight" ${prefs.profile_banner_style === "spotlight" ? "selected" : ""}>Spotlight</option>
              <option value="poster" ${prefs.profile_banner_style === "poster" ? "selected" : ""}>Poster</option>
            </select>
          </label>
          <label class="field">
            <span>Profile cards</span>
            <select id="profile-page-card-style">
              <option value="glass" ${prefs.profile_card_style === "glass" ? "selected" : ""}>Glass</option>
              <option value="solid" ${prefs.profile_card_style === "solid" ? "selected" : ""}>Solid</option>
              <option value="outline" ${prefs.profile_card_style === "outline" ? "selected" : ""}>Outline</option>
              <option value="elevated" ${prefs.profile_card_style === "elevated" ? "selected" : ""}>Elevated</option>
              <option value="soft" ${prefs.profile_card_style === "soft" ? "selected" : ""}>Soft</option>
              <option value="edge" ${prefs.profile_card_style === "edge" ? "selected" : ""}>Edge accent</option>
            </select>
          </label>
          <label class="field">
            <span>Stat style</span>
            <select id="profile-page-stat-style">
              <option value="tiles" ${prefs.profile_stat_style === "tiles" ? "selected" : ""}>Tiles</option>
              <option value="ribbon" ${prefs.profile_stat_style === "ribbon" ? "selected" : ""}>Ribbon</option>
              <option value="minimal" ${prefs.profile_stat_style === "minimal" ? "selected" : ""}>Minimal</option>
            </select>
          </label>
          <label class="check-card">
            <input id="profile-page-show-joined-date" type="checkbox" ${prefs.profile_show_joined_date !== false ? "checked" : ""} />
            <span>Show joined date on the profile page</span>
          </label>
          <label class="check-card">
            <input id="profile-page-show-follow-counts" type="checkbox" ${prefs.profile_show_follow_counts !== false ? "checked" : ""} />
            <span>Show follow and friend counts</span>
          </label>
          <label class="check-card">
            <input id="profile-page-show-uploads" type="checkbox" ${prefs.profile_show_uploads !== false ? "checked" : ""} />
            <span>Show uploads section</span>
          </label>
          <label class="check-card">
            <input id="profile-page-show-collections" type="checkbox" ${prefs.profile_show_collections !== false ? "checked" : ""} />
            <span>Show collections section</span>
          </label>
          <label class="check-card">
            <input id="profile-page-show-friends" type="checkbox" ${prefs.profile_show_friends !== false ? "checked" : ""} />
            <span>Show friends section</span>
          </label>
        </div>
        <div class="modal-actions">
          <button type="button" class="primary" data-profile-customize-save="1">Save Profile Style</button>
          <span id="profile-customize-status" class="muted"></span>
        </div>
      ` : ""}
    </section>
  `;
}

function renderProfile(data) {
  const user = data.user || {};
  const prefs = { ...DEFAULT_USER_SETTINGS, ...(user.user_settings || {}) };
  const profileAccent = safeHexColor(user.profile_color, "#37c9a7");
  const avatarUrl = avatarUrlForRecord(user);
  const websiteUrl = normalizedPublicUrl(user.website_url);
  const safeLayout = safeClassToken(prefs.profile_layout, "spotlight");
  const safeCardStyle = safeClassToken(prefs.profile_card_style, "glass");
  const safeBannerStyle = safeClassToken(prefs.profile_banner_style, "gradient");
  const safeHeroAlign = safeClassToken(prefs.profile_hero_alignment, "split");
  const safeStatStyle = safeClassToken(prefs.profile_stat_style, "tiles");
  const safeContentFocus = safeClassToken(prefs.profile_content_focus, "balanced");
  const visibility = {
    showJoinedDate: prefs.profile_show_joined_date !== false,
    showUploads: prefs.profile_show_uploads !== false,
    showCollections: prefs.profile_show_collections !== false,
    showFriends: prefs.profile_show_friends !== false,
    showFollowCounts: prefs.profile_show_follow_counts !== false,
    showLikeStats: user.show_liked_count !== false,
  };
  const joined = user.created_at ? new Date(user.created_at).toLocaleDateString() : "";
  $("profile-dialog-title").textContent = user.display_name || user.username || "Profile";
  const tags = (user.featured_tags || []).map((tag) => `<span>${escapeHtml(tag)}</span>`).join("");
  const media = data.media || [];
  const collections = data.collections || [];
  const friends = data.friends || [];
  const compactStats = [
    { label: "Posts", value: Number(user.media_count || 0) },
    visibility.showFollowCounts ? { label: "Followers", value: Number(user.follower_count || 0) } : null,
    visibility.showFollowCounts ? { label: "Following", value: Number(user.following_count || 0) } : null,
    visibility.showFriends ? { label: "Friends", value: Number(user.friend_count || 0) } : null,
    { label: "Downloads", value: Number(user.download_count || 0) },
    visibility.showLikeStats ? { label: "Likes", value: Number(user.like_count || 0) } : null,
  ].filter(Boolean);
  const statCards = [
    { label: "Posts", value: Number(user.media_count || 0), note: "Published uploads" },
    visibility.showFollowCounts ? { label: "Followers", value: Number(user.follower_count || 0), note: "People following this profile" } : null,
    visibility.showFollowCounts ? { label: "Following", value: Number(user.following_count || 0), note: "Creators this profile follows" } : null,
    visibility.showFriends ? { label: "Friends", value: Number(user.friend_count || 0), note: "Accepted mutuals" } : null,
    { label: "Downloads", value: Number(user.download_count || 0), note: "Downloads on public posts" },
    visibility.showLikeStats ? { label: "Likes", value: Number(user.like_count || 0), note: "Total likes across public work" } : null,
  ].filter(Boolean);
  const heroRibbonItems = [
    tags || "",
    user.website_url ? "<span>Website linked</span>" : "",
    user.public_profile === false ? "<span>Private profile</span>" : "",
    prefs.profile_content_focus === "collections" ? "<span>Collections-forward layout</span>" : "",
    prefs.profile_content_focus === "social" ? "<span>Social-forward layout</span>" : "",
  ].filter(Boolean);
  const heroRibbonMarkup = heroRibbonItems.length ? `<div class="profile-ribbon">${heroRibbonItems.join("")}</div>` : "";
  const compactMarkup = `
    <section class="profile-hero" style="--profile-accent:${profileAccent}">
      <div class="avatar large">${avatarUrl ? `<img src="${escapeHtml(avatarUrl)}" alt="">` : escapeHtml((user.display_name || user.username || "IG").slice(0, 2).toUpperCase())}</div>
      <div>
        <h2>${escapeHtml(user.display_name || user.username)}</h2>
        <p class="muted">@${escapeHtml(user.username || "")}${user.location_label ? ` · ${escapeHtml(user.location_label)}` : ""}</p>
        ${user.profile_headline ? `<p class="profile-headline">${escapeHtml(user.profile_headline)}</p>` : ""}
        ${user.bio ? `<p>${escapeHtml(user.bio)}</p>` : ""}
        ${tags ? `<div class="tag-row">${tags}</div>` : ""}
      </div>
      <div class="profile-actions">
        <button type="button" data-follow-user="${user.id}">${user.followed_by_me ? "Unfollow" : "Follow"}</button>
        <button type="button" data-friend-user="${user.id}" ${["self", "friends", "pending_out"].includes(user.friend_status) ? "disabled" : ""}>${friendButtonLabel(user.friend_status)}</button>
        <button type="button" data-copy-profile="${escapeHtml(user.username || "")}">Copy Link</button>
        ${websiteUrl ? `<a class="button-link" href="${escapeHtml(websiteUrl)}" target="_blank" rel="noopener">Website</a>` : ""}
      </div>
    </section>
    <section class="profile-stats">
      ${compactStats.map((item) => `<div><strong>${item.value}</strong><span>${item.label}</span></div>`).join("")}
    </section>
  `;
  const uploadsSection = visibility.showUploads ? `
    <section class="profile-section-card">
      <header><h3>Recent Uploads</h3><span class="muted">${media.length}</span></header>
      <div class="mini-media-grid">${media.length ? media.map((item) => `
        <button class="mini-media" type="button" data-open="${item.id}">
          ${renderPreview(item, "mini")}
          <span>${adultBadge(item)}${escapeHtml(item.title)}</span>
        </button>
      `).join("") : `<p class="muted">No public uploads to show.</p>`}</div>
    </section>
  ` : "";
  const collectionsSection = visibility.showCollections ? `
    <section class="profile-section-card">
      <header><h3>Collections</h3><span class="muted">${collections.length}</span></header>
      <div class="profile-collection-grid">${collections.length ? collections.map((collection) => collectionCardMarkup(collection)).join("") : `<p class="muted">No public collections to show.</p>`}</div>
    </section>
  ` : "";
  const friendsSection = visibility.showFriends ? `
    <section class="profile-section-card">
      <header><h3>Friends</h3><span class="muted">${friends.length}</span></header>
      <div class="profile-friend-grid">${friends.length ? friends.map((friend) => userCard(friend, { compact: true })).join("") : `<p class="muted">No friends to show.</p>`}</div>
    </section>
  ` : "";
  const detailsBadges = [
    visibility.showFollowCounts ? `<span>${Number(user.following_count || 0)} following</span>` : "",
    visibility.showFollowCounts ? `<span>${Number(user.follower_count || 0)} followers</span>` : "",
    visibility.showFriends ? `<span>${Number(user.friend_count || 0)} friends</span>` : "",
    user.location_label ? `<span>${escapeHtml(user.location_label)}</span>` : "",
  ].filter(Boolean);
  const detailsSection = `
    <section class="profile-section-card">
      <header><h3>Profile Details</h3></header>
      <div class="profile-ribbon">
        ${detailsBadges.length ? detailsBadges.join("") : "<span>Keeping things low-key for now.</span>"}
      </div>
    </section>
  `;
  let mainSections = [];
  let railSections = [];
  switch (prefs.profile_content_focus || "balanced") {
    case "collections":
      if (collectionsSection) mainSections.push(collectionsSection);
      if (uploadsSection) mainSections.push(uploadsSection);
      if (friendsSection) railSections.push(friendsSection);
      railSections.push(detailsSection);
      break;
    case "social":
      if (friendsSection) mainSections.push(friendsSection);
      if (uploadsSection) mainSections.push(uploadsSection);
      if (collectionsSection) railSections.push(collectionsSection);
      railSections.push(detailsSection);
      break;
    case "gallery":
      if (uploadsSection) mainSections.push(uploadsSection);
      if (collectionsSection) mainSections.push(collectionsSection);
      railSections.push(detailsSection);
      if (friendsSection) railSections.push(friendsSection);
      break;
    default:
      if (uploadsSection) mainSections.push(uploadsSection);
      if (collectionsSection) mainSections.push(collectionsSection);
      if (friendsSection) railSections.push(friendsSection);
      railSections.push(detailsSection);
      break;
  }
  if (!mainSections.length) {
    mainSections = [`<section class="profile-section-card"><p class="muted">This profile is keeping its showcase sections hidden for now.</p></section>`];
  }
  const expandedMarkup = `
    <div class="profile-showcase profile-layout-${safeLayout} profile-card-style-${safeCardStyle}" data-banner-style="${safeBannerStyle}" data-hero-align="${safeHeroAlign}" style="--profile-accent:${profileAccent}">
      <div class="profile-showcase-top">
        <div class="avatar large">${avatarUrl ? `<img src="${escapeHtml(avatarUrl)}" alt="">` : escapeHtml((user.display_name || user.username || "IG").slice(0, 2).toUpperCase())}</div>
        <div class="profile-showcase-copy">
          <p class="page-eyebrow">Profile</p>
          <h2>${escapeHtml(user.display_name || user.username)}</h2>
          <p class="muted">@${escapeHtml(user.username || "")}${user.location_label ? ` · ${escapeHtml(user.location_label)}` : ""}${visibility.showJoinedDate && joined ? ` · Joined ${escapeHtml(joined)}` : ""}</p>
          ${user.profile_headline ? `<p class="profile-headline">${escapeHtml(user.profile_headline)}</p>` : ""}
          ${user.bio ? `<p>${escapeHtml(user.bio)}</p>` : ""}
          ${heroRibbonMarkup}
        </div>
        <div class="profile-actions">
          <button type="button" data-follow-user="${user.id}">${user.followed_by_me ? "Unfollow" : "Follow"}</button>
          <button type="button" data-friend-user="${user.id}" ${["self", "friends", "pending_out"].includes(user.friend_status) ? "disabled" : ""}>${friendButtonLabel(user.friend_status)}</button>
          <button type="button" data-copy-profile="${escapeHtml(user.username || "")}">Copy Link</button>
          ${websiteUrl ? `<a class="button-link" href="${escapeHtml(websiteUrl)}" target="_blank" rel="noopener">Website</a>` : ""}
          ${currentUser?.username === user.username ? `<button type="button" data-profile-customize-toggle="1">${profileCustomizeOpen ? "Hide Controls" : "Customize Profile"}</button>` : ""}
        </div>
      </div>
      <div class="profile-spotlight-grid" data-stat-style="${safeStatStyle}">
        ${statCards.map((item) => `
          <article class="profile-insight-card">
            <h3>${item.label}</h3>
            <strong>${item.value}</strong>
            <span class="muted">${item.note}</span>
          </article>
        `).join("")}
      </div>
      ${profileCustomizationMarkup(user)}
    </div>
    <div class="profile-dashboard profile-layout-${safeLayout} profile-card-style-${safeCardStyle} profile-focus-${safeContentFocus}">
      <div class="profile-column">
        ${mainSections.join("")}
      </div>
      <aside class="profile-rail">
        ${railSections.join("")}
      </aside>
    </div>
  `;
  if (safeEl("profile-view")) $("profile-view").innerHTML = compactMarkup;
  if (safeEl("profile-page-view")) $("profile-page-view").innerHTML = expandedMarkup;
  renderPageSidebar();
  enhanceMotion(safeEl("profile-view"));
  enhanceMotion(safeEl("profile-page-view"));
}

async function openFriendsPage() {
  setCurrentPage("friends");
  if (!currentUser) {
    if (safeEl("friends-page-requests")) $("friends-page-requests").innerHTML = `<p class="muted">Sign in to manage incoming friend requests.</p>`;
    if (safeEl("friends-page-outgoing")) $("friends-page-outgoing").innerHTML = `<p class="muted">Outgoing invites appear here after you sign in.</p>`;
    if (safeEl("friends-page-list")) $("friends-page-list").innerHTML = `<p class="muted">Your accepted friends list will appear here.</p>`;
    renderPageSidebar();
    return $("auth-dialog").showModal();
  }
  await loadFriendPanel();
}

async function loadFriendPanel() {
  const requests = await apiFetch("/api/friends/requests");
  const friends = await apiFetch("/api/me/friends");
  const incoming = requests.incoming || [];
  const outgoing = requests.outgoing || [];
  friendPanelState = { incoming, outgoing, friends: friends.friends || [] };
  $("friend-requests-list").innerHTML = `
    ${incoming.length ? `<h3>Incoming</h3>${incoming.map((item) => `
      <article class="user-card">
        ${userCard(item.user, { compact: true })}
        <div class="user-card-actions">
          <button type="button" data-friend-action="accept" data-request-id="${item.id}">Accept</button>
          <button type="button" data-friend-action="decline" data-request-id="${item.id}">Decline</button>
        </div>
      </article>
    `).join("")}` : `<p class="muted">No incoming friend requests.</p>`}
    ${outgoing.length ? `<h3>Outgoing</h3>${outgoing.map((item) => `
      <article class="user-card">
        ${userCard(item.user, { compact: true })}
        <div class="user-card-actions"><button type="button" data-friend-action="cancel" data-request-id="${item.id}">Cancel</button></div>
      </article>
    `).join("")}` : ""}
  `;
  $("friends-list").innerHTML = (friends.friends || []).length ? friends.friends.map((friend) => userCard(friend, { compact: true })).join("") : `<p class="muted">No friends yet.</p>`;
  if (safeEl("friends-page-requests")) $("friends-page-requests").innerHTML = incoming.length ? incoming.map((item) => `
    <article class="user-card">
      ${userCard(item.user, { compact: true })}
      <div class="user-card-actions">
        <button type="button" data-friend-action="accept" data-request-id="${item.id}">Accept</button>
        <button type="button" data-friend-action="decline" data-request-id="${item.id}">Decline</button>
      </div>
    </article>
  `).join("") : `<p class="muted">No incoming friend requests.</p>`;
  if (safeEl("friends-page-outgoing")) $("friends-page-outgoing").innerHTML = outgoing.length ? outgoing.map((item) => `
    <article class="user-card">
      ${userCard(item.user, { compact: true })}
      <div class="user-card-actions"><button type="button" data-friend-action="cancel" data-request-id="${item.id}">Cancel</button></div>
    </article>
  `).join("") : `<p class="muted">No outgoing friend requests.</p>`;
  if (safeEl("friends-page-list")) $("friends-page-list").innerHTML = (friends.friends || []).length ? friends.friends.map((friend) => userCard(friend, { compact: true })).join("") : `<p class="muted">No friends yet.</p>`;
  setTextIfPresent("friends-page-request-count", incoming.length);
  setTextIfPresent("friends-page-outgoing-count", outgoing.length);
  setTextIfPresent("friends-page-list-count", (friends.friends || []).length);
  renderPageSidebar();
  enhanceMotion(safeEl("friends-dialog"));
  enhanceMotion(safeEl("friends-page"));
}

async function respondFriendRequest(requestId, action) {
  await apiFetch(`/api/friends/requests/${requestId}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action }),
  });
  await loadFriendPanel();
}

async function copyProfileLink(username) {
  const url = `${location.origin}${location.pathname}#user/${encodeURIComponent(username)}`;
  try {
    await navigator.clipboard.writeText(url);
  } catch (_err) {
    const temp = document.createElement("input");
    temp.value = url;
    document.body.appendChild(temp);
    temp.select();
    document.execCommand("copy");
    temp.remove();
  }
}

async function deleteOwnMedia(id) {
  if (!confirm("Archive this post? It will disappear from the gallery but can be restored from Studio.")) return;
  await apiFetch(`/api/media/${id}`, { method: "DELETE" });
  await openStudio();
  await refreshAll();
}

function openReport(mediaId) {
  if (!currentUser) return $("auth-dialog").showModal();
  selectedReportMediaId = mediaId;
  setNotice("report-error", "");
  $("report-dialog").showModal();
}

async function submitReport(event) {
  event.preventDefault();
  if (!selectedReportMediaId) return;
  try {
    await apiFetch(`/api/media/${selectedReportMediaId}/report`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        reason: $("report-reason").value,
        details: $("report-details").value,
      }),
    });
    setNotice("report-error", "Report sent.", "success");
    $("report-dialog").close();
  } catch (err) {
    setNotice("report-error", err.message);
  }
}

function previewSelectedAvatar() {
  const input = safeEl("settings-avatar-file");
  const preview = safeEl("settings-avatar-preview");
  if (!input || !preview) return;
  if (preview.dataset.objectUrl) {
    URL.revokeObjectURL(preview.dataset.objectUrl);
    delete preview.dataset.objectUrl;
  }
  const file = input.files?.[0];
  if (!file) {
    if (currentUser) renderAvatar("settings-avatar-preview", currentUser);
    return;
  }
  const objectUrl = URL.createObjectURL(file);
  preview.innerHTML = `<img src="${objectUrl}" alt="">`;
  preview.dataset.objectUrl = objectUrl;
  preview.style.borderColor = safeHexColor(currentUser?.profile_color, safeHexColor(userSettings().accent_color, "#37c9a7"));
}

async function saveProfileCustomization() {
  if (!currentUser) return safeEl("auth-dialog")?.showModal();
  let status = safeEl("profile-customize-status");
  if (status) status.textContent = "Saving profile style...";
  try {
    const data = await apiFetch("/api/me/settings", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        profile_layout: safeEl("profile-page-layout")?.value || "spotlight",
        profile_banner_style: safeEl("profile-page-banner-style")?.value || "gradient",
        profile_card_style: safeEl("profile-page-card-style")?.value || "glass",
        profile_stat_style: safeEl("profile-page-stat-style")?.value || "tiles",
        profile_content_focus: safeEl("profile-page-content-focus")?.value || "balanced",
        profile_hero_alignment: safeEl("profile-page-hero-alignment")?.value || "split",
        profile_show_joined_date: Boolean(safeEl("profile-page-show-joined-date")?.checked),
        profile_show_uploads: Boolean(safeEl("profile-page-show-uploads")?.checked),
        profile_show_collections: Boolean(safeEl("profile-page-show-collections")?.checked),
        profile_show_friends: Boolean(safeEl("profile-page-show-friends")?.checked),
        profile_show_follow_counts: Boolean(safeEl("profile-page-show-follow-counts")?.checked),
      }),
    });
    currentUser = data.user || currentUser;
    writeStore(USER_KEY, JSON.stringify(currentUser));
    if (profilePageData?.user) {
      profilePageData = { ...profilePageData, user: { ...profilePageData.user, ...currentUser } };
    }
    renderAuth();
    renderProfile(profilePageData || { user: currentUser, media: [], collections: [], friends: [] });
    status = safeEl("profile-customize-status");
    if (status) status.textContent = "Profile style saved.";
  } catch (err) {
    if (status) status.textContent = err.message;
  }
}

async function saveAvatar() {
  if (!currentUser) return;
  const fileInput = safeEl("settings-avatar-file");
  const file = fileInput?.files?.[0];
  if (!file) return setNotice("settings-error", "Choose an image first.");
  if (file.size > 5 * 1024 * 1024) return setNotice("settings-error", "Profile pictures must be 5MB or smaller.");
  const body = new FormData();
  body.set("file", file);
  const saveButton = safeEl("avatar-save");
  try {
    if (saveButton) {
      saveButton.disabled = true;
      saveButton.textContent = "Saving...";
    }
    setNotice("settings-error", "Saving profile picture...", "success");
    const data = await apiUpload("/api/me/avatar", body);
    currentUser = data.user;
    writeStore(USER_KEY, JSON.stringify(currentUser));
    renderAuth();
    fillSettingsForm();
    if (profilePageData?.user && currentUser?.username === profilePageData.user.username) {
      profilePageData = { ...profilePageData, user: { ...profilePageData.user, ...currentUser } };
      renderProfile(profilePageData);
    }
    setNotice("settings-error", "Profile picture saved.", "success");
    if (fileInput) fileInput.value = "";
  } catch (err) {
    setNotice("settings-error", err.message);
  } finally {
    if (saveButton) {
      saveButton.disabled = false;
      saveButton.textContent = "Save Picture";
    }
  }
}

function ensureUploadControlFields() {
  const form = $("upload-form");
  if (!form || $("upload-visibility")) return;
  const submit = form.querySelector('button[type="submit"], .primary');
  const wrapper = document.createElement("div");
  wrapper.className = "upload-controls-grid";
  wrapper.innerHTML = `
    <label class="field">Visibility
      <select id="upload-visibility">
        <option value="public">Public - appears in the gallery</option>
        <option value="unlisted">Unlisted - link/profile only</option>
        <option value="private">Private - only me</option>
      </select>
    </label>
    <label class="check-row"><input id="upload-comments-enabled" type="checkbox" checked> Allow comments</label>
    <label class="check-row"><input id="upload-downloads-enabled" type="checkbox" checked> Allow downloads</label>
    <label class="check-row"><input id="upload-pinned" type="checkbox"> Pin in my studio/feed</label>
  `;
  if (submit) form.insertBefore(wrapper, submit);
  else form.appendChild(wrapper);
}

function closeUploadDialog({ force = false } = {}) {
  if (uploadInFlight && !force) return;
  setNotice("upload-error", "");
  const form = safeEl("upload-form");
  if (form) form.reset();
  uploadAiBusy = false;
  uploadAiAnalysis = null;
  setTextIfPresent("file-label", "Choose images, GIFs, or videos under 500MB each");
  setTextIfPresent("upload-ai-status", "Select a file to auto-analyze with the local vision model before upload. Multi-file uploads still get analyzed again during save.");
  showIfPresent("upload-ai-preview", false);
  if (safeEl("upload-ai-preview")) $("upload-ai-preview").innerHTML = "";
  setDisabledIfPresent("upload-analyze", false);
  renderUploadQueue();
  resetUploadProgress();
  const dialog = safeEl("upload-dialog");
  if (dialog?.open) dialog.close();
  if (location.pathname === "/upload") routeTo(routeForPage(currentPage || "discover"));
  checkUploadReadiness();
}

function setUploadProgress(percent, label = "Uploading", options = {}) {
  showIfPresent("upload-progress-wrap", true);
  const wrap = safeEl("upload-progress-wrap");
  const bar = safeEl("upload-progress-bar");
  const pct = Math.max(0, Math.min(100, Number(percent || 0)));
  if (wrap) wrap.classList.toggle("is-processing", Boolean(options.processing));
  if (bar) bar.style.width = `${pct}%`;
  setTextIfPresent("upload-progress-percent", `${Math.round(pct)}%`);
  setTextIfPresent("upload-progress-label", label);
}

function resetUploadProgress() {
  showIfPresent("upload-progress-wrap", false);
  const wrap = safeEl("upload-progress-wrap");
  const bar = safeEl("upload-progress-bar");
  if (wrap) wrap.classList.remove("is-processing");
  if (bar) bar.style.width = "0%";
  setTextIfPresent("upload-progress-percent", "0%");
  setTextIfPresent("upload-progress-label", "Preparing upload");
  const button = safeEl("upload-submit");
  if (button) {
    button.classList.remove("is-uploading");
    button.disabled = false;
    button.textContent = "Post";
  }
}

function titleFromFilename(filename) {
  return String(filename || "upload")
    .replace(/\.[^.]+$/, "")
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\b\w/g, (char) => char.toUpperCase())
    .slice(0, 160);
}

function renderUploadAiPreview(analysis) {
  const preview = safeEl("upload-ai-preview");
  if (!preview || !analysis) return showIfPresent("upload-ai-preview", false);
  preview.hidden = false;
  preview.innerHTML = `
    <div>
      <strong>${escapeHtml(analysis.title || "Untitled suggestion")}</strong>
      <span>${escapeHtml(categoryDisplayName(analysis.category_name, analysis.subcategory_name))}</span>
    </div>
    <div>
      <strong>${escapeHtml(analysis.suggested_filename || "No rename")}</strong>
      <span>${escapeHtml((analysis.tags || []).join(", ") || "No tags suggested")}</span>
    </div>
    <div>
      <strong>${escapeHtml((analysis.source || "heuristic").toUpperCase())}</strong>
      <span>${escapeHtml(`Confidence ${Math.round(Number(analysis.confidence || 0) * 100)}%${analysis.is_adult ? " · 18+" : ""}`)}</span>
    </div>
  `;
  enhanceMotion(preview);
}

function applyUploadAnalysis(analysis) {
  if (!analysis) return;
  const files = Array.from(safeEl("upload-file")?.files || []);
  const singleFile = files.length === 1;
  if (singleFile && safeEl("upload-title")) $("upload-title").value = analysis.title || $("upload-title").value;
  if (safeEl("upload-tags")) $("upload-tags").value = (analysis.tags || []).join(", ");
  if (analysis.is_adult && safeEl("upload-adult")) $("upload-adult").checked = true;
  const category = categoryByName(analysis.category_name);
  if (category) {
    if (safeEl("upload-category")) $("upload-category").value = String(category.id);
    toggleNewCategory();
    const subcategory = subcategoryByName(category.id, analysis.subcategory_name);
    if (subcategory && safeEl("upload-subcategory")) {
      $("upload-subcategory").value = String(subcategory.id);
      if (safeEl("new-subcategory-name")) $("new-subcategory-name").value = "";
    } else if (analysis.subcategory_name && safeEl("upload-subcategory")) {
      $("upload-subcategory").value = "__new__";
      if (safeEl("new-subcategory-name")) $("new-subcategory-name").value = analysis.subcategory_name;
    } else {
      if (safeEl("upload-subcategory")) $("upload-subcategory").value = "";
      if (safeEl("new-subcategory-name")) $("new-subcategory-name").value = "";
    }
    toggleNewCategory();
  } else {
    if (safeEl("upload-category")) $("upload-category").value = "";
    toggleNewCategory();
    if (safeEl("new-category-name")) $("new-category-name").value = analysis.category_name || "";
    if (safeEl("new-category-kind")) $("new-category-kind").value = analysis.media_kind === "video" ? "video" : "image";
    if (safeEl("new-subcategory-name")) $("new-subcategory-name").value = analysis.subcategory_name || "";
  }
  renderUploadAiPreview(analysis);
  setTextIfPresent(
    "upload-ai-status",
    `${analysisSourceLabel(analysis.source)} suggested ${categoryDisplayName(analysis.category_name, analysis.subcategory_name)} and ${Math.max(0, (analysis.tags || []).length)} tag${(analysis.tags || []).length === 1 ? "" : "s"}.`,
  );
  checkUploadReadiness();
}

async function analyzeUploadSelection({ apply = true, silent = false } = {}) {
  if (uploadAiBusy) return;
  const files = Array.from(safeEl("upload-file")?.files || []);
  if (!files.length) {
    if (!silent) setTextIfPresent("upload-ai-status", "Choose a file first.");
    return;
  }
  const file = files[0];
  const body = new FormData();
  body.set("file", file);
  body.set("title", safeEl("upload-title")?.value || "");
  body.set("description", safeEl("upload-description")?.value || "");
  body.set("tags", safeEl("upload-tags")?.value || "");
  uploadAiBusy = true;
  setDisabledIfPresent("upload-analyze", true);
  setTextIfPresent("upload-ai-status", `Analyzing ${file.name}...`);
  try {
    const data = await apiUpload("/api/media/analyze", body);
    uploadAiAnalysis = {
      ...(data.analysis || {}),
      media_kind: data.media_kind,
      mime_type: data.mime_type,
      original_filename: data.original_filename,
    };
    if (apply) applyUploadAnalysis(uploadAiAnalysis);
    else renderUploadAiPreview(uploadAiAnalysis);
    if (!apply) {
      setTextIfPresent(
        "upload-ai-status",
        `${analysisSourceLabel(uploadAiAnalysis.source)} preview ready for ${file.name}.`,
      );
    }
  } catch (err) {
    uploadAiAnalysis = null;
    showIfPresent("upload-ai-preview", false);
    setTextIfPresent("upload-ai-status", err.message || "AI analysis failed.");
    if (!silent) showToast(err.message || "AI analysis failed.", "error");
  } finally {
    uploadAiBusy = false;
    setDisabledIfPresent("upload-analyze", false);
    checkUploadReadiness();
  }
}

function updateUploadFileSummary() {
  const files = Array.from(safeEl("upload-file")?.files || []);
  const file = files[0];
  const totalBytes = files.reduce((sum, entry) => sum + Number(entry.size || 0), 0);
  setTextIfPresent("file-label", files.length ? `${files.length} file${files.length === 1 ? "" : "s"} selected - ${formatBytes(totalBytes)}` : "Choose images, GIFs, or videos under 500MB each");
  setTextIfPresent("upload-file-summary", files.length ? `${files.length} queued · ${formatBytes(totalBytes)} total` : "No file selected.");
  const title = safeEl("upload-title");
  if (file && title && !title.value.trim()) title.value = titleFromFilename(file.name);
  if (!files.length) {
    uploadAiAnalysis = null;
    showIfPresent("upload-ai-preview", false);
    setTextIfPresent("upload-ai-status", "Select a file to auto-analyze with the local vision model before upload. Multi-file uploads still get analyzed again during save.");
  } else if (safeEl("upload-auto-ai")?.checked) {
    analyzeUploadSelection({ apply: true, silent: true });
  } else {
    setTextIfPresent("upload-ai-status", "AI suggestions are off for now. You can still analyze the first file manually.");
  }
  renderUploadQueue();
  checkUploadReadiness();
}

function renderUploadQueue(activeIndex = -1, statuses = []) {
  const queue = safeEl("upload-queue");
  if (!queue) return;
  const files = Array.from(safeEl("upload-file")?.files || []);
  queue.hidden = files.length === 0;
  queue.innerHTML = files.map((file, index) => {
    const status = statuses[index] || (index === activeIndex ? "Uploading" : "Queued");
    return `
      <div class="upload-queue-item${index === activeIndex ? " is-active" : ""}">
        <strong>${escapeHtml(titleFromFilename(file.name))}</strong>
        <span>${escapeHtml(file.type || "Unknown type")} · ${formatBytes(file.size)}</span>
        <em>${escapeHtml(status)}</em>
      </div>
    `;
  }).join("");
  enhanceMotion(queue);
}

function openSettingsPanel(options = {}) {
  const { updateRoute = true } = options;
  if (updateRoute) routeTo("/settings");
  if (!currentUser) {
    routeTo("/login");
    return safeEl("auth-dialog")?.showModal();
  }
  fillSettingsForm();
  safeEl("settings-dialog")?.showModal();
}

async function openCurrentUserDestination(target) {
  const destination = target || (currentUser ? ACCOUNT_NAVIGATION.signedInUsernameTarget : ACCOUNT_NAVIGATION.signedOutUsernameTarget);
  if (!currentUser) {
    routeTo("/login");
    return safeEl("auth-dialog")?.showModal();
  }
  if (destination === "settings") return openSettingsPanel();
  return openProfile(currentUser.username);
}

async function submitUpload(event) {
  event.preventDefault();
  if (uploadInFlight) return;
  if (!currentUser) {
    $("upload-dialog").close();
    $("auth-dialog").showModal();
    return;
  }
  setNotice("upload-error", "");
  const files = Array.from($("upload-file").files || []);
  if (!files.length) return setNotice("upload-error", "Choose a file first.");
  const oversized = files.find((file) => file.size > MAX_UPLOAD_BYTES);
  if (oversized) return setNotice("upload-error", `${oversized.name} is over 500MB.`);
  const buildBody = (file, index) => {
    const body = new FormData();
    body.set("file", file);
    body.set("title", files.length === 1 ? $("upload-title").value : titleFromFilename(file.name));
    body.set("description", $("upload-description").value);
    body.set("tags", $("upload-tags").value);
    body.set("auto_ai", safeEl("upload-auto-ai")?.checked ? "true" : "false");
    body.set("is_adult", $("upload-adult").checked ? "true" : "false");
    if ($("upload-visibility")) body.set("visibility", $("upload-visibility").value || "public");
    if ($("upload-comments-enabled")) body.set("comments_enabled", $("upload-comments-enabled").checked ? "true" : "false");
    if ($("upload-downloads-enabled")) body.set("downloads_enabled", $("upload-downloads-enabled").checked ? "true" : "false");
    if ($("upload-pinned")) body.set("pinned", index === 0 && $("upload-pinned").checked ? "true" : "false");
    if ($("upload-category").value) {
      body.set("category_id", $("upload-category").value);
      if (safeEl("upload-subcategory")?.value && $("upload-subcategory").value !== "__new__") body.set("subcategory_id", $("upload-subcategory").value);
      if (safeEl("upload-subcategory")?.value === "__new__" && safeEl("new-subcategory-name")?.value.trim()) body.set("subcategory_name", $("new-subcategory-name").value.trim());
    } else {
      body.set("category_name", $("new-category-name").value);
      body.set("category_kind", $("new-category-kind").value);
      if (safeEl("new-subcategory-name")?.value.trim()) body.set("subcategory_name", $("new-subcategory-name").value.trim());
    }
    return body;
  };
  try {
    uploadInFlight = true;
    uploadStartedAt = Date.now();
    setDisabledIfPresent("upload-submit", true);
    const submit = safeEl("upload-submit");
    if (submit) {
      submit.classList.add("is-uploading");
      submit.textContent = "Uploading...";
    }
    const statuses = files.map(() => "Queued");
    const uploadedIds = [];
    for (const [index, file] of files.entries()) {
      statuses[index] = "Uploading";
      renderUploadQueue(index, statuses);
      setUploadProgress(Math.round((index / files.length) * 100), `Uploading ${index + 1} of ${files.length}: ${file.name}`);
      const uploaded = await apiUpload("/api/media", buildBody(file, index), ({ loaded, total, percent, phase }) => {
        const seconds = Math.max(1, Math.round((Date.now() - uploadStartedAt) / 1000));
        const overall = ((index + ((percent || 0) / 100)) / files.length) * 100;
        if (phase === "processing") {
          setUploadProgress(overall, `Saving ${index + 1} of ${files.length} on the server...`, { processing: true });
          return;
        }
        if (total) {
          setUploadProgress(overall, `${file.name}: ${formatBytes(loaded)} of ${formatBytes(total)} uploaded in ${seconds}s`);
        } else {
          setUploadProgress(overall || 12, `${file.name}: ${formatBytes(loaded)} uploaded. Measuring transfer...`, { processing: true });
        }
      });
      statuses[index] = "Saved";
      uploadedIds.push(uploaded?.media?.id);
      renderUploadQueue(index, statuses);
    }
    setUploadProgress(100, "Saved. Refreshing gallery");
    uploadInFlight = false;
    closeUploadDialog({ force: true });
    focusGalleryOnNewestUploads();
    await refreshAll();
    const firstUploadedId = uploadedIds.find(Boolean);
    if (files.length === 1 && firstUploadedId && confirm("Upload saved. Open it now?")) await openDetail(firstUploadedId);
    else showToast(`${files.length} upload${files.length === 1 ? "" : "s"} saved.`, "success");
  } catch (err) {
    setNotice("upload-error", err.message);
    showToast(err.message || "Upload failed.", "error");
  } finally {
    uploadInFlight = false;
    resetUploadProgress();
    checkUploadReadiness();
  }
}

async function resendEmailVerification() {
  const button = $("resend-email-verification");
  if (!currentUser || button.hidden) return;
  button.disabled = true;
  const originalText = button.textContent;
  button.textContent = "Sending...";
  try {
    const data = await apiFetch("/api/auth/resend-verification", { method: "POST" });
    $("account-bio").textContent = data.email_verification_sent
      ? "Verification code sent. Check your inbox."
      : data.already_verified
        ? "Email already verified."
        : "Verification code could not be sent.";
  } catch (err) {
    $("account-bio").textContent = err.message;
  } finally {
    button.disabled = false;
    button.textContent = originalText;
  }
}


function ensureLiveControlButtons() {
  const refresh = safeEl("refresh");
  const parent = refresh?.parentElement || document.querySelector(".topbar-actions") || document.body;
  const addButton = (id, text, handler) => {
    if (safeEl(id)) return;
    const button = document.createElement("button");
    button.id = id;
    button.type = "button";
    button.textContent = text;
    button.addEventListener("click", handler);
    parent.insertBefore(button, refresh?.nextSibling || null);
  };
  addButton("following-feed", "Following", loadFollowingFeed);
  addButton("liked-feed", "Liked", loadLikedFeed);
  addButton("live-checks-open", "Checks", () => runLiveChecks({ silent: false }));
}

function renderLiveChecks(data, silent = false) {
  const status = safeEl("connection-status");
  const checks = data?.checks || [];
  latestLiveSnapshot = data?.snapshot || latestLiveSnapshot;
  const failing = checks.filter((check) => check.ok === false && check.severity !== "warn");
  const warnings = checks.filter((check) => check.ok === false && check.severity === "warn");
  const activePosts = Number(latestLiveSnapshot?.media_active || 0);
  const label = !navigator.onLine ? "Offline" : failing.length ? "Attention" : warnings.length ? "Warnings" : activePosts ? `Live · ${activePosts}` : "Live";
  if (status) {
    status.textContent = label;
    status.title = checks.map((check) => `${check.label}: ${check.detail}`).join("\n");
    status.dataset.state = failing.length ? "error" : warnings.length ? "warn" : "ok";
    status.hidden = false;
  }
  if (!mediaItems.length && !galleryLoading && activePosts && !galleryFiltersActive()) {
    setTextIfPresent("result-count", `${activePosts} posts live · refresh if they do not appear`);
  }
  const missing = Number(data?.snapshot?.missing_db_files || 0);
  if (!silent && checks.length) {
    let message = checks.map((check) => `${check.ok ? "✓" : check.severity === "warn" ? "!" : "✕"} ${check.label}: ${check.detail}`).join("\n");
    if (missing > 0 && isSiteOwner()) message += `\n\n${missing} legacy file(s) still need migration. Use OK on the next prompt to migrate up to 10 safely.`;
    alert(message);
  }
  return { missing };
}

async function runLiveChecks({ silent = false, force = false } = {}) {
  const now = Date.now();
  if (silent && !force && liveCheckInFlight) return liveCheckInFlight;
  if (silent && !force && now - lastLiveCheckAt < LIVE_CHECK_MIN_GAP_MS) return latestLiveSnapshot;
  if (!navigator.onLine) {
    renderLiveChecks({ checks: [{ label: "Browser network", ok: false, severity: "error", detail: "Your browser reports no internet connection." }] }, silent);
    return;
  }
  liveCheckInFlight = (async () => {
    try {
      lastLiveCheckAt = Date.now();
      const data = await apiFetch("/api/live/checks");
      const rendered = renderLiveChecks(data, silent);
      if (!silent && rendered.missing > 0 && isSiteOwner() && confirm("Run a safe DB file migration batch now? This migrates up to 10 legacy disk files to DB blobs and may take a moment.")) {
        const migrated = await apiFetch("/api/live/migrate", { method: "POST" });
        alert(`Migration batch complete. Migrated: ${migrated.migrated?.migrated || 0}. Missing after batch: ${migrated.snapshot?.missing_db_files || 0}.`);
        return runLiveChecks({ silent: true, force: true });
      }
      return data;
    } catch (err) {
      renderLiveChecks({ checks: [{ label: "Backend", ok: false, severity: "error", detail: err.message }] }, silent);
    } finally {
      liveCheckInFlight = null;
    }
  })();
  return liveCheckInFlight;
}

function startSilentChecks() {
  window.addEventListener("online", () => runLiveChecks({ silent: true }));
  window.addEventListener("offline", () => renderLiveChecks({ checks: [{ label: "Browser network", ok: false, severity: "error", detail: "Offline." }] }, true));
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) runLiveChecks({ silent: true });
  });
  const scheduleLiveCheck = () => {
    window.setTimeout(async () => {
      if (!document.hidden) await runLiveChecks({ silent: true }).catch(() => {});
      scheduleLiveCheck();
    }, isLowPowerMode() ? LOW_POWER_LIVE_CHECK_INTERVAL_MS : LIVE_CHECK_INTERVAL_MS);
  };
  const scheduleSessionRefresh = () => {
    window.setTimeout(async () => {
      if (token && !document.hidden) await refreshMe().catch(() => {});
      scheduleSessionRefresh();
    }, isLowPowerMode() ? 240000 : 120000);
  };
  scheduleLiveCheck();
  scheduleSessionRefresh();
}

function checkUploadReadiness() {
  const files = Array.from(safeEl("upload-file")?.files || []);
  const title = safeEl("upload-title")?.value?.trim();
  let message = "";
  if (files.length) {
    const invalid = files.find((file) => !(/^(image|video)\//.test(file.type || "") || /\.(jpe?g|png|webp|gif|mp4|webm|mov|m4v|ogg)$/i.test(file.name || "")));
    const oversized = files.find((file) => file.size > MAX_UPLOAD_BYTES);
    if (invalid) message = `${invalid.name} may be rejected. Use an image, GIF, or video.`;
    else if (oversized) message = `${oversized.name} is over 500MB and will be rejected.`;
    else if (!title && files.length === 1) message = "Add a title before uploading.";
  }
  setNotice("upload-error", message);
  setDisabledIfPresent("upload-submit", Boolean(message) || uploadInFlight || uploadAiBusy);
}

function showKeyboardShortcuts() {
  alert([
    "Keyboard shortcuts",
    "/ - focus search",
    "U - upload",
    "R - refresh current view",
    "S - share current view",
    "C - open compare board when posts are selected",
    "L - open slideshow for the current page",
    "Arrow Left/Right - previous/next media or page",
    "Escape - close the open dialog",
  ].join("\n"));
}

function closeTopDialog() {
  const dialogs = Array.from(document.querySelectorAll("dialog[open]"));
  const dialog = dialogs.at(-1);
  if (!dialog) return false;
  if (dialog.id === "detail-dialog") closeDetailDialog();
  else if (dialog.id === "slideshow-dialog") closeSlideshow();
  else if (dialog.id === "upload-dialog") closeUploadDialog();
  else dialog.close();
  return true;
}

function bindKeyboardShortcuts() {
  document.addEventListener("keydown", async (event) => {
    const target = event.target;
    const isTyping = ["INPUT", "TEXTAREA", "SELECT"].includes(target?.tagName) || target?.isContentEditable;
    if (event.key === "Escape" && closeTopDialog()) return;
    if (isTyping && event.key !== "Escape") return;
    if (event.key === "/") {
      event.preventDefault();
      safeEl("search")?.focus();
    } else if (event.key.toLowerCase() === "u") {
      event.preventDefault();
      currentUser ? $("upload-dialog").showModal() : $("auth-dialog").showModal();
    } else if (event.key.toLowerCase() === "r") {
      event.preventDefault();
      await refreshAll();
      showToast("Gallery refreshed.", "success");
    } else if (event.key.toLowerCase() === "s") {
      event.preventDefault();
      await shareCurrentView();
    } else if (event.key.toLowerCase() === "c") {
      event.preventDefault();
      openCompareBoard();
    } else if (event.key.toLowerCase() === "l") {
      event.preventDefault();
      openSlideshow();
    } else if (event.key === "ArrowLeft") {
      if (safeEl("slideshow-dialog")?.open) moveSlideshow(-1);
      else if (safeEl("detail-dialog")?.open) await openAdjacentDetail(-1);
      else if (["discover", "following", "liked"].includes(currentPage) && galleryPage > 1) await loadCurrentGalleryPage(galleryPage - 1, { scrollToTop: true });
    } else if (event.key === "ArrowRight") {
      if (safeEl("slideshow-dialog")?.open) moveSlideshow(1);
      else if (safeEl("detail-dialog")?.open) await openAdjacentDetail(1);
      else if (["discover", "following", "liked"].includes(currentPage) && galleryHasNext) await loadCurrentGalleryPage(galleryPage + 1, { scrollToTop: true });
    }
  });
}

function updateBackToTopVisibility() {
  showIfPresent("back-to-top", window.scrollY > 520);
}

function bindEvents() {
  ensureUploadControlFields();
  ensureLiveControlButtons();
  bindKeyboardShortcuts();
  window.addEventListener("scroll", updateBackToTopVisibility, { passive: true });
  on("back-to-top", "click", () => window.scrollTo({ top: 0, behavior: isLowPowerMode() ? "auto" : "smooth" }));
  document.addEventListener("error", (event) => {
    const target = event.target;
    if (target?.tagName === "IMG") {
      target.alt = "Preview unavailable";
      target.closest(".media-preview")?.classList.add("preview-missing");
    }
  }, true);
  $("auth-open").addEventListener("click", () => openCurrentUserDestination());
  if ($("auth-close")) $("auth-close").addEventListener("click", () => {
    $("auth-dialog").close();
    if (location.pathname === "/login") routeTo(routeForPage(currentPage || "discover"));
  });
  $("logout").addEventListener("click", async () => {
    token = "";
    currentUser = null;
    writeStore(TOKEN_KEY, "");
    writeStore(USER_KEY, "");
    renderAuth();
    await refreshAll();
  });
  $("auth-toggle").addEventListener("click", () => setRegisterMode(!registerMode));
  $("auth-form").addEventListener("submit", submitAuth);
  $("resend-email-verification").addEventListener("click", resendEmailVerification);
  on("account-avatar", "click", () => openCurrentUserDestination(ACCOUNT_NAVIGATION.sidebarProfileTarget));
  on("account-name", "click", () => openCurrentUserDestination(ACCOUNT_NAVIGATION.sidebarProfileTarget));
  $("settings-email-save").addEventListener("click", saveEmailAndSendCode);
  $("settings-email-verify").addEventListener("click", verifyEmailCode);
  on("discover-open", "click", openDiscoverPage);
  $("surprise-open").addEventListener("click", openSurprise);
  on("slideshow-open", "click", openSlideshow);
  on("slideshow-close", "click", closeSlideshow);
  on("slideshow-prev", "click", () => moveSlideshow(-1));
  on("slideshow-next", "click", () => moveSlideshow(1));
  on("slideshow-play", "click", toggleSlideshowPlay);
  on("slideshow-delay", "input", () => {
    if (slideshowPlaying) startSlideshow();
  });
  on("slideshow-dialog", "close", () => {
    stopSlideshow();
    slideshowItemsOverride = null;
  });
  on("compare-open", "click", openCompareBoard);
  on("compare-tray-open", "click", openCompareBoard);
  on("compare-clear", "click", clearCompareSelection);
  on("select-page", "click", selectCurrentPage);
  on("selection-slideshow", "click", () => openSlideshow(compareItems()));
  on("selection-like", "click", () => bulkToggleSelection("like", "liked", true, "Selected posts liked."));
  on("selection-save", "click", () => bulkToggleSelection("bookmark", "bookmarked", true, "Selected posts saved."));
  on("selection-collect", "click", openSelectedCollectionPicker);
  on("compare-close", "click", () => safeEl("compare-dialog")?.close());
  on("save-view", "click", saveCurrentView);
  on("saved-views-open", "click", openSavedViewsDialog);
  on("saved-views-close", "click", () => safeEl("saved-views-dialog")?.close());
  on("saved-view-form", "submit", saveCurrentView);
  on("insights-open", "click", openInsights);
  on("insights-close", "click", () => safeEl("insights-dialog")?.close());
  on("detail-zoom-in", "click", () => zoomDetail(0.2));
  on("detail-zoom-out", "click", () => zoomDetail(-0.2));
  on("detail-rotate", "click", rotateDetail);
  on("detail-fit", "click", resetDetailTransform);
  on("detail-media", "click", () => {
    detailZoom = detailZoom > 1 ? 1 : 1.8;
    applyDetailTransform();
  });
  on("saved-views-list", "click", async (event) => {
    const apply = event.target.closest("[data-apply-saved-view]");
    const share = event.target.closest("[data-share-saved-view]");
    const del = event.target.closest("[data-delete-saved-view]");
    if (apply) {
      const view = readSavedViews().find((item) => item.id === apply.dataset.applySavedView);
      if (view) {
        safeEl("saved-views-dialog")?.close();
        applyGalleryState(view.state);
      }
    }
    if (share) await shareSavedView(share.dataset.shareSavedView);
    if (del) deleteSavedView(del.dataset.deleteSavedView);
  });
  on("share-view", "click", shareCurrentView);
  on("shortcuts-open", "click", showKeyboardShortcuts);
  on("users-open", "click", () => openUserSearchPage());
  on("profile-open", "click", () => currentUser && openProfile(currentUser.username));
  on("user-search-close", "click", () => $("user-search-dialog").close());
  on("user-search-input", "input", () => {
    clearTimeout(window.__userSearchTimer);
    window.__userSearchTimer = setTimeout(searchUsers, isLowPowerMode() ? 320 : 180);
  });
  on("users-page-query", "input", () => {
    clearTimeout(window.__userSearchTimer);
    window.__userSearchTimer = setTimeout(searchUsers, isLowPowerMode() ? 320 : 180);
  });
  on("friends-open", "click", openFriendsPage);
  on("friends-close", "click", () => $("friends-dialog").close());
  on("friend-tab-incoming", "click", () => {
    showIfPresent("friend-requests-list", true);
    showIfPresent("friends-list", false);
  });
  on("friend-tab-list", "click", () => {
    showIfPresent("friend-requests-list", false);
    showIfPresent("friends-list", true);
  });
  on("following-feed", "click", openFollowingPage);
  on("liked-feed", "click", openLikedPage);
  on("live-checks-open", "click", () => runLiveChecks({ silent: false }));
  $("collections-open").addEventListener("click", () => openCollectionsPage());
  $("collections-close").addEventListener("click", () => $("collections-dialog").close());
  if ($("collection-picker-close")) $("collection-picker-close").addEventListener("click", () => $("collection-picker-dialog").close());
  $("collection-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    await createCollectionFromInputs({
      name: $("collection-name").value,
      description: $("collection-description").value,
      isPublic: $("collection-public").checked,
      noticeId: "collections-error",
    });
    $("collection-form").reset();
    $("collection-public").checked = true;
  });
  on("collections-page-form", "submit", async (event) => {
    event.preventDefault();
    await createCollectionFromInputs({
      name: $("collections-page-name").value,
      description: $("collections-page-description").value,
      isPublic: $("collections-page-public").checked,
      noticeId: "collections-page-error",
    });
    $("collections-page-form").reset();
    $("collections-page-public").checked = true;
  });
  on("collections-page-community", "click", () => openCollectionsPage({ mine: false }));
  on("collections-page-mine", "click", () => openCollectionsPage({ mine: true }));
  on("collections-page-refresh", "click", () => openCollectionsPage({ mine: collectionsMineMode, preserveSelection: true }));
  $("collection-picker-form").addEventListener("submit", addToCollection);
  $("studio-open").addEventListener("click", openStudio);
  $("studio-close").addEventListener("click", () => $("studio-dialog").close());
  if ($("settings-close")) $("settings-close").addEventListener("click", () => {
    $("settings-dialog").close();
    if (location.pathname === "/settings") routeTo(routeForPage(currentPage || "discover"));
  });
  $("report-form").addEventListener("submit", submitReport);
  if ($("report-close")) $("report-close").addEventListener("click", () => $("report-dialog").close());
  $("clear-tag").addEventListener("click", () => {
    clearGalleryFilters();
  });
  $("tag-cloud").addEventListener("click", (event) => {
    const tagButton = event.target.closest("[data-tag]");
    if (!tagButton) return;
    $("search").value = tagButton.dataset.tag;
    loadMedia(1);
  });
  $("settings-open").addEventListener("click", () => {
    openCurrentUserDestination(ACCOUNT_NAVIGATION.settingsTarget);
  });
  $("settings-form").addEventListener("submit", submitSettings);
  $("settings-age-save").addEventListener("click", submitAgeVerification);
  $("age-verify-form").addEventListener("submit", submitAgeVerification);
  $("age-close").addEventListener("click", () => $("age-dialog").close());
  $("avatar-save").addEventListener("click", saveAvatar);
  $("settings-avatar-file").addEventListener("change", previewSelectedAvatar);
  $("upload-open").addEventListener("click", () => {
    routeTo(currentUser ? "/upload" : "/login");
    currentUser ? $("upload-dialog").showModal() : $("auth-dialog").showModal();
  });
  if ($("upload-close")) $("upload-close").addEventListener("click", closeUploadDialog);
  on("upload-dialog", "cancel", (event) => {
    event.preventDefault();
    closeUploadDialog();
  });
  on("upload-dialog", "click", (event) => {
    if (event.target === safeEl("upload-dialog")) closeUploadDialog();
  });
  $("upload-form").addEventListener("submit", submitUpload);
  on("upload-analyze", "click", () => analyzeUploadSelection({ apply: true, silent: false }));
  on("upload-auto-ai", "change", (event) => {
    if (event.target.checked) analyzeUploadSelection({ apply: true, silent: true });
    else setTextIfPresent("upload-ai-status", "AI suggestions are off for now. You can still analyze the first file manually.");
  });
  on("edit-media-close", "click", () => $("edit-media-dialog").close());
  on("edit-media-form", "submit", submitEditMedia);
  $("upload-category").addEventListener("change", toggleNewCategory);
  on("upload-subcategory", "change", toggleNewCategory);
  on("edit-media-category", "change", toggleEditSubcategory);
  on("edit-media-subcategory", "change", toggleEditSubcategory);
  $("upload-file").addEventListener("change", updateUploadFileSummary);
  const dropZone = document.querySelector(".drop-zone");
  if (dropZone) {
    ["dragenter", "dragover"].forEach((eventName) => dropZone.addEventListener(eventName, (event) => {
      event.preventDefault();
      dropZone.classList.add("is-dragging");
    }));
    dropZone.addEventListener("dragleave", () => {
      dropZone.classList.remove("is-dragging");
    });
    dropZone.addEventListener("drop", (event) => {
      event.preventDefault();
      dropZone.classList.remove("is-dragging");
      const files = event.dataTransfer?.files;
      const input = safeEl("upload-file");
      if (input && files?.length) {
        input.files = files;
        updateUploadFileSummary();
      }
    });
  }
  if ($("upload-title")) $("upload-title").addEventListener("input", checkUploadReadiness);
  $("refresh").addEventListener("click", refreshAll);
  on("gallery-prev", "click", () => loadCurrentGalleryPage(galleryPage - 1, { scrollToTop: true }));
  on("gallery-next", "click", () => loadCurrentGalleryPage(galleryPage + 1, { scrollToTop: true }));
  on("active-filters", "click", (event) => {
    const chip = event.target.closest("[data-clear-filter]");
    if (!chip) return;
    const key = chip.dataset.clearFilter;
    if (key === "all") return clearGalleryFilters();
    if (key === "search") $("search").value = "";
    if (key === "kind") $("kind-filter").value = "";
    if (key === "category") $("category-filter").value = "";
    if (key === "subcategory") $("subcategory-filter").value = "";
    if (key === "uploader") $("uploader-filter").value = "";
    if (key === "minSize") $("min-size-filter").value = "";
    if (key === "maxSize") $("max-size-filter").value = "";
    if (key === "dateFrom") $("date-from-filter").value = "";
    if (key === "dateTo") $("date-to-filter").value = "";
    if (key === "adult") $("adult-filter").value = "show";
    if (key === "sort") $("sort-filter").value = "new";
    loadMedia(1);
  });
  ["kind-filter", "sort-filter", "adult-filter", "date-from-filter", "date-to-filter"].forEach((id) => $(id).addEventListener("input", () => loadMedia(1)));
  on("category-filter", "input", () => {
    populateSubcategorySelect("subcategory-filter", $("category-filter").value, {
      includeCreate: false,
      selectedValue: "",
      emptyLabel: "All subcategories",
    });
    loadMedia(1);
  });
  on("subcategory-filter", "input", () => loadMedia(1));
  ["uploader-filter", "min-size-filter", "max-size-filter"].forEach((id) => $(id).addEventListener("input", () => {
    clearTimeout(window.__advancedFilterTimer);
    renderActiveFilters();
    window.__advancedFilterTimer = setTimeout(() => loadMedia(1), isLowPowerMode() ? 450 : SEARCH_DEBOUNCE_MS);
  }));
  $("search").addEventListener("input", () => {
    clearTimeout(window.__gallerySearchTimer);
    renderActiveFilters();
    window.__gallerySearchTimer = setTimeout(() => loadMedia(1), isLowPowerMode() ? 450 : SEARCH_DEBOUNCE_MS);
  });
  on("users-page-results", "click", async (event) => {
    const profile = event.target.closest("[data-profile]");
    const follow = event.target.closest("[data-follow-user]");
    const friend = event.target.closest("[data-friend-user]");
    if (profile) await openProfile(profile.dataset.profile);
    if (follow) await toggleFollowUser(follow.dataset.followUser);
    if (friend) await sendFriendRequest(friend.dataset.friendUser);
  });
  $("gallery-grid").addEventListener("click", async (event) => {
    const open = event.target.closest("[data-open]");
    const cardOpen = event.target.closest(".media-card[data-open]");
    const profile = event.target.closest("[data-profile]");
    const compare = event.target.closest("[data-compare]");
    const like = event.target.closest("[data-like]");
    const bookmark = event.target.closest("[data-bookmark]");
    const collect = event.target.closest("[data-collect]");
    const copy = event.target.closest("[data-copy]");
    const manage = event.target.closest("[data-edit-media]");
    const ageGate = event.target.closest("[data-age-gate]");
    const download = event.target.closest("[data-download]");
    const del = event.target.closest("[data-delete-media]");
    if (profile) return openProfile(profile.dataset.profile);
    if (compare) return toggleCompareSelection(compare.dataset.compare);
    if (open && !handleAdultOpen(open.dataset.open)) return openDetail(open.dataset.open);
    if (manage) return editOwnMedia(manage.dataset.editMedia);
    if (del) return deleteOwnMedia(del.dataset.deleteMedia);
    if (download) return downloadMedia(download.dataset.download);
    if (like) return toggleLike(like.dataset.like);
    if (bookmark) return toggleBookmark(bookmark.dataset.bookmark);
    if (collect) return openCollectionPicker(collect.dataset.collect);
    if (copy) return copyAddress(copy.dataset.copy);
    if (ageGate) return openAgeDialog("Verify your age to download this 18+ post.");
    if (cardOpen && !handleAdultOpen(cardOpen.dataset.open)) return openDetail(cardOpen.dataset.open);
  });
  $("user-search-results").addEventListener("click", async (event) => {
    const profile = event.target.closest("[data-profile]");
    const follow = event.target.closest("[data-follow-user]");
    const friend = event.target.closest("[data-friend-user]");
    if (profile) await openProfile(profile.dataset.profile);
    if (follow) await toggleFollowUser(follow.dataset.followUser);
    if (friend) await sendFriendRequest(friend.dataset.friendUser);
  });
  $("friends-dialog").addEventListener("click", async (event) => {
    const action = event.target.closest("[data-friend-action]");
    const profile = event.target.closest("[data-profile]");
    const follow = event.target.closest("[data-follow-user]");
    const friend = event.target.closest("[data-friend-user]");
    if (action) await respondFriendRequest(action.dataset.requestId, action.dataset.friendAction);
    if (profile) await openProfile(profile.dataset.profile);
    if (follow) await toggleFollowUser(follow.dataset.followUser);
    if (friend) await sendFriendRequest(friend.dataset.friendUser);
  });
  on("friends-page", "click", async (event) => {
    const action = event.target.closest("[data-friend-action]");
    const profile = event.target.closest("[data-profile]");
    const follow = event.target.closest("[data-follow-user]");
    const friend = event.target.closest("[data-friend-user]");
    if (action) await respondFriendRequest(action.dataset.requestId, action.dataset.friendAction);
    if (profile) await openProfile(profile.dataset.profile);
    if (follow) await toggleFollowUser(follow.dataset.followUser);
    if (friend) await sendFriendRequest(friend.dataset.friendUser);
  });
  $("profile-close").addEventListener("click", () => {
    activeProfileUsername = "";
    if (location.hash.startsWith("#user/")) history.replaceState(null, "", location.pathname + location.search);
    $("profile-dialog").close();
  });
  $("profile-view").addEventListener("click", async (event) => {
    const open = event.target.closest("[data-open]");
    const collection = event.target.closest("[data-collection-open]");
    const profile = event.target.closest("[data-profile]");
    const follow = event.target.closest("[data-follow-user]");
    const friend = event.target.closest("[data-friend-user]");
    const copyProfile = event.target.closest("[data-copy-profile]");
    if (open && !handleAdultOpen(open.dataset.open)) await openDetail(open.dataset.open);
    if (collection) {
      $("collections-dialog").showModal();
      await openCollection(collection.dataset.collectionOpen);
    }
    if (profile) await openProfile(profile.dataset.profile);
    if (follow) await toggleFollowUser(follow.dataset.followUser);
    if (friend) await sendFriendRequest(friend.dataset.friendUser);
    if (copyProfile) await copyProfileLink(copyProfile.dataset.copyProfile);
  });
  on("profile-page-view", "click", async (event) => {
    const open = event.target.closest("[data-open]");
    const collection = event.target.closest("[data-collection-open]");
    const profile = event.target.closest("[data-profile]");
    const follow = event.target.closest("[data-follow-user]");
    const friend = event.target.closest("[data-friend-user]");
    const copyProfile = event.target.closest("[data-copy-profile]");
    const profileCustomizeToggle = event.target.closest("[data-profile-customize-toggle]");
    const profileCustomizeSave = event.target.closest("[data-profile-customize-save]");
    const settings = event.target.closest("[data-open-settings]");
    if (open && !handleAdultOpen(open.dataset.open)) await openDetail(open.dataset.open);
    if (collection) {
      await openCollectionsPage({ mine: collectionsMineMode, preserveSelection: true });
      await openCollection(collection.dataset.collectionOpen);
    }
    if (profile) await openProfile(profile.dataset.profile);
    if (follow) await toggleFollowUser(follow.dataset.followUser);
    if (friend) await sendFriendRequest(friend.dataset.friendUser);
    if (copyProfile) await copyProfileLink(copyProfile.dataset.copyProfile);
    if (profileCustomizeToggle) {
      profileCustomizeOpen = !profileCustomizeOpen;
      if (profilePageData) renderProfile(profilePageData);
      return;
    }
    if (profileCustomizeSave) {
      await saveProfileCustomization();
      return;
    }
    if (settings) openSettingsPanel();
  });
  $("collections-list").addEventListener("click", async (event) => {
    const open = event.target.closest("[data-collection-open]");
    if (open) await openCollection(open.dataset.collectionOpen);
  });
  on("collections-page-list", "click", async (event) => {
    const open = event.target.closest("[data-collection-open]");
    if (open) await openCollection(open.dataset.collectionOpen);
  });
  $("collection-media").addEventListener("click", async (event) => {
    const open = event.target.closest("[data-open]");
    if (open && !handleAdultOpen(open.dataset.open)) await openDetail(open.dataset.open);
  });
  on("collections-page-detail", "click", async (event) => {
    const open = event.target.closest("[data-open]");
    if (open && !handleAdultOpen(open.dataset.open)) await openDetail(open.dataset.open);
  });
  $("compare-grid").addEventListener("click", async (event) => {
    const open = event.target.closest("[data-open]");
    const remove = event.target.closest("[data-compare-remove]");
    if (remove) {
      compareSelection.delete(Number(remove.dataset.compareRemove));
      updateCompareUi();
      renderCompareBoard();
    }
    if (open && !handleAdultOpen(open.dataset.open)) await openDetail(open.dataset.open);
  });
  $("studio-list").addEventListener("click", async (event) => {
    const open = event.target.closest("[data-open]");
    const edit = event.target.closest("[data-edit-media]");
    const del = event.target.closest("[data-delete-media]");
    const restore = event.target.closest("[data-restore-media]");
    if (open && !handleAdultOpen(open.dataset.open)) await openDetail(open.dataset.open);
    if (edit) await editOwnMedia(edit.dataset.editMedia);
    if (del) await deleteOwnMedia(del.dataset.deleteMedia);
    if (restore) await restoreOwnMedia(restore.dataset.restoreMedia);
  });
  on("studio-page-list", "click", async (event) => {
    const open = event.target.closest("[data-open]");
    const edit = event.target.closest("[data-edit-media]");
    const del = event.target.closest("[data-delete-media]");
    const restore = event.target.closest("[data-restore-media]");
    if (open && !handleAdultOpen(open.dataset.open)) await openDetail(open.dataset.open);
    if (edit) await editOwnMedia(edit.dataset.editMedia);
    if (del) await deleteOwnMedia(del.dataset.deleteMedia);
    if (restore) await restoreOwnMedia(restore.dataset.restoreMedia);
  });
  $("comments-list").addEventListener("click", async (event) => {
    const del = event.target.closest("[data-delete-comment]");
    if (del) await deleteComment(del.dataset.deleteComment);
  });
  $("detail-close").addEventListener("click", closeDetailDialog);
  on("detail-prev", "click", () => openAdjacentDetail(-1));
  on("detail-next", "click", () => openAdjacentDetail(1));
  $("detail-dialog").addEventListener("cancel", () => stopMediaPlayback($("detail-dialog")));
  $("detail-dialog").addEventListener("close", () => stopMediaPlayback($("detail-dialog")));
  $("detail-dialog").addEventListener("click", (event) => {
    if (event.target === $("detail-dialog")) closeDetailDialog();
    const profile = event.target.closest("[data-profile]");
    if (profile) openProfile(profile.dataset.profile);
  });
  $("detail-like").addEventListener("click", () => activeDetail && toggleLike(activeDetail.id));
  $("detail-bookmark").addEventListener("click", () => activeDetail && toggleBookmark(activeDetail.id));
  $("detail-collect").addEventListener("click", () => activeDetail && openCollectionPicker(activeDetail.id));
  $("detail-report").addEventListener("click", () => activeDetail && openReport(activeDetail.id));
  $("detail-copy").addEventListener("click", () => activeDetail && copyAddress(activeDetail.id));
  $("detail-download").addEventListener("click", async (event) => {
    event.preventDefault();
    if (activeDetail) await downloadMedia(activeDetail.id);
  });
  $("comment-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!currentUser) return $("auth-dialog").showModal();
    const body = $("comment-body").value.trim();
    if (!body || !activeDetail) return;
    await apiFetch(`/api/media/${activeDetail.id}/comments`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ body }),
    });
    $("comment-body").value = "";
    await openDetail(activeDetail.id);
  });
}

async function openRouteFromLocation() {
  if (REMOTE_MODE) return false;
  const path = location.pathname.replace(/\/+$/, "") || "/";
  const mediaMatch = path.match(/^\/media\/(\d+)$/);
  const userMatch = path.match(/^\/users\/([^/]+)$/);
  routeSyncInProgress = true;
  try {
    if (mediaMatch) {
      if (!["discover", "following", "liked", "collections", "studio", "profile"].includes(currentPage)) {
        setCurrentPage("discover", { updateRoute: false });
      }
      await openDetail(mediaMatch[1], { updateRoute: false });
      return true;
    }
    if (safeEl("detail-dialog")?.open) closeDetailDialog({ updateRoute: false });
    if (userMatch) {
      await openProfile(decodeURIComponent(userMatch[1]));
      return true;
    }
    if (path === "/collections") {
      await openCollectionsPage();
      return true;
    }
    if (path === "/following") {
      await openFollowingPage();
      return true;
    }
    if (path === "/liked") {
      await openLikedPage();
      return true;
    }
    if (path === "/users") {
      await openUserSearchPage({ preserveQuery: true });
      return true;
    }
    if (path === "/friends") {
      await openFriendsPage();
      return true;
    }
    if (path === "/studio") {
      await openStudio();
      return true;
    }
    if (path === "/profile" && currentUser?.username) {
      await openProfile(currentUser.username);
      return true;
    }
    if (path === "/upload") {
      setCurrentPage("discover", { updateRoute: false });
      currentUser ? safeEl("upload-dialog")?.showModal() : safeEl("auth-dialog")?.showModal();
      return true;
    }
    if (path === "/settings") {
      currentUser ? openSettingsPanel() : safeEl("auth-dialog")?.showModal();
      return true;
    }
    if (path === "/login") {
      safeEl("auth-dialog")?.showModal();
      return true;
    }
    if (path === "/") {
      setCurrentPage("discover", { updateRoute: false });
      return true;
    }
    return false;
  } finally {
    routeSyncInProgress = false;
  }
}

async function boot() {
  applyRuntimePerformanceMode();
  bindEvents();
  setCurrentPage("discover", { updateRoute: false });
  renderAuth();
  updateCompareUi();
  enhanceMotion(document);
  startSilentChecks();
  window.addEventListener("hashchange", async () => {
    const hashProfile = decodeURIComponent(location.hash || "").match(/^#user\/(.+)/)?.[1];
    if (!hashProfile) return;
    await openProfile(hashProfile);
  });
  window.addEventListener("popstate", async () => {
    try {
      await openRouteFromLocation();
    } catch (err) {
      showToast(err.message || "Route unavailable.", "error");
    }
  });
  const hasBackendConfig = await initApiOrigin();
  if (REMOTE_MODE && !hasBackendConfig) return;
  try {
    refreshSiteBackground({ force: false });
    if (token) await refreshMe();
    await refreshAll();
    await openRouteFromLocation();
    const hashProfile = decodeURIComponent(location.hash || "").match(/^#user\/(.+)/)?.[1];
    if (hashProfile) await openProfile(hashProfile);
    $("connection-status").textContent = REMOTE_MODE ? "Live" : "Local";
    runLiveChecks({ silent: true });
  } catch (err) {
    $("connection-status").textContent = "Offline";
    $("result-count").textContent = err.message;
  }
}

boot();

// =====================================================================
// 2026 UI/UX Revamp helpers: no API changes, visual state only.
// =====================================================================
(function installImageGalleryUxRevamp() {
  const ready = () => {
    if (!document.body || document.body.dataset.uxRevamp === 'ready') return;
    document.body.dataset.uxRevamp = 'ready';
    document.body.classList.add('ux-revamp-ready');

    const topbarButtons = Array.from(document.querySelectorAll('.topbar-actions button'));
    const pageButtonMap = new Map([
      ['discover-open', 'discover-page'], ['collections-open', 'collections-page'], ['users-open', 'users-page'],
      ['friends-open', 'friends-page'], ['studio-open', 'studio-page'], ['profile-open', 'profile-page'],
      ['following-feed', 'discover-page'], ['liked-feed', 'discover-page'], ['live-checks-open', 'discover-page']
    ]);

    const markActiveNavigation = () => {
      let visiblePageId = '';
      document.querySelectorAll('.app-page').forEach((page) => {
        if (!page.hidden && getComputedStyle(page).display !== 'none') visiblePageId = page.id;
      });
      topbarButtons.forEach((button) => {
        const isActive = pageButtonMap.get(button.id) === visiblePageId;
        button.classList.toggle('is-active', isActive);
        if (isActive) button.setAttribute('aria-current', 'page');
        else button.removeAttribute('aria-current');
      });
    };

    topbarButtons.forEach((button) => button.addEventListener('click', () => setTimeout(markActiveNavigation, 50), { passive: true }));
    markActiveNavigation();
    if (!isLowPowerMode()) {
      setInterval(() => {
        if (!document.hidden) markActiveNavigation();
      }, 10000);
    }

    if (!isLowPowerMode() && 'IntersectionObserver' in window && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      const seen = new WeakSet();
      const observer = new IntersectionObserver((entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add('ux-visible');
          observer.unobserve(entry.target);
        });
      }, { threshold: 0.08, rootMargin: '0px 0px -5% 0px' });
      const scan = () => document.querySelectorAll('.media-card, .collection-card, .user-card, .studio-item, .saved-view-card, .page-panel').forEach((el) => {
        if (seen.has(el)) return;
        seen.add(el);
        el.classList.add('ux-reveal');
        observer.observe(el);
      });
      scan();
      new MutationObserver(debounce(scan, 180)).observe(document.body, { childList: true, subtree: true });
    }

    document.addEventListener('keydown', (event) => {
      const tag = document.activeElement?.tagName?.toLowerCase();
      if (event.key === '/' && !event.metaKey && !event.ctrlKey && !['input', 'textarea', 'select'].includes(tag)) {
        const search = document.getElementById('search');
        if (search) { event.preventDefault(); search.focus(); search.select?.(); }
      }
    });
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready, { once: true });
  else ready();
})();

// =====================================================================
// 2026 Dynamic Scaling + Overlap Shield — Image Gallery
// Runtime-only UI guard. It does not change API calls, auth, uploads, or DB logic.
// =====================================================================
(function installImageGalleryDynamicScalingShield() {
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
  const WATCH_SELECTOR = [
    '.topbar', '.topbar-actions', '.brand', '.layout', '.sidebar', '.content', '.page-panel',
    '.gallery-grid', '.media-card', '.media-info', '.media-card-head', '.card-actions',
    '.action-row', '.modal-actions', '.detail-head-actions', '.profile-actions',
    '.content-actions', '.collection-card', '.studio-item', '.user-card', '.saved-view-card',
    '.detail-grid', '.detail-side', '.detail-tools', '.modal-shell', '.profile-showcase',
    '.profile-section-card', '.profile-insight-card', '.upload-queue-item', '.account-card'
  ].join(',');

  let scheduled = false;

  function computeScale() {
    const width = Math.max(320, window.visualViewport?.width || window.innerWidth || document.documentElement.clientWidth || 320);
    const height = Math.max(480, window.visualViewport?.height || window.innerHeight || document.documentElement.clientHeight || 480);
    const zoomAwareWidthScale = width / 1440;
    const heightScale = height / 900;
    return clamp(Math.min(zoomAwareWidthScale, heightScale) + 0.16, 0.76, 1.06);
  }

  function classifyViewport() {
    const width = window.visualViewport?.width || window.innerWidth || document.documentElement.clientWidth || 0;
    if (width <= 560) return 'compact';
    if (width <= 1120) return 'narrow';
    if (width >= 1600) return 'wide';
    return 'normal';
  }

  function setScaleVars() {
    const scale = computeScale();
    document.documentElement.style.setProperty('--dynamic-ui-scale', scale.toFixed(3));
    document.body?.setAttribute('data-ui-size', classifyViewport());
  }

  function visibleElement(el) {
    if (!el || !(el instanceof HTMLElement)) return false;
    if (!el.isConnected) return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }

  function markOverflow(root) {
    if (isLowPowerMode()) return;
    const activePage = document.querySelector('.app-page:not([hidden])');
    const scope = root && root.querySelectorAll ? root : (activePage || document);
    const nodes = new Set();
    if (scope instanceof HTMLElement && scope.matches(WATCH_SELECTOR)) nodes.add(scope);
    scope.querySelectorAll?.(WATCH_SELECTOR).forEach((node) => nodes.add(node));
    nodes.forEach((el) => {
      if (!visibleElement(el)) return;
      const horizontalOverflow = el.scrollWidth > Math.ceil(el.clientWidth + 2);
      el.classList.toggle('ui-overflow-guard', horizontalOverflow);
    });
  }

  function run(root) {
    scheduled = false;
    if (!document.body) return;
    setScaleVars();
    markOverflow(root || document);
  }

  function schedule(root) {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => run(root));
  }

  function boot() {
    if (!document.body) return;
    run(document);
    window.addEventListener('resize', () => schedule(document), { passive: true });
    window.addEventListener('orientationchange', () => schedule(document), { passive: true });
    document.addEventListener('transitionend', (event) => {
      if (!isLowPowerMode()) schedule(event.target);
    }, { passive: true });

    const scheduleActivePage = debounce(() => schedule(document.querySelector('.app-page:not([hidden])') || document), 180);
    new MutationObserver(scheduleActivePage).observe(document.body, { childList: true, subtree: true });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();


/* XENUS_UX_ANIMATION_PACK_V1 */
(() => {
  const reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduceMotion) {
    document.body?.classList.add("xenus-animated-ready");
    return;
  }

  const ready = () => {
    document.body.classList.add("xenus-animated-ready");

    const revealSelectors = [
      ".media-card",
      ".collection-card",
      ".user-card",
      ".studio-item",
      ".sidebar-block",
      ".account-card",
      ".panel",
      ".stats-grid",
      ".content-head",
      ".profile-hero",
      ".profile-card",
      ".profile-showcase",
      ".upload-ai-panel",
      ".drop-zone"
    ];

    const revealItems = () => {
      const nodes = Array.from(document.querySelectorAll(revealSelectors.join(",")));
      nodes.forEach((node, index) => {
        if (node.dataset.xenusRevealReady === "1") return;
        node.dataset.xenusRevealReady = "1";
        node.classList.add("xenus-reveal");
        node.style.setProperty("--xenus-stagger-delay", `${Math.min(index % 12, 11) * 45}ms`);
      });

      if (!("IntersectionObserver" in window)) {
        nodes.forEach(node => node.classList.add("xenus-in-view"));
        return;
      }

      const observer = new IntersectionObserver((entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            entry.target.classList.add("xenus-in-view");
            observer.unobserve(entry.target);
          }
        }
      }, { threshold: 0.08, rootMargin: "0px 0px -6% 0px" });

      nodes.forEach(node => {
        if (!node.classList.contains("xenus-in-view")) observer.observe(node);
      });
    };

    const addRipple = (event) => {
      const button = event.target.closest("button, .button-link, .icon-button");
      if (!button || button.disabled) return;

      const rect = button.getBoundingClientRect();
      const ripple = document.createElement("span");
      ripple.className = "xenus-ripple";
      ripple.style.left = `${event.clientX - rect.left}px`;
      ripple.style.top = `${event.clientY - rect.top}px`;
      button.appendChild(ripple);
      setTimeout(() => ripple.remove(), 700);
    };

    document.addEventListener("pointerdown", addRipple, { passive: true });

    revealItems();

    const mutationObserver = new MutationObserver(() => {
      window.requestAnimationFrame(revealItems);
    });

    mutationObserver.observe(document.body, {
      childList: true,
      subtree: true
    });

    document.addEventListener("click", (event) => {
      const card = event.target.closest(".media-card, .collection-card, .user-card, .studio-item");
      if (!card) return;
      card.animate(
        [
          { transform: "scale(1)" },
          { transform: "scale(.985)" },
          { transform: "scale(1.012)" },
          { transform: "scale(1)" }
        ],
        {
          duration: 320,
          easing: "cubic-bezier(.2, 1.4, .35, 1)"
        }
      );
    }, { passive: true });
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", ready, { once: true });
  } else {
    ready();
  }
})();

/* XENUS_GALLERY_THUMB_LAZY_V1 */
(() => {
  const toThumbUrl = (url) => {
    const value = String(url || "");
    if (!value.includes("/api/media/") || !value.includes("/file")) return value;
    return value.replace(/\/api\/media\/(\d+)\/file(\?[^"']*)?/, "/api/media/$1/thumb?w=520$2");
  };

  const applyThumbs = (root = document) => {
    root.querySelectorAll?.('img[src*="/api/media/"][src*="/file"]').forEach((img) => {
      if (img.closest(".detail-media, .slideshow-shell, .compare-modal")) return;
      img.loading = "lazy";
      img.decoding = "async";
      const next = toThumbUrl(img.getAttribute("src"));
      if (next && next !== img.getAttribute("src")) {
        img.setAttribute("data-full-src", img.getAttribute("src"));
        img.setAttribute("src", next);
      }
    });

    root.querySelectorAll?.("video").forEach((video) => {
      if (!video.closest(".detail-media, .slideshow-shell")) {
        video.preload = "metadata";
      }
    });
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => applyThumbs(), { once: true });
  } else {
    applyThumbs();
  }

  new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      mutation.addedNodes.forEach((node) => {
        if (node.nodeType === 1) applyThumbs(node);
      });
    }
  }).observe(document.documentElement, { childList: true, subtree: true });
})();

/* XENUS_HARD_SINGLE_SCROLLBAR_GUARD_V1 */
(() => {
  const allowedScrollerSelector = [
    "dialog",
    ".modal",
    ".modal-shell",
    ".detail-shell",
    ".profile-shell",
    ".slideshow-shell",
    ".table-wrap",
    ".horizontal-scroll",
    ".carousel",
    ".tag-cloud",
    ".chip-row",
    ".scroll-panel"
  ].join(",");

  const isPageLikeScroller = (el) => {
    if (!el || el === document.documentElement || el === document.body) return false;
    if (el.closest(allowedScrollerSelector)) return false;

    const style = getComputedStyle(el);
    const overflowY = style.overflowY;
    if (!["auto", "scroll", "overlay"].includes(overflowY)) return false;

    const rect = el.getBoundingClientRect();
    const almostViewport = rect.height >= window.innerHeight * 0.72;
    const actuallyScrollable = el.scrollHeight > el.clientHeight + 8;

    return almostViewport && actuallyScrollable;
  };

  const fixNestedScrollers = () => {
    document.body.classList.toggle("xenus-modal-lock", !!document.querySelector("dialog[open], .modal[open]"));

    document.querySelectorAll(".xenus-page-scroll-container").forEach((el) => {
      el.classList.remove("xenus-page-scroll-container");
    });

    document.querySelectorAll("body *").forEach((el) => {
      if (isPageLikeScroller(el)) {
        el.classList.add("xenus-page-scroll-container");
      }
    });
  };

  const run = () => requestAnimationFrame(fixNestedScrollers);

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", run, { once: true });
  } else {
    run();
  }

  window.addEventListener("resize", run, { passive: true });
  window.addEventListener("hashchange", run, { passive: true });

  new MutationObserver(run).observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["open", "class", "style"]
  });
})();
