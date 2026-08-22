import { useCallback, useEffect, useRef, useState } from "react";
import { Download, Film, Image as ImageIcon, PlusCircle, RefreshCw, Save, Search, Sparkles } from "lucide-react";
import { apiFetch, apiFetchBlob, cachedApiFetch, clearApiCache, downloadBlob, toQuery } from "../api.js";
import { MediaGrid } from "../components/media.jsx";
import { CollectionCover, EmptyState, Notice, Page, ResilientImage, Segmented, SkeletonList } from "../components/ui.jsx";
import { formatDate } from "../utils/format.js";
import { mediaImageSources, preloadMediaAssets, replaceMedia } from "../utils/media.js";

export function CollectionsPage({ ctx }) {
  const [mine, setMine] = useState(false);
  const [collections, setCollections] = useState([]);
  const [selected, setSelected] = useState(null);
  const [media, setMedia] = useState([]);
  // Smart-collection creation previously only existed via two narrow side
  // doors -- "save current Discover search" and "one-click from a tag
  // suggestion" -- with no way to just build one directly here. The
  // backend (POST /api/collections) already fully supports is_smart +
  // filter_json in the create payload (sanitize_smart_filter accepts the
  // same shape Discover's own filters use), so this is purely a UI gap:
  // just exposing the fields that were always accepted.
  const [form, setForm] = useState({ name: "", description: "", is_public: true, is_smart: false, filter_json: {} });
  const [picker, setPicker] = useState({ q: "", loading: false, results: [] });
  const [addingId, setAddingId] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [suggestions, setSuggestions] = useState([]);
  const [creatingSuggestion, setCreatingSuggestion] = useState("");

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

  useEffect(() => {
    if (!mine || !ctx.user) {
      setSuggestions([]);
      return;
    }
    apiFetch("/api/collections/suggestions")
      .then((data) => setSuggestions(data.suggestions || []))
      .catch(() => setSuggestions([]));
  }, [mine, ctx.user]);

  async function createSuggestedCollection(suggestion) {
    setCreatingSuggestion(suggestion.tag);
    try {
      const data = await apiFetch("/api/collections", {
        method: "POST",
        body: JSON.stringify({
          name: suggestion.tag.replace(/\b\w/g, (letter) => letter.toUpperCase()),
          is_public: true,
          is_smart: true,
          filter_json: { q: suggestion.tag },
        }),
      });
      clearApiCache();
      setCollections((rows) => [data.collection, ...rows]);
      setSuggestions((rows) => rows.filter((row) => row.tag !== suggestion.tag));
      await openCollection(data.collection.id, { fresh: true });
    } catch (createError) {
      ctx.showToast(createError.message, "error");
    } finally {
      setCreatingSuggestion("");
    }
  }

  async function createCollection(event) {
    event.preventDefault();
    try {
      const data = await apiFetch("/api/collections", {
        method: "POST",
        body: JSON.stringify(form),
      });
      clearApiCache();
      setForm({ name: "", description: "", is_public: true, is_smart: false, filter_json: {} });
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
      await Promise.all([
        openCollection(selected.id, { fresh: true }),
        loadCollections({ fresh: true }),
      ]);
    } catch (addError) {
      ctx.showToast(addError.message, "error");
    } finally {
      setAddingId("");
    }
  }

  const canEditSelected = Boolean(ctx.user && selected && Number(selected.user_id) === Number(ctx.user.id));
  const handleItemUpdated = useCallback((item) => setMedia((rows) => replaceMedia(rows, item)), []);

  const [downloadingAll, setDownloadingAll] = useState(false);
  const downloadCollection = useCallback(async () => {
    if (!selected) return;
    setDownloadingAll(true);
    try {
      const { blob, filename } = await apiFetchBlob(`/api/collections/${selected.id}/download`);
      downloadBlob(blob, filename.endsWith(".zip") ? filename : `${selected.name || "collection"}.zip`);
    } catch (downloadError) {
      showToast(downloadError.message, "error");
    } finally {
      setDownloadingAll(false);
    }
  }, [selected, showToast]);

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
          {ctx.user && mine && suggestions.length ? (
            <div className="collection-suggestions">
              <h3><Sparkles size={14} />Suggested collections</h3>
              {suggestions.map((suggestion) => (
                <button
                  key={suggestion.tag}
                  type="button"
                  className="collection-suggestion-row"
                  onClick={() => createSuggestedCollection(suggestion)}
                  disabled={creatingSuggestion === suggestion.tag}
                >
                  <img src={suggestion.thumb_url} alt="" />
                  <span>
                    <strong>{suggestion.tag}</strong>
                    <small>{suggestion.count} posts</small>
                  </span>
                  <PlusCircle size={16} />
                </button>
              ))}
            </div>
          ) : null}
          {ctx.user && mine ? (
            <form className="stacked-form create-box" onSubmit={createCollection}>
              <input value={form.name} onChange={(event) => setForm((current) => ({ ...current, name: event.target.value }))} placeholder="Collection name" maxLength={100} required />
              <input value={form.description} onChange={(event) => setForm((current) => ({ ...current, description: event.target.value }))} placeholder="Description" maxLength={500} />
              <label className="check-row"><input checked={form.is_public} onChange={(event) => setForm((current) => ({ ...current, is_public: event.target.checked }))} type="checkbox" />Public</label>
              <label className="check-row">
                <input
                  checked={form.is_smart}
                  onChange={(event) => setForm((current) => ({ ...current, is_smart: event.target.checked }))}
                  type="checkbox"
                />
                <Sparkles size={13} />Smart collection (auto-updates to match a filter)
              </label>
              {form.is_smart ? (
                <div className="smart-collection-builder">
                  <input
                    value={form.filter_json.q || ""}
                    onChange={(event) => setForm((current) => ({ ...current, filter_json: { ...current.filter_json, q: event.target.value } }))}
                    placeholder="Search terms (title, description, tags)"
                    maxLength={80}
                  />
                  <select
                    value={form.filter_json.media_kind || ""}
                    onChange={(event) => setForm((current) => ({ ...current, filter_json: { ...current.filter_json, media_kind: event.target.value } }))}
                  >
                    <option value="">Any type</option>
                    <option value="image">Images &amp; GIFs</option>
                    <option value="video">Videos</option>
                  </select>
                  <select
                    value={form.filter_json.category_id || ""}
                    onChange={(event) => setForm((current) => ({ ...current, filter_json: { ...current.filter_json, category_id: event.target.value } }))}
                  >
                    <option value="">Any category</option>
                    {ctx.lookups.categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                  </select>
                  <select
                    value={form.filter_json.adult || "show"}
                    onChange={(event) => setForm((current) => ({ ...current, filter_json: { ...current.filter_json, adult: event.target.value } }))}
                  >
                    <option value="show">Show 18+</option>
                    <option value="hide">Hide 18+</option>
                    <option value="only">Only 18+</option>
                  </select>
                  <select
                    value={form.filter_json.sort || "new"}
                    onChange={(event) => setForm((current) => ({ ...current, filter_json: { ...current.filter_json, sort: event.target.value } }))}
                  >
                    <option value="new">Newest</option>
                    <option value="popular">Most liked</option>
                    <option value="views">Most viewed</option>
                    <option value="downloads">Most downloaded</option>
                    <option value="trending">Trending</option>
                    <option value="old">Oldest</option>
                  </select>
                  <p className="muted-copy">Matching posts are pulled live every time this collection is opened — nothing is copied into it.</p>
                </div>
              ) : null}
              <button type="submit"><Save size={16} />Create</button>
            </form>
          ) : null}
          {loading ? <SkeletonList /> : collections.map((collection) => (
            <button className={`collection-row ${selected?.id === collection.id ? "active" : ""}`} key={collection.id} type="button" onClick={() => openCollection(collection.id)}>
              <CollectionCover collection={collection} />
              <span>
                <strong>{collection.name}{collection.is_smart ? <span className="smart-collection-badge"><Sparkles size={11} />Smart</span> : null}</strong>
                <small>{collection.is_smart ? "Live filter" : `${collection.item_count || 0} posts`}</small>
              </span>
            </button>
          ))}
          {!loading && !collections.length ? <EmptyState title="No collections" /> : null}
        </aside>
        <section className="detail-panel collection-detail-panel">
          {selected ? (
            <>
              <div className="section-head collection-detail-head">
                <div><h2>{selected.name}{selected.is_smart ? <span className="smart-collection-badge"><Sparkles size={11} />Smart</span> : null}</h2><p>{selected.description || "No description"}</p></div>
                <span>{selected.is_public ? "Public" : "Private"}</span>
                <button type="button" onClick={downloadCollection} disabled={downloadingAll || !media.length}>
                  <Download size={16} />{downloadingAll ? "Zipping…" : "Download all"}
                </button>
              </div>
              {canEditSelected && !selected.is_smart ? (
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
              <MediaGrid ctx={ctx} items={media} emptyTitle="This collection is empty" onItemUpdated={handleItemUpdated} onOpen={ctx.openLightbox} />
            </>
          ) : <EmptyState title="Select a collection" />}
        </section>
      </section>
    </Page>
  );
}
