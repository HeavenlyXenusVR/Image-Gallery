import { useCallback, useEffect, useMemo, useState } from "react";
import { Download, Eye, RefreshCw, Tag, Trash2 } from "lucide-react";
import { apiFetch, apiFetchBlob, clearApiCache, downloadBlob } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { StudioItem } from "../components/media.jsx";
import { EmptyState, Metric, Page, RequireLogin, SkeletonList } from "../components/ui.jsx";
import { replaceMedia } from "../utils/media.js";

export function StudioPage({ ctx }) {
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [selectedIds, setSelectedIds] = useState(() => new Set());
  const [downloading, setDownloading] = useState(false);
  const [bulkBusy, setBulkBusy] = useState(false);
  const [bulkVisibility, setBulkVisibility] = useState("public");
  const [bulkTag, setBulkTag] = useState("");

  const showToast = ctx.showToast;
  const userId = ctx.user?.id;

  const toggleSelect = useCallback((id) => {
    setSelectedIds((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);

  const clearSelection = useCallback(() => setSelectedIds(new Set()), []);

  const downloadSelected = useCallback(async () => {
    if (!selectedIds.size) return;
    setDownloading(true);
    try {
      const { blob, filename } = await apiFetchBlob("/api/media/download-batch", {
        method: "POST",
        body: JSON.stringify({ media_ids: Array.from(selectedIds) }),
      });
      downloadBlob(blob, filename.endsWith(".zip") ? filename : "gallery-selection.zip");
      showToast(`Downloaded ${selectedIds.size} post${selectedIds.size === 1 ? "" : "s"}.`, "success");
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setDownloading(false);
    }
  }, [selectedIds, showToast]);

  const summarizeBulkResults = useCallback((results, successVerb) => {
    const ok = results.filter((row) => row.ok).length;
    const failed = results.length - ok;
    if (ok) showToast(`${successVerb} ${ok} post${ok === 1 ? "" : "s"}.${failed ? ` ${failed} failed.` : ""}`, failed ? "info" : "success");
    else showToast("No posts were updated.", "error");
  }, [showToast]);

  const bulkSetVisibility = useCallback(async () => {
    if (!selectedIds.size) return;
    setBulkBusy(true);
    try {
      const data = await apiFetch("/api/media/bulk", {
        method: "POST",
        body: JSON.stringify({ ids: Array.from(selectedIds), patch: { visibility: bulkVisibility } }),
      });
      clearApiCache();
      summarizeBulkResults(data.results || [], "Updated");
      await loadStudio();
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setBulkBusy(false);
    }
  }, [selectedIds, bulkVisibility, summarizeBulkResults, showToast]);

  const bulkAddTag = useCallback(async () => {
    const tag = bulkTag.trim();
    if (!selectedIds.size || !tag) return;
    setBulkBusy(true);
    try {
      const data = await apiFetch("/api/media/bulk", {
        method: "POST",
        body: JSON.stringify({ ids: Array.from(selectedIds), patch: { add_tag: tag } }),
      });
      clearApiCache();
      summarizeBulkResults(data.results || [], "Tagged");
      setBulkTag("");
      await loadStudio();
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setBulkBusy(false);
    }
  }, [selectedIds, bulkTag, summarizeBulkResults, showToast]);

  const bulkDelete = useCallback(async () => {
    if (!selectedIds.size) return;
    if (!window.confirm(`Delete ${selectedIds.size} selected post${selectedIds.size === 1 ? "" : "s"}? This cannot be undone from here.`)) return;
    setBulkBusy(true);
    try {
      const data = await apiFetch("/api/media/bulk-delete", {
        method: "POST",
        body: JSON.stringify({ ids: Array.from(selectedIds) }),
      });
      clearApiCache();
      summarizeBulkResults(data.results || [], "Deleted");
      const removedIds = new Set((data.results || []).filter((row) => row.ok).map((row) => Number(row.id)));
      setItems((rows) => rows.filter((row) => !removedIds.has(Number(row.id))));
      setSelectedIds(new Set());
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setBulkBusy(false);
    }
  }, [selectedIds, summarizeBulkResults, showToast]);

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
      {selectedIds.size ? (
        <div className="studio-bulk-bar">
          <span>{selectedIds.size} selected</span>
          <button type="button" onClick={downloadSelected} disabled={downloading || bulkBusy}>
            <Download size={16} />{downloading ? "Zipping…" : "Download selected"}
          </button>
          <select value={bulkVisibility} onChange={(event) => setBulkVisibility(event.target.value)} disabled={bulkBusy} aria-label="Bulk visibility">
            <option value="public">Public</option>
            <option value="unlisted">Unlisted</option>
            <option value="private">Private</option>
          </select>
          <button type="button" onClick={bulkSetVisibility} disabled={bulkBusy}>
            <Eye size={16} />Set visibility
          </button>
          <input
            value={bulkTag}
            onChange={(event) => setBulkTag(event.target.value)}
            placeholder="Add tag to selected"
            maxLength={32}
            disabled={bulkBusy}
            aria-label="Tag to add to selected posts"
          />
          <button type="button" onClick={bulkAddTag} disabled={bulkBusy || !bulkTag.trim()}>
            <Tag size={16} />Add tag
          </button>
          <button type="button" className="danger" onClick={bulkDelete} disabled={bulkBusy}>
            <Trash2 size={16} />Delete selected
          </button>
          <button type="button" onClick={clearSelection} disabled={bulkBusy}>Clear</button>
        </div>
      ) : null}
      {loading ? <SkeletonList /> : (
        <div className="studio-list">
          {items.map((item) => (
            <StudioItem
              ctx={ctx}
              item={item}
              key={item.id}
              selected={selectedIds.has(item.id)}
              onToggleSelect={() => toggleSelect(item.id)}
              onChanged={(updated) => setItems((rows) => replaceMedia(rows, updated))}
              onRemoved={(id) => {
                setItems((rows) => rows.filter((row) => Number(row.id) !== Number(id)));
                setSelectedIds((current) => {
                  if (!current.has(id)) return current;
                  const next = new Set(current);
                  next.delete(id);
                  return next;
                });
              }}
            />
          ))}
        </div>
      )}
      {!loading && !items.length ? <EmptyState title="No uploads yet" /> : null}
    </Page>
  );
}
