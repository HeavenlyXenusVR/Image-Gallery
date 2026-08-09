import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { Bell, Columns2, Grid2X2, RefreshCw, Save, Search, SlidersHorizontal, Sparkles, X as XIcon } from "lucide-react";
import { apiFetch, cachedApiFetch, clearApiCache, toQuery } from "../api.js";
import { PAGE_SIZE } from "../config.js";
import { CategoryPills, DiscoverTrending } from "../components/discover.jsx";
import { MediaGrid } from "../components/media.jsx";
import { Notice, Page, TagCloud } from "../components/ui.jsx";
import { preloadMediaAssets, replaceMedia } from "../utils/media.js";

function timeOfDayGreeting(user) {
  const name = user?.display_name || user?.username || "there";
  const hour = new Date().getHours();
  if (hour < 5) return `Still up, ${name}?`;
  if (hour < 12) return `Good morning, ${name}`;
  if (hour < 17) return `Good afternoon, ${name}`;
  if (hour < 22) return `Good evening, ${name}`;
  return `Still up, ${name}?`;
}

const VIEW_MODE_KEY = "ig_discover_view";

function pageSizeFor(settings) {
  const parsed = Number(settings?.items_per_page);
  if (!Number.isFinite(parsed)) return PAGE_SIZE;
  return Math.min(60, Math.max(12, Math.round(parsed)));
}

function getFilterChips(filters, categories) {
  const chips = [];
  if (filters.q) chips.push({ key: "q", label: `"${filters.q}"`, clear: { q: "" } });
  if (filters.media_kind) {
    chips.push({ key: "media_kind", label: filters.media_kind === "image" ? "Images & GIFs" : "Videos", clear: { media_kind: "" } });
  }
  if (filters.category_id) {
    const cat = categories.find((c) => String(c.id) === String(filters.category_id));
    chips.push({ key: "category_id", label: cat?.name || `Category ${filters.category_id}`, clear: { category_id: "", subcategory_id: "" } });
  }
  if (filters.subcategory_id) chips.push({ key: "subcategory_id", label: `Sub ${filters.subcategory_id}`, clear: { subcategory_id: "" } });
  if (filters.uploader) chips.push({ key: "uploader", label: `By ${filters.uploader}`, clear: { uploader: "" } });
  if (filters.min_size) chips.push({ key: "min_size", label: `≥${filters.min_size} MB`, clear: { min_size: "" } });
  if (filters.max_size) chips.push({ key: "max_size", label: `≤${filters.max_size} MB`, clear: { max_size: "" } });
  if (filters.date_from) chips.push({ key: "date_from", label: `From ${filters.date_from}`, clear: { date_from: "" } });
  if (filters.date_to) chips.push({ key: "date_to", label: `To ${filters.date_to}`, clear: { date_to: "" } });
  if (filters.adult !== "show") {
    chips.push({ key: "adult", label: filters.adult === "hide" ? "No 18+" : "Only 18+", clear: { adult: "show" } });
  }
  if (filters.sort && filters.sort !== "new") {
    const sortLabels = { trending: "Trending", popular: "Most liked", downloads: "Most downloaded", views: "Most viewed", old: "Oldest" };
    chips.push({ key: "sort", label: sortLabels[filters.sort] || filters.sort, clear: { sort: "new" } });
  }
  return chips;
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
  }));
  const [items, setItems] = useState([]);
  const [hasNext, setHasNext] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState("");
  const [randomPending, setRandomPending] = useState(false);
  const [viewMode, setViewMode] = useState(() => localStorage.getItem(VIEW_MODE_KEY) || "grid");
  const [savingSmart, setSavingSmart] = useState(false);
  const [savingAlert, setSavingAlert] = useState(false);

  const pageRef = useRef(1);
  const filtersRef = useRef(filters);
  filtersRef.current = filters;
  const sentinelRef = useRef(null);

  const pageSize = pageSizeFor(ctx.settings);

  const handleItemUpdated = useCallback((item) => setItems((rows) => replaceMedia(rows, item)), []);

  const selectedCategory = ctx.lookups.categories.find(
    (c) => String(c.id) === String(filters.category_id),
  );
  const subcategories = selectedCategory?.subcategories || selectedCategory?.children || [];

  const loadMedia = useCallback(async ({ page = 1, append = false } = {}) => {
    const f = filtersRef.current;
    const queryParams = {
      q: f.q,
      media_kind: f.media_kind,
      category_id: f.category_id,
      subcategory_id: f.subcategory_id,
      uploader: f.uploader,
      min_size: f.min_size ? Number(f.min_size) * 1024 * 1024 : "",
      max_size: f.max_size ? Number(f.max_size) * 1024 * 1024 : "",
      date_from: f.date_from,
      date_to: f.date_to,
      adult: f.adult,
      sort: f.sort,
      limit: pageSize + 1,
      offset: (page - 1) * pageSize,
    };
    const path = `/api/media${toQuery(queryParams)}`;
    try {
      const data = append
        ? await apiFetch(path)
        : await cachedApiFetch(path, { ttl: 20_000, staleTtl: 5 * 60_000, storage: "session" });
      const rows = data.media || [];
      const pageItems = rows.slice(0, pageSize);
      if (append) {
        setItems((prev) => [...prev, ...pageItems]);
      } else {
        setItems(pageItems);
      }
      setHasNext(rows.length > pageSize);
      preloadMediaAssets(rows, { limit: 6 });
    } catch (err) {
      if (!append) { setError(err.message); setItems([]); setHasNext(false); }
    } finally {
      if (!append) setLoading(false);
      else setLoadingMore(false);
    }
  }, [pageSize]);

  // Filter change → reset and reload
  useEffect(() => {
    pageRef.current = 1;
    setHasNext(false);
    setLoading(true);
    setError("");
    setItems([]);
    loadMedia({ page: 1, append: false });

    const next = { ...filters };
    Object.keys(next).forEach((key) => {
      if (next[key] === "" || (key === "adult" && next[key] === "show") || (key === "sort" && next[key] === "new")) {
        delete next[key];
      }
    });
    setSearchParams(next, { replace: true });
  }, [filters]); // intentionally omit loadMedia/setSearchParams — stable refs

  // Infinite scroll sentinel
  useEffect(() => {
    const sentinel = sentinelRef.current;
    if (!sentinel) return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting && hasNext && !loadingMore && !loading) {
          const nextPage = pageRef.current + 1;
          pageRef.current = nextPage;
          setLoadingMore(true);
          loadMedia({ page: nextPage, append: true });
        }
      },
      { rootMargin: "300px" },
    );
    observer.observe(sentinel);
    return () => observer.disconnect();
  }, [hasNext, loadingMore, loading, loadMedia]);

  function updateFilter(key, value) {
    setFilters((current) => ({
      ...current,
      [key]: value,
      ...(key === "category_id" ? { subcategory_id: "" } : {}),
    }));
  }

  function applyFilterClear(patch) {
    setFilters((current) => ({ ...current, ...patch }));
  }

  function clearAllFilters() {
    setFilters({
      q: "", media_kind: "", category_id: "", subcategory_id: "", uploader: "",
      min_size: "", max_size: "", date_from: "", date_to: "",
      adult: "show", sort: ctx.settings.default_sort || "new",
    });
  }

  async function openRandom() {
    if (randomPending) return;
    setRandomPending(true);
    try {
      const data = await apiFetch("/api/media/random");
      navigate(`/media/${data.media.id}`);
    } catch (randomError) {
      ctx.showToast(randomError.message, "error");
    } finally {
      setRandomPending(false);
    }
  }

  function changeViewMode(mode) {
    setViewMode(mode);
    localStorage.setItem(VIEW_MODE_KEY, mode);
  }

  function filterPayloadFromFilters(f) {
    return {
      q: f.q || undefined,
      media_kind: f.media_kind || undefined,
      category_id: f.category_id || undefined,
      subcategory_id: f.subcategory_id || undefined,
      uploader: f.uploader || undefined,
      min_size: f.min_size ? Number(f.min_size) * 1024 * 1024 : undefined,
      max_size: f.max_size ? Number(f.max_size) * 1024 * 1024 : undefined,
      date_from: f.date_from || undefined,
      date_to: f.date_to || undefined,
      adult: f.adult && f.adult !== "show" ? f.adult : undefined,
      sort: f.sort && f.sort !== "new" ? f.sort : undefined,
    };
  }

  async function saveSmartCollection() {
    if (!ctx.user) {
      ctx.showToast("Login required to save collections.", "error");
      return;
    }
    if (!filterChips.length) {
      ctx.showToast("Set at least one filter before saving it as a smart collection.", "error");
      return;
    }
    const name = window.prompt("Name this smart collection", filters.q || "My smart collection");
    if (!name || !name.trim()) return;
    setSavingSmart(true);
    try {
      await apiFetch("/api/collections", {
        method: "POST",
        body: JSON.stringify({ name: name.trim(), is_public: true, is_smart: true, filter_json: filterPayloadFromFilters(filters) }),
      });
      clearApiCache("/api/collections");
      ctx.showToast(`Saved "${name.trim()}" as a smart collection.`, "success");
    } catch (saveError) {
      ctx.showToast(saveError.message, "error");
    } finally {
      setSavingSmart(false);
    }
  }

  async function saveSearchAlert() {
    if (!ctx.user) {
      ctx.showToast("Login required to save alerts.", "error");
      return;
    }
    if (!filterChips.length) {
      ctx.showToast("Set at least one filter before saving it as an alert.", "error");
      return;
    }
    const name = window.prompt("Name this saved search / alert", filters.q || "My saved search");
    if (!name || !name.trim()) return;
    setSavingAlert(true);
    try {
      await apiFetch("/api/saved-searches", {
        method: "POST",
        body: JSON.stringify({ name: name.trim(), filter_json: filterPayloadFromFilters(filters) }),
      });
      ctx.showToast(`Saved "${name.trim()}" — you'll be notified when new matches are uploaded.`, "success");
    } catch (saveError) {
      ctx.showToast(saveError.message, "error");
    } finally {
      setSavingAlert(false);
    }
  }

  const openLightbox = ctx.openLightbox;
  const filterChips = getFilterChips(filters, ctx.lookups.categories);
  const gridExtraClass = viewMode === "masonry" ? "media-grid-masonry" : "";

  return (
    <Page
      title="Discover"
      eyebrow="Gallery"
      lede="Search the archive, narrow by category or uploader, and scan the latest posts without losing your place."
      className="page-discover"
      actions={(
        <>
          <button type="button" onClick={openRandom} disabled={randomPending}>
            <Sparkles size={16} />{randomPending ? "Loading" : "Surprise"}
          </button>
          <button type="button" onClick={() => { pageRef.current = 1; setItems([]); setHasNext(false); setLoadingMore(false); setLoading(true); setError(""); clearApiCache("/api/media"); loadMedia({ page: 1, append: false }); }} disabled={loading}>
            <RefreshCw size={16} />Refresh
          </button>
        </>
      )}
    >
      <div className="discover-greeting">
        <strong>{timeOfDayGreeting(ctx.user)}</strong>
        <span>Here&rsquo;s what the archive&rsquo;s been up to.</span>
      </div>

      <label className="discover-search">
        <Search size={18} />
        <input
          value={filters.q}
          onChange={(e) => updateFilter("q", e.target.value)}
          type="search"
          placeholder="Search wallpapers, memes, tags…"
        />
      </label>

      {!filterChips.length ? <DiscoverTrending /> : null}

      <CategoryPills
        categories={ctx.lookups.categories}
        selectedId={filters.category_id}
        onSelect={(categoryId) => updateFilter("category_id", categoryId)}
      />

      <section className="workspace">
        <aside className="filter-rail">
          <label className="field">
            <span>Type</span>
            <select value={filters.media_kind} onChange={(e) => updateFilter("media_kind", e.target.value)}>
              <option value="">All media</option>
              <option value="image">Images and GIFs</option>
              <option value="video">Videos</option>
            </select>
          </label>
          <label className="field">
            <span>Category</span>
            <select value={filters.category_id} onChange={(e) => updateFilter("category_id", e.target.value)}>
              <option value="">All categories</option>
              {ctx.lookups.categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </label>
          <label className="field">
            <span>Subcategory</span>
            <select value={filters.subcategory_id} onChange={(e) => updateFilter("subcategory_id", e.target.value)} disabled={!subcategories.length}>
              <option value="">All subcategories</option>
              {subcategories.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          </label>
          <label className="field">
            <span>Sort</span>
            <select value={filters.sort} onChange={(e) => updateFilter("sort", e.target.value)}>
              <option value="new">Newest</option>
              <option value="trending">Trending</option>
              <option value="popular">Most liked</option>
              <option value="downloads">Most downloaded</option>
              <option value="views">Most viewed</option>
              <option value="old">Oldest</option>
            </select>
          </label>
          <details className="filter-details" open>
            <summary><SlidersHorizontal size={16} /> Advanced</summary>
            <label className="field"><span>Uploader</span><input value={filters.uploader} onChange={(e) => updateFilter("uploader", e.target.value)} /></label>
            <div className="two-col">
              <label className="field"><span>Min MB</span><input value={filters.min_size} onChange={(e) => updateFilter("min_size", e.target.value)} type="number" min="0" /></label>
              <label className="field"><span>Max MB</span><input value={filters.max_size} onChange={(e) => updateFilter("max_size", e.target.value)} type="number" min="0" /></label>
            </div>
            <div className="two-col">
              <label className="field"><span>From</span><input value={filters.date_from} onChange={(e) => updateFilter("date_from", e.target.value)} type="date" /></label>
              <label className="field"><span>To</span><input value={filters.date_to} onChange={(e) => updateFilter("date_to", e.target.value)} type="date" /></label>
            </div>
            <label className="field">
              <span>18+ posts</span>
              <select value={filters.adult} onChange={(e) => updateFilter("adult", e.target.value)}>
                <option value="show">Show when allowed</option>
                <option value="hide">Hide 18+</option>
                <option value="only">Only 18+</option>
              </select>
            </label>
          </details>
          <TagCloud tags={ctx.lookups.tags} onPick={(tag) => updateFilter("q", tag.name || tag.tag || tag)} />
        </aside>

        <section className="content-panel">
          {/* Toolbar: active filter chips + view mode toggle */}
          <div className="discover-toolbar">
            {filterChips.length > 0 ? (
              <div className="active-filters">
                {filterChips.map((chip) => (
                  <button
                    key={chip.key}
                    type="button"
                    className="filter-chip"
                    onClick={() => applyFilterClear(chip.clear)}
                    title={`Remove: ${chip.label}`}
                  >
                    {chip.label}
                    <XIcon size={12} />
                  </button>
                ))}
                <button type="button" className="filter-chip filter-chip-clear" onClick={clearAllFilters}>
                  Clear all
                </button>
                {ctx.user ? (
                  <button type="button" className="filter-chip filter-chip-save" onClick={saveSmartCollection} disabled={savingSmart}>
                    <Save size={12} />{savingSmart ? "Saving…" : "Save as smart collection"}
                  </button>
                ) : null}
                {ctx.user ? (
                  <button type="button" className="filter-chip filter-chip-save" onClick={saveSearchAlert} disabled={savingAlert}>
                    <Bell size={12} />{savingAlert ? "Saving…" : "Save as alert"}
                  </button>
                ) : null}
              </div>
            ) : null}
            <div className="view-toggle">
              <button
                type="button"
                className={`icon-button ${viewMode === "grid" ? "active" : ""}`}
                onClick={() => changeViewMode("grid")}
                title="Grid view"
                aria-label="Grid view"
              >
                <Grid2X2 size={16} />
              </button>
              <button
                type="button"
                className={`icon-button ${viewMode === "masonry" ? "active" : ""}`}
                onClick={() => changeViewMode("masonry")}
                title="Masonry view"
                aria-label="Masonry view"
              >
                <Columns2 size={16} />
              </button>
            </div>
          </div>

          {error ? <Notice kind="error">{error}</Notice> : null}
          <MediaGrid
            ctx={ctx}
            items={items}
            loading={loading}
            emptyTitle="No posts match this view"
            onItemUpdated={handleItemUpdated}
            onOpen={openLightbox}
            extraClass={gridExtraClass}
          />

          {/* Infinite scroll sentinel */}
          <div ref={sentinelRef} className="scroll-sentinel" aria-hidden="true" />
          {loadingMore ? (
            <div className="load-more-spinner" aria-label="Loading more posts">
              <span className="spinner-ring" />
              <span>Loading more</span>
            </div>
          ) : null}
          {!hasNext && !loading && items.length > 0 ? (
            <div className="scroll-end">All caught up</div>
          ) : null}
        </section>
      </section>
    </Page>
  );
}
