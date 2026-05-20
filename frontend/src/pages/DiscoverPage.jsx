import { useCallback, useEffect, useMemo, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { RefreshCw, Search, SlidersHorizontal, Sparkles } from "lucide-react";
import { apiFetch, cachedApiFetch, clearApiCache, prefetchApi, toQuery } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { PAGE_SIZE } from "../config.js";
import { MediaGrid } from "../components/media.jsx";
import { Notice, Page, Pager, TagCloud } from "../components/ui.jsx";
import { preloadMediaAssets, replaceMedia } from "../utils/media.js";

function pageSizeFor(settings) {
  const parsed = Number(settings?.items_per_page);
  if (!Number.isFinite(parsed)) return PAGE_SIZE;
  return Math.min(60, Math.max(12, Math.round(parsed)));
}

export function DiscoverPage({ ctx }) {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const [filters, setFilters] = useState(() => ({
    q: searchParams.get("q") || "",
    media_kind: searchParams.get("media_kind") || "",
    category_id: searchParams.get("category_id") || "",
    subcategory_id: searchParams.get("subcategory_id") || "",
    uploader: searchParams.get("uploader") || "",
    min_size: searchParams.get("min_size") || "",
    max_size: searchParams.get("max_size") || "",
    date_from: searchParams.get("date_from") || "",
    date_to: searchParams.get("date_to") || "",
    adult: searchParams.get("adult") || "show",
    sort: searchParams.get("sort") || ctx.settings.default_sort || "new",
    page: Number(searchParams.get("page") || "1") || 1,
  }));
  const [items, setItems] = useState([]);
  const [hasNext, setHasNext] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const selectedCategory = useMemo(() => {
    return ctx.lookups.categories.find((category) => String(category.id) === String(filters.category_id));
  }, [ctx.lookups.categories, filters.category_id]);
  const subcategories = selectedCategory?.subcategories || selectedCategory?.children || [];
  const pageSize = pageSizeFor(ctx.settings);

  const loadMedia = useCallback(async ({ background = false } = {}) => {
    if (!background) {
      setLoading(true);
      setError("");
    }
    try {
      const page = Math.max(1, Number(filters.page) || 1);
      const queryParams = {
        q: filters.q,
        media_kind: filters.media_kind,
        category_id: filters.category_id,
        subcategory_id: filters.subcategory_id,
        uploader: filters.uploader,
        min_size: filters.min_size ? Number(filters.min_size) * 1024 * 1024 : "",
        max_size: filters.max_size ? Number(filters.max_size) * 1024 * 1024 : "",
        date_from: filters.date_from,
        date_to: filters.date_to,
        adult: filters.adult,
        sort: filters.sort,
        limit: pageSize + 1,
        offset: (page - 1) * pageSize,
      };
      const query = toQuery(queryParams);
      const path = `/api/media${query}`;
      const data = background
        ? await apiFetch(path)
        : await cachedApiFetch(path, { ttl: 20_000, staleTtl: 5 * 60_000, storage: "session" });
      const rows = data.media || [];
      setItems(rows.slice(0, pageSize));
      setHasNext(rows.length > pageSize);
      preloadMediaAssets(rows, { limit: 6 });
      if (rows.length > pageSize) {
        prefetchApi(`/api/media${toQuery({ ...queryParams, offset: page * pageSize })}`, { ttl: 30_000, staleTtl: 5 * 60_000, storage: "session" });
      }
    } catch (fetchError) {
      if (!background) {
        setError(fetchError.message);
        setItems([]);
        setHasNext(false);
      }
    } finally {
      if (!background) setLoading(false);
    }
  }, [filters, pageSize]);

  useEffect(() => {
    const next = { ...filters };
    Object.keys(next).forEach((key) => {
      if (next[key] === "" || (key === "page" && Number(next[key]) === 1)) delete next[key];
    });
    setSearchParams(next, { replace: true });
    loadMedia();
  }, [filters, loadMedia, setSearchParams]);

  useLiveRefresh(() => loadMedia({ background: true }), {
    enabled: Number(filters.page) === 1,
    interval: ctx.user ? 18_000 : 28_000,
  });

  function updateFilter(key, value) {
    setFilters((current) => ({
      ...current,
      [key]: value,
      page: 1,
      ...(key === "category_id" ? { subcategory_id: "" } : {}),
    }));
  }

  async function openRandom() {
    try {
      const data = await apiFetch("/api/media/random");
      navigate(`/media/${data.media.id}`);
    } catch (randomError) {
      ctx.showToast(randomError.message, "error");
    }
  }

  return (
    <Page
      title="Discover"
      eyebrow="Gallery"
      lede="Search the archive, narrow by category or uploader, and scan the latest posts without losing your place."
      className="page-discover"
      actions={(
      <>
        <button type="button" onClick={openRandom}><Sparkles size={16} />Surprise</button>
        <button type="button" onClick={() => { clearApiCache("/api/media"); loadMedia(); }}><RefreshCw size={16} />Refresh</button>
      </>
      )}
    >
      <section className="workspace">
        <aside className="filter-rail">
          <label className="field">
            <span>Search</span>
            <div className="input-with-icon"><Search size={16} /><input value={filters.q} onChange={(event) => updateFilter("q", event.target.value)} type="search" placeholder="wallpaper, meme, vaporwave" /></div>
          </label>
          <label className="field">
            <span>Type</span>
            <select value={filters.media_kind} onChange={(event) => updateFilter("media_kind", event.target.value)}>
              <option value="">All media</option>
              <option value="image">Images and GIFs</option>
              <option value="video">Videos</option>
            </select>
          </label>
          <label className="field">
            <span>Category</span>
            <select value={filters.category_id} onChange={(event) => updateFilter("category_id", event.target.value)}>
              <option value="">All categories</option>
              {ctx.lookups.categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}
            </select>
          </label>
          <label className="field">
            <span>Subcategory</span>
            <select value={filters.subcategory_id} onChange={(event) => updateFilter("subcategory_id", event.target.value)} disabled={!subcategories.length}>
              <option value="">All subcategories</option>
              {subcategories.map((subcategory) => <option key={subcategory.id} value={subcategory.id}>{subcategory.name}</option>)}
            </select>
          </label>
          <label className="field">
            <span>Sort</span>
            <select value={filters.sort} onChange={(event) => updateFilter("sort", event.target.value)}>
              <option value="new">Newest</option>
              <option value="popular">Most liked</option>
              <option value="downloads">Most downloaded</option>
              <option value="views">Most viewed</option>
              <option value="old">Oldest</option>
            </select>
          </label>
          <details className="filter-details" open>
            <summary><SlidersHorizontal size={16} /> Advanced</summary>
            <label className="field"><span>Uploader</span><input value={filters.uploader} onChange={(event) => updateFilter("uploader", event.target.value)} /></label>
            <div className="two-col">
              <label className="field"><span>Min MB</span><input value={filters.min_size} onChange={(event) => updateFilter("min_size", event.target.value)} type="number" min="0" /></label>
              <label className="field"><span>Max MB</span><input value={filters.max_size} onChange={(event) => updateFilter("max_size", event.target.value)} type="number" min="0" /></label>
            </div>
            <div className="two-col">
              <label className="field"><span>From</span><input value={filters.date_from} onChange={(event) => updateFilter("date_from", event.target.value)} type="date" /></label>
              <label className="field"><span>To</span><input value={filters.date_to} onChange={(event) => updateFilter("date_to", event.target.value)} type="date" /></label>
            </div>
            <label className="field">
              <span>18+ posts</span>
              <select value={filters.adult} onChange={(event) => updateFilter("adult", event.target.value)}>
                <option value="show">Show when allowed</option>
                <option value="hide">Hide 18+</option>
                <option value="only">Only 18+</option>
              </select>
            </label>
          </details>
          <TagCloud tags={ctx.lookups.tags} onPick={(tag) => updateFilter("q", tag.name || tag.tag || tag)} />
        </aside>
        <section className="content-panel">
          {error ? <Notice kind="error">{error}</Notice> : null}
          <MediaGrid ctx={ctx} items={items} loading={loading} emptyTitle="No posts match this view" onItemUpdated={(item) => setItems((rows) => replaceMedia(rows, item))} />
          <Pager page={filters.page} hasNext={hasNext} loading={loading} onPage={(page) => setFilters((current) => ({ ...current, page }))} />
        </section>
      </section>
    </Page>
  );
}
