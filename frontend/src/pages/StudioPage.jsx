import { useCallback, useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";
import { apiFetch } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { StudioItem } from "../components/media.jsx";
import { EmptyState, Metric, Page, RequireLogin, SkeletonList } from "../components/ui.jsx";
import { replaceMedia } from "../utils/media.js";

export function StudioPage({ ctx }) {
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);

  const showToast = ctx.showToast;
  const userId = ctx.user?.id;

  const loadStudio = useCallback(async ({ background = false } = {}) => {
    if (!userId) return;
    if (!background) setLoading(true);
    try {
      const data = await apiFetch("/api/me/media?include_deleted=true");
      setItems(data.media || []);
    } catch (error) {
      if (!background) showToast(error.message, "error");
    } finally {
      if (!background) setLoading(false);
    }
  }, [userId, showToast]);

  useEffect(() => {
    loadStudio();
  }, [loadStudio]);

  useLiveRefresh(() => loadStudio({ background: true }), { enabled: Boolean(ctx.user), interval: 25_000 });

  if (!ctx.user) return <RequireLogin />;
  const totals = items.reduce((acc, item) => ({
    views: acc.views + Number(item.views || 0),
    likes: acc.likes + Number(item.likes || item.like_count || 0),
    downloads: acc.downloads + Number(item.downloads || item.download_count || 0),
  }), { views: 0, likes: 0, downloads: 0 });

  return (
    <Page title="Studio" eyebrow="Manage" actions={<button type="button" onClick={() => loadStudio()} disabled={loading}><RefreshCw size={16} />Refresh</button>}>
      <div className="stat-strip">
        <Metric label="Posts" value={items.length} />
        <Metric label="Views" value={totals.views} />
        <Metric label="Likes" value={totals.likes} />
        <Metric label="Downloads" value={totals.downloads} />
      </div>
      {loading ? <SkeletonList /> : (
        <div className="studio-list">
          {items.map((item) => <StudioItem ctx={ctx} item={item} key={item.id} onChanged={(updated) => setItems((rows) => replaceMedia(rows, updated))} onRemoved={(id) => setItems((rows) => rows.filter((row) => Number(row.id) !== Number(id)))} />)}
        </div>
      )}
      {!loading && !items.length ? <EmptyState title="No uploads yet" /> : null}
    </Page>
  );
}
