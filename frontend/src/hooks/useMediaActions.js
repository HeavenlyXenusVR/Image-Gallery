import { useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { apiFetch, clearApiCache, resolveApiUrl } from "../api.js";

export function useMediaActions(ctx, onItemUpdated) {
  const navigate = useNavigate();
  const requireAuth = useCallback(() => {
    if (ctx.user) return true;
    navigate("/login");
    return false;
  }, [ctx.user, navigate]);

  const update = useCallback((item) => {
    clearApiCache();
    onItemUpdated?.(item);
  }, [onItemUpdated]);

  return {
    async toggleLike(item) {
      if (!requireAuth()) return;
      try {
        const data = await apiFetch(`/api/media/${item.id}/like`, {
          method: "POST",
          body: JSON.stringify({ liked: !item.liked_by_me }),
        });
        update(data.media);
      } catch (error) {
        ctx.showToast(error.message, "error");
      }
    },
    async toggleBookmark(item) {
      if (!requireAuth()) return;
      try {
        const data = await apiFetch(`/api/media/${item.id}/bookmark`, {
          method: "POST",
          body: JSON.stringify({ bookmarked: !item.bookmarked_by_me }),
        });
        update(data.media);
      } catch (error) {
        ctx.showToast(error.message, "error");
      }
    },
    download(item) {
      if (!item.downloads_enabled && Number(item.user_id) !== Number(ctx.user?.id)) {
        ctx.showToast("Downloads are disabled for this post.", "error");
        return;
      }
      window.open(item.download_url || `/api/media/${item.id}/download`, "_blank", "noopener,noreferrer");
    },
    async copyAddress(item) {
      const raw = item?.url || item?.preview_url || item?.thumb_url || `/api/media/${item.id}/file`;
      try {
        const url = await resolveApiUrl(raw);
        await navigator.clipboard.writeText(url || raw);
        ctx.showToast("Media address copied.", "success");
      } catch (error) {
        ctx.showToast(error.message || "Could not copy media address.", "error");
      }
    },
    async copyPageLink(item) {
      try {
        const basename = String(window.IMAGE_GALLERY_BASENAME || "").replace(/\/+$/, "");
        const url = new URL(`${basename}/media/${item.id}`, window.location.origin);
        await navigator.clipboard.writeText(url.toString());
        ctx.showToast("Post link copied.", "success");
      } catch (error) {
        ctx.showToast(error.message || "Could not copy post link.", "error");
      }
    },
    async openOriginal(item) {
      const raw = item?.url || item?.preview_url || `/api/media/${item.id}/file`;
      const url = await resolveApiUrl(raw).catch(() => raw);
      window.open(url, "_blank", "noopener,noreferrer");
    },
  };
}
