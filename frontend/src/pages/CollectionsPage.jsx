import { useCallback, useEffect, useRef, useState } from "react";
import { Film, Image as ImageIcon, PlusCircle, RefreshCw, Save, Search } from "lucide-react";
import { apiFetch, cachedApiFetch, clearApiCache, toQuery } from "../api.js";
import { MediaGrid } from "../components/media.jsx";
import { CollectionCover, EmptyState, Notice, Page, ResilientImage, Segmented, SkeletonList } from "../components/ui.jsx";
import { formatDate } from "../utils/format.js";
import { mediaImageSources, preloadMediaAssets, replaceMedia } from "../utils/media.js";

export function CollectionsPage({ ctx }) {
  const [mine, setMine] = useState(false);
  const [collections, setCollections] = useState([]);
  const [selected, setSelected] = useState(null);
  const [media, setMedia] = useState([]);
  const [form, setForm] = useState({ name: "", description: "", is_public: true });
  const [picker, setPicker] = useState({ q: "", loading: false, results: [] });
  const [addingId, setAddingId] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const didAutoOpen = useRef(false);

  const showToast = ctx.showToast;

  const openCollection = useCallback(async (id, { fresh = false } = {}) => {
    try {
      const data = fresh
        ? await apiFetch(`/api/collections/${id}`)
        : await cachedApiFetch(`/api/collections/${id}`, { ttl: 20_000, staleTtl: 5 * 60_000 });
      setSelected(data.collection);
      setMedia(data.media || []);
      preloadMediaAssets(data.media || [], { limit: 6 });
    } catch (openError) {
      showToast(openError.message, "error");
    }
  }, [showToast]);

  const loadCollections = useCallback(async ({ fresh = false } = {}) => {
    setLoading(true);
    setError("");
    try {
      const path = `/api/collections${mine ? "?mine=true" : ""}`;
      const data = fresh
        ? await apiFetch(path)
        : await cachedApiFetch(path, { ttl: 20_000, staleTtl: 5 * 60_000 });
      const rows = data.collections || [];
      setCollections(rows);
      if (!didAutoOpen.current && rows[0]) {
        didAutoOpen.current = true;
        openCollection(rows[0].id, { fresh });
      }
    } catch (fetchError) {
      setError(fetchError.message);
    } finally {
      setLoading(false);
    }
  }, [mine, openCollection]);

  useEffect(() => {
    didAutoOpen.current = false;
    setSelected(null);
    setMedia([]);
    setPicker((current) => ({ ...current, results: [] }));
    loadCollections();
  }, [mine, loadCollections]);

  async function createCollection(event) {
    event.preventDefault();
    try {
      const data = await apiFetch("/api/collections", {
        method: "POST",
        body: JSON.stringify(form),
      });
      clearApiCache();
      setForm({ name: "", description: "", is_public: true });
      setMine(true);
      setCollections((rows) => [data.collection, ...rows]);
      await openCollection(data.collection.id, { fresh: true });
    } catch (createError) {
      ctx.showToast(createError.message, "error");
    }
  }

  async function searchExistingMedia(event) {
    event?.preventDefault();
    if (!selected) return;
    setPicker((current) => ({ ...current, loading: true }));
    try {
      const data = await apiFetch(`/api/media${toQuery({ q: picker.q.trim(), sort: "new", limit: 18 })}`);
      const existingIds = new Set(media.map((item) => Number(item.id)));
      const rows = (data.media || []).filter((item) => !existingIds.has(Number(item.id))).slice(0, 12);
      setPicker((current) => ({ ...current, loading: false, results: rows }));
      preloadMediaAssets(rows, { limit: 4, width: 260 });
    } catch (searchError) {
      setPicker((current) => ({ ...current, loading: false }));
      ctx.showToast(searchError.message, "error");
    }
  }

  async function addExistingMedia(item) {
    if (!selected?.id || !item?.id) return;
    setAddingId(String(item.id));
    try {
      await apiFetch(`/api/collections/${selected.id}/items`, {
        method: "POST",
        body: JSON.stringify({ media_id: item.id, saved: true }),
      });
      clearApiCache();
      ctx.showToast(`Added ${item.title || "post"} to ${selected.name}.`, "success");
      setPicker((current) => ({ ...current, results: current.results.filter((row) => Number(row.id) !== Number(item.id)) }));
      await openCollection(selected.id, { fresh: true });
      await loadCollections({ fresh: true });
    } catch (addError) {
      ctx.showToast(addError.message, "error");
    } finally {
      setAddingId("");
    }
  }

  const canEditSelected = Boolean(ctx.user && selected && Number(selected.user_id) === Number(ctx.user.id));
  const handleItemUpdated = useCallback((item) => setMedia((rows) => replaceMedia(rows, item)), []);

  return (
    <Page title="Collections" eyebrow="Stacks" actions={(
      <>
        <Segmented value={mine ? "mine" : "community"} onChange={(value) => setMine(value === "mine")} options={[["community", "Community"], ["mine", "Mine"]]} />
        <button type="button" onClick={() => loadCollections({ fresh: true })} disabled={loading}><RefreshCw size={16} />Refresh</button>
      </>
    )}>
      {error ? <Notice kind="error">{error}</Notice> : null}
      <section className="split-view">
        <aside className="list-panel">
          {ctx.user && mine ? (
            <form className="stacked-form create-box" onSubmit={createCollection}>
              <input value={form.name} onChange={(event) => setForm((current) => ({ ...current, name: event.target.value }))} placeholder="Collection name" maxLength={100} required />
              <input value={form.description} onChange={(event) => setForm((current) => ({ ...current, description: event.target.value }))} placeholder="Description" maxLength={500} />
              <label className="check-row"><input checked={form.is_public} onChange={(event) => setForm((current) => ({ ...current, is_public: event.target.checked }))} type="checkbox" />Public</label>
              <button type="submit"><Save size={16} />Create</button>
            </form>
          ) : null}
          {loading ? <SkeletonList /> : collections.map((collection) => (
            <button className={`collection-row ${selected?.id === collection.id ? "active" : ""}`} key={collection.id} type="button" onClick={() => openCollection(collection.id)}>
              <CollectionCover collection={collection} />
              <span><strong>{collection.name}</strong><small>{collection.item_count || 0} posts</small></span>
            </button>
          ))}
          {!loading && !collections.length ? <EmptyState title="No collections" /> : null}
        </aside>
        <section className="detail-panel collection-detail-panel">
          {selected ? (
            <>
              <div className="section-head collection-detail-head">
                <div><h2>{selected.name}</h2><p>{selected.description || "No description"}</p></div>
                <span>{selected.is_public ? "Public" : "Private"}</span>
              </div>
              {canEditSelected ? (
                <section className="collection-add-panel">
                  <div>
                    <h3>Add existing posts</h3>
                    <p>Search your visible gallery posts and drop them into this collection without re-uploading anything.</p>
                  </div>
                  <form className="collection-add-search" onSubmit={searchExistingMedia}>
                    <label className="input-with-icon wide">
                      <Search size={16} />
                      <input value={picker.q} onChange={(event) => setPicker((current) => ({ ...current, q: event.target.value }))} placeholder="Search title, tags, category, uploader…" />
                    </label>
                    <button type="submit" disabled={picker.loading}><Search size={16} />{picker.loading ? "Searching" : "Search"}</button>
                  </form>
                  {picker.results.length ? (
                    <div className="collection-candidate-grid">
                      {picker.results.map((item) => (
                        <article className="collection-candidate" key={item.id}>
                          <ResilientImage sources={mediaImageSources(item, { width: 260, previewSize: "card" })} diagnostics={{ mediaId: item.id, mediaKind: item.media_kind, context: "collection-picker" }} alt="" loading="lazy" decoding="async" />
                          <div>
                            <strong>{item.title || "Untitled"}</strong>
                            <small>{item.media_kind === "video" ? <Film size={13} /> : <ImageIcon size={13} />}{item.category_name || "Unsorted"} · {formatDate(item.created_at || item.uploaded_at)}</small>
                          </div>
                          <button type="button" onClick={() => addExistingMedia(item)} disabled={addingId === String(item.id)}><PlusCircle size={16} />{addingId === String(item.id) ? "Adding" : "Add"}</button>
                        </article>
                      ))}
                    </div>
                  ) : !picker.loading && picker.q ? <p className="muted-copy">No matching posts outside this collection.</p> : null}
                </section>
              ) : null}
              <MediaGrid ctx={ctx} items={media} emptyTitle="This collection is empty" onItemUpdated={handleItemUpdated} />
            </>
          ) : <EmptyState title="Select a collection" />}
        </section>
      </section>
    </Page>
  );
}
