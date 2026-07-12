import { useCallback, useEffect, useState } from "react";
import { RefreshCw, TrendingUp } from "lucide-react";
import { apiFetch, cachedApiFetch, clearApiCache, toQuery } from "../api.js";
import { MediaGrid } from "../components/media.jsx";
import { Notice, Page, Segmented } from "../components/ui.jsx";
import { preloadMediaAssets, replaceMedia } from "../utils/media.js";

const WINDOWS = [["1", "24h"], ["7", "7 days"], ["30", "30 days"]];

export function TrendingPage({ ctx }) {
  const [days, setDays] = useState("7");
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const handleItemUpdated = useCallback((item) => setItems((rows) => replaceMedia(rows, item)), []);

  const loadTrending = useCallback(async ({ fresh = false } = {}) => {
    setLoading(true);
    setError("");
    try {
      const path = `/api/media/trending${toQuery({ days, limit: 30 })}`;
      const data = fresh
        ? await apiFetch(path)
        : await cachedApiFetch(path, { ttl: 30_000, staleTtl: 5 * 60_000 });
      const rows = data.media || [];
      setItems(rows);
      preloadMediaAssets(rows, { limit: 6 });
    } catch (fetchError) {
      setError(fetchError.message);
      setItems([]);
    } finally {
      setLoading(false);
    }
  }, [days]);

  useEffect(() => {
    loadTrending();
  }, [loadTrending]);

  return (
    <Page
      title="Trending"
      eyebrow="Discover"
      lede="Posts ranked by views, likes, and comments within the selected window."
      actions={(
        <>
          <Segmented value={days} onChange={setDays} options={WINDOWS} />
          <button type="button" onClick={() => { clearApiCache("/api/media/trending"); loadTrending({ fresh: true }); }} disabled={loading}>
            <RefreshCw size={16} />Refresh
          </button>
        </>
      )}
    >
      {error ? <Notice kind="error">{error}</Notice> : null}
      {!loading && !items.length && !error ? (
        <div className="empty-state">
          <TrendingUp size={24} />
          <h2>Nothing trending in this window yet</h2>
        </div>
      ) : (
        <MediaGrid ctx={ctx} items={items} loading={loading} emptyTitle="Nothing trending yet" onItemUpdated={handleItemUpdated} onOpen={ctx.openLightbox} />
      )}
    </Page>
  );
}
