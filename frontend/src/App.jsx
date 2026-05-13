import { useCallback, useEffect, useMemo, useState } from "react";
import { Navigate, Route, Routes, useNavigate } from "react-router-dom";
import { apiFetch, cachedApiFetch, clearApiCache, readStoredUser, readToken, writeStoredUser, writeToken } from "./api.js";
import { Shell } from "./components/Shell.jsx";
import { NotFound } from "./components/ui.jsx";
import { DEFAULT_SETTINGS } from "./config.js";
import { AuthPage } from "./pages/AuthPage.jsx";
import { CollectionsPage } from "./pages/CollectionsPage.jsx";
import { DiscoverPage } from "./pages/DiscoverPage.jsx";
import { FeedPage } from "./pages/FeedPage.jsx";
import { FriendsPage } from "./pages/FriendsPage.jsx";
import { MediaDetailPage } from "./pages/MediaDetailPage.jsx";
import { ProfilePage } from "./pages/ProfilePage.jsx";
import { SettingsPage } from "./pages/SettingsPage.jsx";
import { StudioPage } from "./pages/StudioPage.jsx";
import { UploadPage } from "./pages/UploadPage.jsx";
import { UsersPage } from "./pages/UsersPage.jsx";

function App() {
  const navigate = useNavigate();
  const [token, setTokenState] = useState(() => readToken());
  const [user, setUserState] = useState(() => readStoredUser());
  const [lookups, setLookups] = useState({ categories: [], tags: [], live: null });
  const [toast, setToast] = useState(null);

  const showToast = useCallback((message, kind = "info") => {
    setToast({ message, kind, id: Date.now() });
  }, []);

  const setSessionUser = useCallback((nextUser) => {
    setUserState(nextUser);
    writeStoredUser(nextUser);
  }, []);

  const logout = useCallback((withNotice = true) => {
    writeToken("");
    writeStoredUser(null);
    clearApiCache();
    setTokenState("");
    setUserState(null);
    if (withNotice) showToast("Signed out.", "success");
    navigate("/");
  }, [navigate, showToast]);

  const loginWith = useCallback((payload) => {
    writeToken(payload.token);
    writeStoredUser(payload.user);
    clearApiCache();
    setTokenState(payload.token);
    setUserState(payload.user);
    showToast(`Welcome, ${payload.user?.display_name || payload.user?.username || "friend"}.`, "success");
    navigate("/");
  }, [navigate, showToast]);

  const refreshMe = useCallback(async () => {
    if (!readToken()) {
      setSessionUser(null);
      return;
    }
    try {
      const data = await apiFetch("/api/me");
      setSessionUser(data.user);
    } catch (error) {
      if (error.status === 401) logout(false);
    }
  }, [logout, setSessionUser]);

  const refreshLookups = useCallback(async () => {
    const [categories, tags, live] = await Promise.allSettled([
      cachedApiFetch("/api/categories", { ttl: 10 * 60_000, staleTtl: 60 * 60_000, storage: "local" }),
      cachedApiFetch("/api/tags", { ttl: 10 * 60_000, staleTtl: 60 * 60_000, storage: "local" }),
      cachedApiFetch("/api/live/checks", { ttl: 30_000, staleTtl: 5 * 60_000 }),
    ]);
    setLookups({
      categories: categories.status === "fulfilled" ? categories.value.categories || [] : [],
      tags: tags.status === "fulfilled" ? tags.value.tags || [] : [],
      live: live.status === "fulfilled" ? live.value : null,
    });
  }, []);

  useEffect(() => {
    refreshMe();
    refreshLookups();
  }, [refreshMe, refreshLookups]);

  useEffect(() => {
    if (!toast) return undefined;
    const timer = window.setTimeout(() => setToast(null), 3600);
    return () => window.clearTimeout(timer);
  }, [toast]);

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
    <Shell ctx={ctx}>
      <Routes>
        <Route path="/" element={<DiscoverPage ctx={ctx} />} />
        <Route path="/following" element={<FeedPage ctx={ctx} mode="following" />} />
        <Route path="/liked" element={<FeedPage ctx={ctx} mode="liked" />} />
        <Route path="/media/:mediaId" element={<MediaDetailPage ctx={ctx} />} />
        <Route path="/collections" element={<CollectionsPage ctx={ctx} />} />
        <Route path="/users" element={<UsersPage ctx={ctx} />} />
        <Route path="/users/:username" element={<ProfilePage ctx={ctx} />} />
        <Route path="/friends" element={<FriendsPage ctx={ctx} />} />
        <Route path="/studio" element={<StudioPage ctx={ctx} />} />
        <Route path="/profile" element={ctx.user ? <Navigate to={`/users/${ctx.user.username}`} replace /> : <Navigate to="/login" replace />} />
        <Route path="/upload" element={<UploadPage ctx={ctx} />} />
        <Route path="/settings" element={<SettingsPage ctx={ctx} />} />
        <Route path="/login" element={<AuthPage ctx={ctx} />} />
        <Route path="*" element={<NotFound />} />
      </Routes>
      {toast ? <div className={`toast toast-${toast.kind}`} role="status">{toast.message}</div> : null}
    </Shell>
  );
}

export default App;
