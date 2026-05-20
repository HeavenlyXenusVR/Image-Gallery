import { useCallback, useEffect, useState } from "react";
import { apiFetch, cachedApiFetch, prefetchApi, toQuery } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { PAGE_SIZE } from "../config.js";
import { MediaGrid } from "../components/media.jsx";
import { Notice, Page, Pager, RequireLogin } from "../components/ui.jsx";
import { preloadMediaAssets, replaceMedia } from "../utils/media.js";

function pageSizeFor(settings) {
  const parsed = Number(settings?.items_per_page);
  if (!Number.isFinite(parsed)) return PAGE_SIZE;
  return Math.min(60, Math.max(12, Math.round(parsed)));
}

export function FeedPage({ ctx, mode }) {
  const [page, setPage] = useState(1);
  const [items, setItems] = useState([]);
  const [hasNext, setHasNext] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const title = mode === "liked" ? "Liked" : "Following";
  const endpoint = mode === "liked" ? "/api/me/likes" : "/api/feed/following";
  const pageSize = pageSizeFor(ctx.settings);

  const loadFeed = useCallback(({ background = false } = {}) => {
    if (!ctx.user) return Promise.resolve();
    return (async () => {
      if (!background) setLoading(true);
      if (!background) setError("");
      try {
        const path = `${endpoint}${toQuery({ limit: pageSize + 1, offset: (page - 1) * pageSize })}`;
        const data = background
          ? await apiFetch(path)
          : await cachedApiFetch(path, { ttl: 20_000, staleTtl: 3 * 60_000 });
        const rows = data.media || [];
        setItems(rows.slice(0, pageSize));
        setHasNext(rows.length > pageSize);
        preloadMediaAssets(rows, { limit: 6 });
        if (rows.length > pageSize) {
          prefetchApi(`${endpoint}${toQuery({ limit: pageSize + 1, offset: page * pageSize })}`, { ttl: 30_000, staleTtl: 3 * 60_000 });
        }
      } catch (fetchError) {
        if (!background) setError(fetchError.message);
      } finally {
        if (!background) setLoading(false);
      }
    })();
  }, [ctx.user, endpoint, page, pageSize]);

  useEffect(() => {
    loadFeed();
  }, [loadFeed]);
  useLiveRefresh(() => loadFeed({ background: true }), { enabled: Boolean(ctx.user) && page === 1, interval: 22_000 });

  if (!ctx.user) return <RequireLogin />;
  return (
    <Page title={title} eyebrow="Feed">
      {error ? <Notice kind="error">{error}</Notice> : null}
      <MediaGrid ctx={ctx} items={items} loading={loading} emptyTitle={mode === "liked" ? "No liked posts yet" : "No following posts yet"} onItemUpdated={(item) => setItems((rows) => replaceMedia(rows, item))} />
      <Pager page={page} hasNext={hasNext} loading={loading} onPage={setPage} />
    </Page>
  );
}
