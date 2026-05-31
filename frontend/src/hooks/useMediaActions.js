import { useCallback, useRef } from "react";
import { useNavigate } from "react-router-dom";
import { apiFetch, clearApiCache, resolveApiUrl } from "../api.js";

export function useMediaActions(ctx, onItemUpdated) {
  const navigate = useNavigate();
  // Stable refs so action callbacks never go stale without triggering re-renders
  const ctxRef = useRef(ctx);
  ctxRef.current = ctx;
  const onItemUpdatedRef = useRef(onItemUpdated);
  onItemUpdatedRef.current = onItemUpdated;

  const requireAuth = useCallback(() => {
    if (ctxRef.current.user) return true;
    navigate("/login");
    return false;
  }, [navigate]);

  const update = useCallback((item) => {
    clearApiCache();
    onItemUpdatedRef.current?.(item);
  }, []);

  const toggleLike = useCallback(async (item) => {
    if (!requireAuth()) return;
    try {
      const data = await apiFetch(`/api/media/${item.id}/like`, {
        method: "POST",
        body: JSON.stringify({ liked: !item.liked_by_me }),
      });
      update(data.media);
    } catch (error) {
      ctxRef.current.showToast(error.message, "error");
    }
  }, [requireAuth, update]);

  const toggleBookmark = useCallback(async (item) => {
    if (!requireAuth()) return;
    try {
      const data = await apiFetch(`/api/media/${item.id}/bookmark`, {
        method: "POST",
        body: JSON.stringify({ bookmarked: !item.bookmarked_by_me }),
      });
      update(data.media);
    } catch (error) {
      ctxRef.current.showToast(error.message, "error");
    }
  }, [requireAuth, update]);

  const download = useCallback((item) => {
    const ctx = ctxRef.current;
    if (!item.downloads_enabled && Number(item.user_id) !== Number(ctx.user?.id)) {
      ctx.showToast("Downloads are disabled for this post.", "error");
      return;
    }
    window.open(item.download_url || `/api/media/${item.id}/download`, "_blank", "noopener,noreferrer");
  }, []);

  const copyAddress = useCallback(async (item) => {
    const raw = item?.url || item?.preview_url || item?.thumb_url || `/api/media/${item.id}/file`;
    try {
      const url = await resolveApiUrl(raw);
      await navigator.clipboard.writeText(url || raw);
      ctxRef.current.showToast("Media address copied.", "success");
    } catch (error) {
      ctxRef.current.showToast(error.message || "Could not copy media address.", "error");
    }
  }, []);

  const copyPageLink = useCallback(async (item) => {
    try {
      const basename = String(window.IMAGE_GALLERY_BASENAME || "").replace(/\/+$/, "");
      const url = new URL(`${basename}/media/${item.id}`, window.location.origin);
      await navigator.clipboard.writeText(url.toString());
      ctxRef.current.showToast("Post link copied.", "success");
    } catch (error) {
      ctxRef.current.showToast(error.message || "Could not copy post link.", "error");
    }
  }, []);

  const openOriginal = useCallback(async (item) => {
    const raw = item?.url || item?.preview_url || `/api/media/${item.id}/file`;
    const url = await resolveApiUrl(raw).catch(() => raw);
    window.open(url, "_blank", "noopener,noreferrer");
  }, []);

  return { toggleLike, toggleBookmark, download, copyAddress, copyPageLink, openOriginal };
}
