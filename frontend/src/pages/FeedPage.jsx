import { useEffect, useState } from "react";
import { cachedApiFetch, prefetchApi, toQuery } from "../api.js";
import { PAGE_SIZE } from "../config.js";
import { MediaGrid } from "../components/media.jsx";
import { Notice, Page, Pager, RequireLogin } from "../components/ui.jsx";
import { preloadMediaAssets, replaceMedia } from "../utils/media.js";

export function FeedPage({ ctx, mode }) {
  const [page, setPage] = useState(1);
  const [items, setItems] = useState([]);
  const [hasNext, setHasNext] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const title = mode === "liked" ? "Liked" : "Following";
  const endpoint = mode === "liked" ? "/api/me/likes" : "/api/feed/following";

  useEffect(() => {
    if (!ctx.user) return;
    let ignore = false;
    async function load() {
      setLoading(true);
      setError("");
      try {
        const data = await cachedApiFetch(`${endpoint}${toQuery({ limit: PAGE_SIZE + 1, offset: (page - 1) * PAGE_SIZE })}`, { ttl: 20_000, staleTtl: 3 * 60_000 });
        if (ignore) return;
        const rows = data.media || [];
        setItems(rows.slice(0, PAGE_SIZE));
        setHasNext(rows.length > PAGE_SIZE);
        preloadMediaAssets(rows, { limit: 6 });
        if (rows.length > PAGE_SIZE) {
          prefetchApi(`${endpoint}${toQuery({ limit: PAGE_SIZE + 1, offset: page * PAGE_SIZE })}`, { ttl: 30_000, staleTtl: 3 * 60_000 });
        }
      } catch (fetchError) {
        if (ignore) return;
        setError(fetchError.message);
      } finally {
        if (!ignore) setLoading(false);
      }
    }
    load();
    return () => { ignore = true; };
  }, [ctx.user, endpoint, page]);

  if (!ctx.user) return <RequireLogin />;
  return (
    <Page title={title} eyebrow="Feed">
      {error ? <Notice kind="error">{error}</Notice> : null}
      <MediaGrid ctx={ctx} items={items} loading={loading} emptyTitle={mode === "liked" ? "No liked posts yet" : "No following posts yet"} onItemUpdated={(item) => setItems((rows) => replaceMedia(rows, item))} />
      <Pager page={page} hasNext={hasNext} loading={loading} onPage={setPage} />
    </Page>
  );
}
