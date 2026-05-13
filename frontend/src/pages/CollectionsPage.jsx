import { useCallback, useEffect, useState } from "react";
import { RefreshCw, Save } from "lucide-react";
import { apiFetch, cachedApiFetch } from "../api.js";
import { MediaGrid } from "../components/media.jsx";
import { CollectionCover, EmptyState, Notice, Page, Segmented, SkeletonList } from "../components/ui.jsx";
import { preloadMediaAssets, replaceMedia } from "../utils/media.js";

export function CollectionsPage({ ctx }) {
  const [mine, setMine] = useState(false);
  const [collections, setCollections] = useState([]);
  const [selected, setSelected] = useState(null);
  const [media, setMedia] = useState([]);
  const [form, setForm] = useState({ name: "", description: "", is_public: true });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const loadCollections = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const data = await cachedApiFetch(`/api/collections${mine ? "?mine=true" : ""}`, { ttl: 20_000, staleTtl: 5 * 60_000 });
      setCollections(data.collections || []);
      if (!selected && data.collections?.[0]) openCollection(data.collections[0].id);
    } catch (fetchError) {
      setError(fetchError.message);
    } finally {
      setLoading(false);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mine]);

  useEffect(() => {
    setSelected(null);
    setMedia([]);
    loadCollections();
  }, [mine, loadCollections]);

  async function openCollection(id) {
    try {
      const data = await cachedApiFetch(`/api/collections/${id}`, { ttl: 20_000, staleTtl: 5 * 60_000 });
      setSelected(data.collection);
      setMedia(data.media || []);
      preloadMediaAssets(data.media || [], { limit: 6 });
    } catch (openError) {
      ctx.showToast(openError.message, "error");
    }
  }

  async function createCollection(event) {
    event.preventDefault();
    try {
      const data = await apiFetch("/api/collections", {
        method: "POST",
        body: JSON.stringify(form),
      });
      setForm({ name: "", description: "", is_public: true });
      setMine(true);
      setCollections((rows) => [data.collection, ...rows]);
      await openCollection(data.collection.id);
    } catch (createError) {
      ctx.showToast(createError.message, "error");
    }
  }

  return (
    <Page title="Collections" eyebrow="Stacks" actions={(
      <>
        <Segmented value={mine ? "mine" : "community"} onChange={(value) => setMine(value === "mine")} options={[["community", "Community"], ["mine", "Mine"]]} />
        <button type="button" onClick={loadCollections}><RefreshCw size={16} />Refresh</button>
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
        <section className="detail-panel">
          {selected ? (
            <>
              <div className="section-head">
                <div><h2>{selected.name}</h2><p>{selected.description || "No description"}</p></div>
                <span>{selected.is_public ? "Public" : "Private"}</span>
              </div>
              <MediaGrid ctx={ctx} items={media} emptyTitle="This collection is empty" onItemUpdated={(item) => setMedia((rows) => replaceMedia(rows, item))} />
            </>
          ) : <EmptyState title="Select a collection" />}
        </section>
      </section>
    </Page>
  );
}
