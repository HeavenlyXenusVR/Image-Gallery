import { useCallback, useEffect, useMemo, useState } from "react";
import { Navigate, Route, Routes, useNavigate } from "react-router-dom";
import { apiFetch, cachedApiFetch, clearApiCache, prefetchApi, readStoredUser, readToken, resolveApiUrl, toQuery, writeStoredUser, writeToken } from "./api.js";
import { Shell } from "./components/Shell.jsx";
import { NotFound } from "./components/ui.jsx";
import { DEFAULT_SETTINGS, PAGE_SIZE, setRuntimeMaxUploadBytes } from "./config.js";
import { useLiveRefresh } from "./hooks/useLiveRefresh.js";
import { galleryClassName, galleryStyle } from "./utils/appearance.js";
import { AuthPage } from "./pages/AuthPage.jsx";
import { CollectionsPage } from "./pages/CollectionsPage.jsx";
import { DiscoverPage } from "./pages/DiscoverPage.jsx";
import { FeedPage } from "./pages/FeedPage.jsx";
import { FriendsPage } from "./pages/FriendsPage.jsx";
import { MediaDetailPage } from "./pages/MediaDetailPage.jsx";
import { MessagesPage } from "./pages/MessagesPage.jsx";
import { ProfilePage } from "./pages/ProfilePage.jsx";
import { SettingsPage } from "./pages/SettingsPage.jsx";
import { StudioPage } from "./pages/StudioPage.jsx";
import { UploadPage } from "./pages/UploadPage.jsx";
import { UsersPage } from "./pages/UsersPage.jsx";

const BOOT_TIPS = [
  "Video thumbnails are pre-warmed in the background so gallery cards do not wait on first open.",
  "The detail player now remounts when you switch quality, so medium and low really swap sources.",
  "Discover and user search are prefetched while the overlay is up so the first deck lands faster.",
  "Muted preview clips now lean on the lighter video ladder instead of reaching for the largest file first.",
];
const SITE_BACKGROUND_KEY = "image_gallery_site_background";
const SITE_BACKGROUND_REFRESH_MS = 5 * 60_000;

function readSiteBackground() {
  try {
    const raw = localStorage.getItem(SITE_BACKGROUND_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch (_error) {
    return null;
  }
}

function writeSiteBackground(background) {
  try {
    if (background) localStorage.setItem(SITE_BACKGROUND_KEY, JSON.stringify(background));
    else localStorage.removeItem(SITE_BACKGROUND_KEY);
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

function clearSiteBackground() {
  writeSiteBackground(null);
  document.documentElement.style.setProperty("--site-background-image", "none");
  document.body.dataset.backgroundReady = "0";
}

function galleryPageSize(settings) {
  const parsed = Number(settings?.items_per_page);
  if (!Number.isFinite(parsed)) return PAGE_SIZE;
  return Math.min(60, Math.max(12, Math.round(parsed)));
}

function App() {
  const navigate = useNavigate();
  const [token, setTokenState] = useState(() => readToken());
  const [user, setUserState] = useState(() => readStoredUser());
  const [lookups, setLookups] = useState({ categories: [], tags: [], live: null });
  const [toast, setToast] = useState(null);
  const [bootPhase, setBootPhase] = useState(() => readToken() ? "Checking your gallery access" : "Opening public gallery");
  const [bootTipIndex, setBootTipIndex] = useState(0);
  const [bootDismissed, setBootDismissed] = useState(false);
  const [bootLeaving, setBootLeaving] = useState(false);
  const [sessionReady, setSessionReady] = useState(() => !readToken());
  const [lookupsReady, setLookupsReady] = useState(false);

  const showToast = useCallback((message, kind = "info") => {
    setToast({ message, kind, id: Date.now() });
  }, []);

  const setSessionUser = useCallback((nextUser) => {
    setUserState(nextUser);
    writeStoredUser(nextUser);
  }, []);

  const logout = useCallback((withNotice = true) => {
    void apiFetch("/api/auth/logout", { method: "POST", timeoutMs: 5000 }).catch(() => null);
    writeToken("");
    writeStoredUser(null);
    clearApiCache();
    setTokenState("");
    setUserState(null);
    setSessionReady(true);
    if (withNotice) showToast("Signed out.", "success");
    navigate("/");
  }, [navigate, showToast]);

  const refreshLookups = useCallback(async () => {
    try {
      const [categories, tags, live] = await Promise.allSettled([
        cachedApiFetch("/api/categories", { ttl: 10 * 60_000, staleTtl: 60 * 60_000, storage: "local" }),
        cachedApiFetch("/api/tags", { ttl: 10 * 60_000, staleTtl: 60 * 60_000, storage: "local" }),
        cachedApiFetch("/api/live/checks", { ttl: 30_000, staleTtl: 5 * 60_000 }),
      ]);
      if (live.status === "fulfilled") setRuntimeMaxUploadBytes(live.value?.max_upload_bytes);
      setLookups({
        categories: categories.status === "fulfilled" ? categories.value.categories || [] : [],
        tags: tags.status === "fulfilled" ? tags.value.tags || [] : [],
        live: live.status === "fulfilled" ? live.value : null,
      });
    } finally {
      setLookupsReady(true);
    }
  }, []);

  const loginWith = useCallback((payload) => {
    writeToken(payload.token);
    writeStoredUser(payload.user);
    clearApiCache();
    setTokenState(payload.token);
    setUserState(payload.user);
    setSessionReady(true);
    setLookupsReady(false);
    setBootDismissed(false);
    setBootLeaving(false);
    setBootPhase("Curating your live feed");
    setBootTipIndex(0);
    showToast(`Welcome, ${payload.user?.display_name || payload.user?.username || "friend"}.`, "success");
    refreshLookups();
    navigate("/");
  }, [navigate, refreshLookups, showToast]);

  const refreshMe = useCallback(async () => {
    try {
      const data = await apiFetch("/api/me");
      setSessionUser(data.user);
      if (!readToken() && data.user) setTokenState("cookie-session");
    } catch (error) {
      if (error.status === 401) {
        writeToken("");
        writeStoredUser(null);
        setTokenState("");
        setSessionUser(null);
      }
    } finally {
      setSessionReady(true);
    }
  }, [setSessionUser]);

  useEffect(() => {
    refreshMe();
    refreshLookups();
  }, [refreshMe, refreshLookups]);

  useLiveRefresh(refreshLookups, { interval: 30_000 });
  useLiveRefresh(refreshMe, { enabled: Boolean(token), interval: 45_000 });

  useEffect(() => {
    if (!toast) return undefined;
    const timer = window.setTimeout(() => setToast(null), 3600);
    return () => window.clearTimeout(timer);
  }, [toast]);

  useEffect(() => {
    if (bootDismissed) return undefined;
    const timer = window.setInterval(() => {
      setBootTipIndex((current) => (current + 1) % BOOT_TIPS.length);
    }, 3200);
    return () => window.clearInterval(timer);
  }, [bootDismissed]);

  useEffect(() => {
    let cancelled = false;
    let refreshTimer = 0;

    const scheduleRefresh = (delay) => {
      window.clearTimeout(refreshTimer);
      refreshTimer = window.setTimeout(() => {
        void refreshSiteBackground({ force: true });
      }, Math.max(30_000, Number(delay) || SITE_BACKGROUND_REFRESH_MS));
    };

    const applySiteBackground = async (background, { persist = true } = {}) => {
      const rawUrl = String(background?.url || "").trim();
      if (!rawUrl) return false;
      const resolvedUrl = await resolveApiUrl(rawUrl);
      if (!resolvedUrl || cancelled) return false;
      const withBust = `${resolvedUrl}${resolvedUrl.includes("?") ? "&" : "?"}bg=${background?.id || Date.now()}`;
      await new Promise((resolve) => {
        const preload = new Image();
        preload.decoding = "async";
        preload.onload = () => {
          if (!cancelled) {
            document.documentElement.style.setProperty("--site-background-image", `url("${withBust.replace(/["\\]/g, "\\$&")}")`);
            document.body.dataset.backgroundReady = "1";
            if (persist) writeSiteBackground({ ...background, url: rawUrl, appliedAt: Date.now() });
          }
          resolve(null);
        };
        preload.onerror = () => resolve(null);
        preload.src = withBust;
      });
      return !cancelled;
    };

    const refreshSiteBackground = async ({ force = false } = {}) => {
      const cached = readSiteBackground();
      const cachedAge = Date.now() - Number(cached?.appliedAt || 0);
      if (!force && cached?.url && cachedAge < SITE_BACKGROUND_REFRESH_MS) {
        await applySiteBackground(cached, { persist: false });
        scheduleRefresh(SITE_BACKGROUND_REFRESH_MS - cachedAge);
        return;
      }
      try {
        const data = await apiFetch("/api/site/background");
        if (cancelled) return;
        if (data?.background?.url) {
          await applySiteBackground(data.background);
          scheduleRefresh((Number(data.refresh_after_seconds) || 300) * 1000);
          return;
        }
      } catch (_error) {
        // Background rotation is decorative; the gallery should remain quiet if it fails.
      }
      if (cached?.url) {
        await applySiteBackground(cached, { persist: false });
        scheduleRefresh(60_000);
        return;
      }
      clearSiteBackground();
      scheduleRefresh(SITE_BACKGROUND_REFRESH_MS);
    };

    void refreshSiteBackground();
    return () => {
      cancelled = true;
      window.clearTimeout(refreshTimer);
    };
  }, []);

  useEffect(() => {
    if (bootDismissed) return;
    if (!lookupsReady) {
      setBootPhase("Mapping categories and tags");
      return;
    }
    if (!sessionReady) {
      setBootPhase(readToken() ? "Checking your gallery access" : "Opening public gallery");
    }
  }, [bootDismissed, lookupsReady, sessionReady]);

  useEffect(() => {
    if (bootDismissed || !lookupsReady || !sessionReady) return undefined;
    let cancelled = false;
    const startedAt = Date.now();
    const settings = { ...DEFAULT_SETTINGS, ...(user?.user_settings || {}) };
    const pageSize = galleryPageSize(settings);
    const sort = settings.default_sort || DEFAULT_SETTINGS.default_sort || "new";
    const discoverQuery = toQuery({ limit: pageSize + 1, offset: 0, adult: "show", sort });

    const finishBoot = async () => {
      const remaining = Math.max(0, 1500 - (Date.now() - startedAt));
      if (remaining) {
        await new Promise((resolve) => window.setTimeout(resolve, remaining));
      }
      if (cancelled) return;
      setBootLeaving(true);
      window.setTimeout(() => {
        if (cancelled) return;
        setBootDismissed(true);
        setBootLeaving(false);
      }, 420);
    };

    const primeDeck = async () => {
      setBootPhase(user ? "Curating your live feed" : "Developing preview wall");
      await Promise.allSettled([
        cachedApiFetch(`/api/media${discoverQuery}`, { ttl: 20_000, staleTtl: 5 * 60_000, storage: "session" }),
        cachedApiFetch(`/api/users/search${toQuery({ limit: 12 })}`, { ttl: 15_000, staleTtl: 3 * 60_000, storage: "session" }),
        user ? cachedApiFetch("/api/collections?mine=true", { ttl: 20_000, staleTtl: 3 * 60_000, storage: "session" }) : Promise.resolve(null),
        user ? cachedApiFetch(`/api/feed/following${toQuery({ limit: pageSize + 1, offset: 0 })}`, { ttl: 20_000, staleTtl: 3 * 60_000, storage: "session" }) : Promise.resolve(null),
      ]);
      if (cancelled) return;
      prefetchApi(`/api/media${toQuery({ limit: pageSize + 1, offset: pageSize, adult: "show", sort })}`, { ttl: 20_000, staleTtl: 5 * 60_000, storage: "session" });
      if (user) {
        prefetchApi(`/api/feed/following${toQuery({ limit: pageSize + 1, offset: pageSize })}`, { ttl: 20_000, staleTtl: 3 * 60_000, storage: "session" });
      }
      setBootPhase("Developing preview wall");
      await finishBoot();
    };

    primeDeck();
    return () => {
      cancelled = true;
    };
  }, [bootDismissed, lookupsReady, sessionReady, user]);

  const ctx = useMemo(() => ({
    token,
    user,
    settings: { ...DEFAULT_SETTINGS, ...(user?.user_settings || {}) },
    lookups,
    loginWith,
    logout,
    refreshMe,
    refreshLookups,
    setSessionUser,
    showToast,
  }), [loginWith, logout, lookups, refreshLookups, refreshMe, setSessionUser, showToast, token, user]);

  return (
    <Shell ctx={ctx} className={galleryClassName(ctx.settings)} style={galleryStyle(ctx.settings)}>
      <Routes>
        <Route path="/" element={<DiscoverPage ctx={ctx} />} />
        <Route path="/following" element={<FeedPage ctx={ctx} mode="following" />} />
        <Route path="/liked" element={<FeedPage ctx={ctx} mode="liked" />} />
        <Route path="/media/:mediaId" element={<MediaDetailPage ctx={ctx} />} />
        <Route path="/collections" element={<CollectionsPage ctx={ctx} />} />
        <Route path="/users" element={<UsersPage ctx={ctx} />} />
        <Route path="/users/:username" element={<ProfilePage ctx={ctx} />} />
        <Route path="/friends" element={<FriendsPage ctx={ctx} />} />
        <Route path="/messages" element={<MessagesPage ctx={ctx} />} />
        <Route path="/studio" element={<StudioPage ctx={ctx} />} />
        <Route path="/profile" element={ctx.user ? <Navigate to={`/users/${ctx.user.username}`} replace /> : <Navigate to="/login" replace />} />
        <Route path="/upload" element={<UploadPage ctx={ctx} />} />
        <Route path="/settings" element={<SettingsPage ctx={ctx} />} />
        <Route path="/login" element={<AuthPage ctx={ctx} />} />
        <Route path="*" element={<NotFound />} />
      </Routes>
      {!bootDismissed ? (
        <GalleryBootOverlay
          authenticated={Boolean(token && user)}
          leaving={bootLeaving}
          phase={bootPhase}
          tip={BOOT_TIPS[bootTipIndex]}
        />
      ) : null}
      {toast ? <div className={`toast toast-${toast.kind}`} role="status">{toast.message}</div> : null}
    </Shell>
  );
}

function GalleryBootOverlay({ phase, tip, authenticated, leaving }) {
  return (
    <div
      aria-busy="true"
      aria-live="polite"
      className={`gallery-loading-screen ${leaving ? "is-leaving" : ""}`}
      role="status"
    >
      <div className="gallery-loading-backdrop" />
      <section className="gallery-loading-panel">
        <div className="gallery-loading-hero">
          <div className="gallery-loading-lightbox" aria-hidden="true">
            <span className="gallery-loading-frame frame-back" />
            <span className="gallery-loading-frame frame-mid" />
            <span className="gallery-loading-frame frame-front" />
            <span className="gallery-loading-beam" />
            <span className="gallery-loading-core" />
          </div>
          <div className="gallery-loading-copy">
            <span className="gallery-loading-kicker">Image Gallery // Curated Media Deck</span>
            <strong>{phase}</strong>
            <p>
              {authenticated
                ? "Your studio, feed, and profile surfaces are loading behind the glass while previews and search caches come online."
                : "The public gallery deck is indexing categories, tags, and featured posts before it fades in."}
            </p>
          </div>
        </div>
        <div className="gallery-loading-status-grid">
          <article>
            <span>Deck</span>
            <strong>{authenticated ? "Signed In" : "Guest View"}</strong>
            <small>{authenticated ? "Personal feed and studio routes are being prepared." : "Public browsing tools are coming online."}</small>
          </article>
          <article>
            <span>Preview Lab</span>
            <strong>Hydrating</strong>
            <small>Thumb caches, user search, and category rails are being staged in the background.</small>
          </article>
          <article>
            <span>Tip Deck</span>
            <strong>Rotating</strong>
            <small>{tip}</small>
          </article>
        </div>
        <div className="gallery-loading-progress" aria-hidden="true">
          <span />
        </div>
      </section>
    </div>
  );
}

export default App;
