import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Link,
  NavLink,
  Navigate,
  Route,
  Routes,
  useNavigate,
  useParams,
  useSearchParams,
} from "react-router-dom";
import {
  Bookmark,
  Check,
  Download,
  Eye,
  Film,
  Folder,
  Grid3X3,
  Heart,
  Home,
  Image as ImageIcon,
  KeyRound,
  Lock,
  LogIn,
  LogOut,
  Mail,
  MessageCircle,
  Palette,
  RefreshCw,
  Save,
  Search,
  Settings,
  ShieldCheck,
  SlidersHorizontal,
  Sparkles,
  Trash2,
  Upload,
  UserPlus,
  UserRound,
  Users,
  WandSparkles,
  X,
} from "lucide-react";
import {
  apiFetch,
  cachedApiFetch,
  clearApiCache,
  readStoredUser,
  readToken,
  toQuery,
  writeStoredUser,
  writeToken,
} from "./api.js";

const PAGE_SIZE = 24;
const MAX_UPLOAD_BYTES = 500 * 1024 * 1024;
const DEFAULT_SETTINGS = {
  theme_mode: "system",
  accent_color: "#37c9a7",
  grid_density: "comfortable",
  default_sort: "new",
  items_per_page: PAGE_SIZE,
  autoplay_previews: false,
  muted_previews: true,
  reduce_motion: false,
  open_original_in_new_tab: false,
  blur_video_previews: false,
  profile_layout: "spotlight",
  profile_banner_style: "gradient",
  profile_card_style: "glass",
  profile_stat_style: "tiles",
  profile_content_focus: "balanced",
  profile_hero_alignment: "split",
  profile_show_joined_date: true,
  profile_show_uploads: true,
  profile_show_collections: true,
  profile_show_friends: true,
  profile_show_follow_counts: true,
};

function App() {
  const navigate = useNavigate();
  const [token, setTokenState] = useState(() => readToken());
  const [user, setUserState] = useState(() => readStoredUser());
  const [lookups, setLookups] = useState({ categories: [], tags: [], live: null });
  const [toast, setToast] = useState(null);

  const showToast = useCallback((message, kind = "info") => {
    setToast({ message, kind, id: Date.now() });
  }, []);

  const setSessionUser = useCallback((nextUser) => {
    setUserState(nextUser);
    writeStoredUser(nextUser);
  }, []);

  const logout = useCallback((withNotice = true) => {
    writeToken("");
    writeStoredUser(null);
    clearApiCache();
    setTokenState("");
    setUserState(null);
    if (withNotice) showToast("Signed out.", "success");
    navigate("/");
  }, [navigate, showToast]);

  const loginWith = useCallback((payload) => {
    writeToken(payload.token);
    writeStoredUser(payload.user);
    clearApiCache();
    setTokenState(payload.token);
    setUserState(payload.user);
    showToast(`Welcome, ${payload.user?.display_name || payload.user?.username || "friend"}.`, "success");
    navigate("/");
  }, [navigate, showToast]);

  const refreshMe = useCallback(async () => {
    if (!readToken()) {
      setSessionUser(null);
      return;
    }
    try {
      const data = await apiFetch("/api/me");
      setSessionUser(data.user);
    } catch (error) {
      if (error.status === 401) logout(false);
    }
  }, [logout, setSessionUser]);

  const refreshLookups = useCallback(async () => {
    const [categories, tags, live] = await Promise.allSettled([
      cachedApiFetch("/api/categories", { ttl: 5 * 60_000 }),
      cachedApiFetch("/api/tags", { ttl: 5 * 60_000 }),
      cachedApiFetch("/api/live/checks", { ttl: 30_000 }),
    ]);
    setLookups({
      categories: categories.status === "fulfilled" ? categories.value.categories || [] : [],
      tags: tags.status === "fulfilled" ? tags.value.tags || [] : [],
      live: live.status === "fulfilled" ? live.value : null,
    });
  }, []);

  useEffect(() => {
    refreshMe();
    refreshLookups();
  }, [refreshMe, refreshLookups]);

  useEffect(() => {
    if (!toast) return undefined;
    const timer = window.setTimeout(() => setToast(null), 3600);
    return () => window.clearTimeout(timer);
  }, [toast]);

  const ctx = useMemo(() => ({
    token,
    user,
    settings: { ...DEFAULT_SETTINGS, ...(user?.user_settings || {}) },
    lookups,
    loginWith,
    logout,
    refreshMe,
    refreshLookups,
    setSessionUser,
    showToast,
  }), [loginWith, logout, lookups, refreshLookups, refreshMe, setSessionUser, showToast, token, user]);

  return (
    <Shell ctx={ctx}>
      <Routes>
        <Route path="/" element={<DiscoverPage ctx={ctx} />} />
        <Route path="/following" element={<FeedPage ctx={ctx} mode="following" />} />
        <Route path="/liked" element={<FeedPage ctx={ctx} mode="liked" />} />
        <Route path="/media/:mediaId" element={<MediaDetailPage ctx={ctx} />} />
        <Route path="/collections" element={<CollectionsPage ctx={ctx} />} />
        <Route path="/users" element={<UsersPage ctx={ctx} />} />
        <Route path="/users/:username" element={<ProfilePage ctx={ctx} />} />
        <Route path="/friends" element={<FriendsPage ctx={ctx} />} />
        <Route path="/studio" element={<StudioPage ctx={ctx} />} />
        <Route path="/profile" element={ctx.user ? <Navigate to={`/users/${ctx.user.username}`} replace /> : <Navigate to="/login" replace />} />
        <Route path="/upload" element={<UploadPage ctx={ctx} />} />
        <Route path="/settings" element={<SettingsPage ctx={ctx} />} />
        <Route path="/login" element={<AuthPage ctx={ctx} />} />
        <Route path="*" element={<NotFound />} />
      </Routes>
      {toast ? <div className={`toast toast-${toast.kind}`} role="status">{toast.message}</div> : null}
    </Shell>
  );
}

function Shell({ ctx, children }) {
  const liveOk = ctx.lookups.live?.ok ?? ctx.lookups.live?.checks?.database ?? ctx.lookups.live?.checks?.api;
  return (
    <div className="app-shell">
      <header className="topbar">
        <Link className="brand" to="/">
          <span className="brand-mark"><ImageIcon size={18} /></span>
          <span>Image Gallery</span>
        </Link>
        <nav className="primary-nav" aria-label="Main">
          <NavItem to="/" icon={Home} label="Discover" />
          <NavItem to="/collections" icon={Folder} label="Collections" />
          <NavItem to="/users" icon={Users} label="Users" />
          <NavItem to="/following" icon={Sparkles} label="Following" />
          <NavItem to="/liked" icon={Heart} label="Liked" />
          {ctx.user ? <NavItem to="/friends" icon={UserPlus} label="Friends" /> : null}
          {ctx.user ? <NavItem to="/studio" icon={Grid3X3} label="Studio" /> : null}
          {ctx.user ? <NavItem to="/upload" icon={Upload} label="Upload" accent /> : null}
        </nav>
        <div className="account-actions">
          <span className={`health-pill ${liveOk ? "is-live" : ""}`}>{liveOk ? "Live" : "Checking"}</span>
          {ctx.user ? (
            <>
              <Link className="avatar-link" to={`/users/${ctx.user.username}`} title="Profile">
                <Avatar user={ctx.user} />
              </Link>
              <IconButton to="/settings" icon={Settings} label="Settings" />
              <button className="icon-button" type="button" onClick={() => ctx.logout()} title="Logout">
                <LogOut size={18} />
                <span className="sr-only">Logout</span>
              </button>
            </>
          ) : (
            <Link className="auth-link" to="/login">
              <LogIn size={18} />
              <span>Login</span>
            </Link>
          )}
        </div>
      </header>
      <main className="main-stage">{children}</main>
    </div>
  );
}

function NavItem({ to, icon: Icon, label, accent = false }) {
  return (
    <NavLink className={({ isActive }) => `nav-item ${isActive ? "active" : ""} ${accent ? "accent" : ""}`} to={to} end={to === "/"}>
      <Icon size={18} />
      <span>{label}</span>
    </NavLink>
  );
}

function IconButton({ to, icon: Icon, label }) {
  return (
    <Link className="icon-button" to={to} title={label}>
      <Icon size={18} />
      <span className="sr-only">{label}</span>
    </Link>
  );
}

function DiscoverPage({ ctx }) {
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

  const loadMedia = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const page = Math.max(1, Number(filters.page) || 1);
      const query = toQuery({
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
        limit: PAGE_SIZE + 1,
        offset: (page - 1) * PAGE_SIZE,
      });
      const data = await cachedApiFetch(`/api/media${query}`, { ttl: 12_000 });
      const rows = data.media || [];
      setItems(rows.slice(0, PAGE_SIZE));
      setHasNext(rows.length > PAGE_SIZE);
      preloadMediaAssets(rows.slice(0, 8));
    } catch (fetchError) {
      setError(fetchError.message);
      setItems([]);
      setHasNext(false);
    } finally {
      setLoading(false);
    }
  }, [filters]);

  useEffect(() => {
    const next = { ...filters };
    Object.keys(next).forEach((key) => {
      if (next[key] === "" || (key === "page" && Number(next[key]) === 1)) delete next[key];
    });
    setSearchParams(next, { replace: true });
    loadMedia();
  }, [filters, loadMedia, setSearchParams]);

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
    <Page title="Discover" eyebrow="Gallery" actions={(
      <>
        <button type="button" onClick={openRandom}><Sparkles size={16} />Surprise</button>
        <button type="button" onClick={() => { clearApiCache("/api/media"); loadMedia(); }}><RefreshCw size={16} />Refresh</button>
      </>
    )}>
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

function FeedPage({ ctx, mode }) {
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
        const data = await apiFetch(`${endpoint}${toQuery({ limit: PAGE_SIZE + 1, offset: (page - 1) * PAGE_SIZE })}`);
        if (ignore) return;
        const rows = data.media || [];
        setItems(rows.slice(0, PAGE_SIZE));
        setHasNext(rows.length > PAGE_SIZE);
        preloadMediaAssets(rows.slice(0, 8));
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

function MediaDetailPage({ ctx }) {
  const { mediaId } = useParams();
  const [media, setMedia] = useState(null);
  const [comments, setComments] = useState([]);
  const [collections, setCollections] = useState([]);
  const [collectionId, setCollectionId] = useState("");
  const [commentBody, setCommentBody] = useState("");
  const [report, setReport] = useState({ reason: "", details: "" });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const actions = useMediaActions(ctx, (updated) => setMedia(updated));

  const loadDetail = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const data = await apiFetch(`/api/media/${mediaId}`);
      setMedia(data.media);
      setComments(data.comments || []);
      if (ctx.user) {
        const mine = await apiFetch("/api/collections?mine=true").catch(() => ({ collections: [] }));
        setCollections(mine.collections || []);
      }
    } catch (fetchError) {
      setError(fetchError.message);
      setMedia(null);
    } finally {
      setLoading(false);
    }
  }, [ctx.user, mediaId]);

  useEffect(() => {
    loadDetail();
  }, [loadDetail]);

  async function addComment(event) {
    event.preventDefault();
    if (!commentBody.trim()) return;
    try {
      const data = await apiFetch(`/api/media/${media.id}/comments`, {
        method: "POST",
        body: JSON.stringify({ body: commentBody.trim() }),
      });
      setComments((rows) => [...rows, data.comment]);
      setCommentBody("");
      ctx.showToast("Comment posted.", "success");
    } catch (commentError) {
      ctx.showToast(commentError.message, "error");
    }
  }

  async function deleteComment(commentId) {
    try {
      await apiFetch(`/api/comments/${commentId}`, { method: "DELETE" });
      setComments((rows) => rows.filter((comment) => Number(comment.id) !== Number(commentId)));
    } catch (deleteError) {
      ctx.showToast(deleteError.message, "error");
    }
  }

  async function saveToCollection() {
    if (!collectionId) return;
    try {
      await apiFetch(`/api/collections/${collectionId}/items`, {
        method: "POST",
        body: JSON.stringify({ media_id: media.id, saved: true }),
      });
      ctx.showToast("Saved to collection.", "success");
    } catch (saveError) {
      ctx.showToast(saveError.message, "error");
    }
  }

  async function reportMedia(event) {
    event.preventDefault();
    if (!report.reason.trim()) return;
    try {
      await apiFetch(`/api/media/${media.id}/report`, {
        method: "POST",
        body: JSON.stringify(report),
      });
      setReport({ reason: "", details: "" });
      ctx.showToast("Report sent.", "success");
    } catch (reportError) {
      ctx.showToast(reportError.message, "error");
    }
  }

  if (loading) return <Page title="Media" eyebrow="Loading"><SkeletonGrid count={1} /></Page>;
  if (error) return <Page title="Media" eyebrow="Error"><Notice kind="error">{error}</Notice></Page>;
  if (!media) return <NotFound />;

  const isOwner = ctx.user && Number(ctx.user.id) === Number(media.user_id);

  return (
    <Page title={media.title || `Media ${media.id}`} eyebrow={media.media_kind || "Media"} actions={(
      <>
        <button type="button" onClick={() => actions.toggleLike(media)}><Heart size={16} />{media.liked_by_me ? "Unlike" : "Like"}</button>
        <button type="button" onClick={() => actions.toggleBookmark(media)}><Bookmark size={16} />{media.bookmarked_by_me ? "Saved" : "Save"}</button>
        <button type="button" onClick={() => actions.download(media)}><Download size={16} />Download</button>
      </>
    )}>
      <section className="detail-layout">
        <article className="media-stage">
          {media.locked ? (
            <div className="locked-state"><Lock size={38} /><h2>Age verification required</h2></div>
          ) : media.media_kind === "video" ? (
            <video controls playsInline src={media.url} poster={thumbUrl(media)} />
          ) : (
            <img src={media.preview_url || media.url} alt={media.title || ""} />
          )}
        </article>
        <aside className="detail-side">
          <UserLine user={media} />
          {media.description ? <p className="description">{media.description}</p> : null}
          <StatsRow item={media} />
          <ChipRow values={[media.category_name, media.subcategory_name, ...(media.tags || [])]} />
          {ctx.user && collections.length ? (
            <section className="side-box">
              <h3>Collection</h3>
              <div className="inline-controls">
                <select value={collectionId} onChange={(event) => setCollectionId(event.target.value)}>
                  <option value="">Choose</option>
                  {collections.map((collection) => <option key={collection.id} value={collection.id}>{collection.name}</option>)}
                </select>
                <button type="button" onClick={saveToCollection}><Save size={16} />Add</button>
              </div>
            </section>
          ) : null}
          {isOwner ? <MediaControls ctx={ctx} media={media} onChanged={setMedia} /> : null}
          {ctx.user ? (
            <form className="side-box" onSubmit={reportMedia}>
              <h3>Report</h3>
              <input value={report.reason} onChange={(event) => setReport((current) => ({ ...current, reason: event.target.value }))} placeholder="Reason" />
              <textarea value={report.details} onChange={(event) => setReport((current) => ({ ...current, details: event.target.value }))} placeholder="Details" rows={3} />
              <button type="submit">Send</button>
            </form>
          ) : null}
        </aside>
      </section>
      <section className="comments-panel">
        <div className="section-head"><h2>Comments</h2><span>{comments.length}</span></div>
        {ctx.user && media.comments_enabled !== false ? (
          <form className="comment-form" onSubmit={addComment}>
            <input value={commentBody} onChange={(event) => setCommentBody(event.target.value)} placeholder="Add a comment" />
            <button type="submit"><MessageCircle size={16} />Post</button>
          </form>
        ) : null}
        <div className="comments-list">
          {comments.length ? comments.map((comment) => {
            const canDelete = ctx.user && (Number(ctx.user.id) === Number(comment.user_id) || Number(ctx.user.id) === Number(media.user_id));
            return (
              <article className="comment" key={comment.id}>
                <Avatar user={comment} compact />
                <div>
                  <strong>{comment.display_name || comment.username || "User"}</strong>
                  <p>{comment.body}</p>
                </div>
                {canDelete ? <button className="icon-button" type="button" onClick={() => deleteComment(comment.id)} title="Delete"><Trash2 size={16} /></button> : null}
              </article>
            );
          }) : <EmptyState title="No comments yet" />}
        </div>
      </section>
    </Page>
  );
}

function CollectionsPage({ ctx }) {
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
      const data = await apiFetch(`/api/collections${mine ? "?mine=true" : ""}`);
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
      const data = await apiFetch(`/api/collections/${id}`);
      setSelected(data.collection);
      setMedia(data.media || []);
      preloadMediaAssets((data.media || []).slice(0, 8));
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

function UsersPage({ ctx }) {
  const [query, setQuery] = useState("");
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const timer = window.setTimeout(async () => {
      setLoading(true);
      try {
        const data = await cachedApiFetch(`/api/users/search${toQuery({ q: query, limit: 42 })}`, { ttl: 20_000 });
        setUsers(data.users || []);
      } catch (error) {
        ctx.showToast(error.message, "error");
      } finally {
        setLoading(false);
      }
    }, 220);
    return () => window.clearTimeout(timer);
  }, [ctx, query]);

  return (
    <Page title="Users" eyebrow="People">
      <div className="toolbar">
        <div className="input-with-icon wide"><Search size={16} /><input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search users" /></div>
      </div>
      {loading ? <SkeletonGrid count={6} /> : (
        <div className="user-grid">
          {users.map((user) => <UserCard ctx={ctx} user={user} key={user.id} />)}
        </div>
      )}
      {!loading && !users.length ? <EmptyState title="No users found" /> : null}
    </Page>
  );
}

function ProfilePage({ ctx }) {
  const { username } = useParams();
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const loadProfile = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const payload = await apiFetch(`/api/users/${encodeURIComponent(username)}/profile`);
      setData(payload);
      preloadMediaAssets((payload.media || []).slice(0, 8));
    } catch (fetchError) {
      setError(fetchError.message);
    } finally {
      setLoading(false);
    }
  }, [username]);

  useEffect(() => {
    loadProfile();
  }, [loadProfile]);

  if (loading) return <Page title="Profile" eyebrow="Loading"><SkeletonGrid count={4} /></Page>;
  if (error) return <Page title="Profile" eyebrow="Error"><Notice kind="error">{error}</Notice></Page>;
  if (!data?.user) return <NotFound />;

  const profile = data.user;
  const isOwner = ctx.user && ctx.user.username === profile.username;

  return (
    <Page title={profile.display_name || profile.username} eyebrow={`@${profile.username}`} actions={isOwner ? <Link className="button-link" to="/settings"><Settings size={16} />Settings</Link> : null}>
      <section className="profile-hero" style={{ "--accent": safeColor(profile.profile_color || ctx.settings.accent_color) }}>
        <Avatar user={profile} large />
        <div>
          <h2>{profile.profile_headline || profile.display_name || profile.username}</h2>
          {profile.bio ? <p>{profile.bio}</p> : null}
          <div className="profile-stats">
            <span>{profile.media_count || data.media?.length || 0} posts</span>
            <span>{profile.follower_count || 0} followers</span>
            <span>{profile.friend_count || data.friends?.length || 0} friends</span>
          </div>
        </div>
        {!isOwner ? <ProfileActions ctx={ctx} user={profile} onChanged={loadProfile} /> : null}
      </section>
      <section className="profile-sections">
        <div>
          <div className="section-head"><h2>Posts</h2><span>{data.media?.length || 0}</span></div>
          <MediaGrid ctx={ctx} items={data.media || []} emptyTitle="No public posts" />
        </div>
        <aside className="profile-rail">
          <div className="side-box"><h3>Collections</h3>{(data.collections || []).map((collection) => <CollectionMini collection={collection} key={collection.id} />)}{!data.collections?.length ? <p>No public collections.</p> : null}</div>
          <div className="side-box"><h3>Friends</h3>{(data.friends || []).map((friend) => <UserMini user={friend} key={friend.id} />)}{!data.friends?.length ? <p>No friends shown.</p> : null}</div>
        </aside>
      </section>
    </Page>
  );
}

function FriendsPage({ ctx }) {
  const [state, setState] = useState({ incoming: [], outgoing: [], friends: [] });
  const [loading, setLoading] = useState(true);

  const loadFriends = useCallback(async () => {
    if (!ctx.user) return;
    setLoading(true);
    try {
      const [requests, friends] = await Promise.all([
        apiFetch("/api/friends/requests"),
        apiFetch("/api/me/friends"),
      ]);
      setState({ incoming: requests.incoming || [], outgoing: requests.outgoing || [], friends: friends.friends || [] });
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setLoading(false);
    }
  }, [ctx]);

  useEffect(() => {
    loadFriends();
  }, [loadFriends]);

  async function respond(id, action) {
    try {
      await apiFetch(`/api/friends/requests/${id}`, { method: "POST", body: JSON.stringify({ action }) });
      await loadFriends();
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  if (!ctx.user) return <RequireLogin />;

  return (
    <Page title="Friends" eyebrow="Social" actions={<button type="button" onClick={loadFriends}><RefreshCw size={16} />Refresh</button>}>
      {loading ? <SkeletonGrid count={3} /> : (
        <section className="three-columns">
          <FriendColumn title="Incoming" rows={state.incoming} action={(row) => (
            <span className="inline-controls">
              <button type="button" onClick={() => respond(row.id, "accept")}><Check size={16} />Accept</button>
              <button type="button" onClick={() => respond(row.id, "decline")}><X size={16} />Decline</button>
            </span>
          )} />
          <FriendColumn title="Outgoing" rows={state.outgoing} action={(row) => <button type="button" onClick={() => respond(row.id, "cancel")}><X size={16} />Cancel</button>} />
          <div className="side-box"><div className="section-head"><h2>Friends</h2><span>{state.friends.length}</span></div>{state.friends.map((friend) => <UserMini user={friend} key={friend.id} />)}{!state.friends.length ? <EmptyState title="No friends yet" /> : null}</div>
        </section>
      )}
    </Page>
  );
}

function StudioPage({ ctx }) {
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);

  const loadStudio = useCallback(async () => {
    if (!ctx.user) return;
    setLoading(true);
    try {
      const data = await apiFetch("/api/me/media?include_deleted=true");
      setItems(data.media || []);
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setLoading(false);
    }
  }, [ctx]);

  useEffect(() => {
    loadStudio();
  }, [loadStudio]);

  if (!ctx.user) return <RequireLogin />;
  const totals = items.reduce((acc, item) => ({
    views: acc.views + Number(item.views || 0),
    likes: acc.likes + Number(item.likes || item.like_count || 0),
    downloads: acc.downloads + Number(item.downloads || item.download_count || 0),
  }), { views: 0, likes: 0, downloads: 0 });

  return (
    <Page title="Studio" eyebrow="Manage" actions={<button type="button" onClick={loadStudio}><RefreshCw size={16} />Refresh</button>}>
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

function UploadPage({ ctx }) {
  const navigate = useNavigate();
  const [form, setForm] = useState({
    file: null,
    title: "",
    description: "",
    category_id: "",
    category_name: "",
    subcategory_id: "",
    subcategory_name: "",
    tags: "",
    is_adult: false,
    visibility: "public",
    comments_enabled: true,
    downloads_enabled: true,
    pinned: false,
    auto_ai: true,
  });
  const [preview, setPreview] = useState("");
  const [busy, setBusy] = useState(false);
  const [analysis, setAnalysis] = useState(null);

  useEffect(() => {
    if (!form.file) {
      setPreview("");
      return undefined;
    }
    const url = URL.createObjectURL(form.file);
    setPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [form.file]);

  if (!ctx.user) return <RequireLogin />;

  function update(key, value) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  async function analyze() {
    if (!form.file) return;
    setBusy(true);
    try {
      const body = new FormData();
      body.set("file", form.file);
      body.set("title", form.title);
      body.set("description", form.description);
      body.set("tags", form.tags);
      const data = await apiFetch("/api/media/analyze", { method: "POST", body });
      setAnalysis(data.analysis);
      setForm((current) => ({
        ...current,
        title: current.title || data.analysis?.title || "",
        description: current.description || data.analysis?.description || "",
        category_name: current.category_name || data.analysis?.category_name || "",
        subcategory_name: current.subcategory_name || data.analysis?.subcategory_name || "",
        tags: current.tags || (data.analysis?.tags || []).join(", "),
        is_adult: current.is_adult || Boolean(data.analysis?.is_adult),
      }));
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  async function submit(event) {
    event.preventDefault();
    if (!form.file) return ctx.showToast("Choose a file first.", "error");
    if (form.file.size > MAX_UPLOAD_BYTES) return ctx.showToast("Upload is over the configured size limit.", "error");
    setBusy(true);
    try {
      const body = new FormData();
      Object.entries(form).forEach(([key, value]) => {
        if (key === "file" && value) body.set("file", value);
        else if (value !== null && value !== undefined) body.set(key, String(value));
      });
      const data = await apiFetch("/api/media", { method: "POST", body });
      clearApiCache();
      ctx.refreshLookups();
      ctx.showToast("Upload saved.", "success");
      navigate(`/media/${data.media.id}`);
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  const selectedCategory = ctx.lookups.categories.find((category) => String(category.id) === String(form.category_id));
  const subcategories = selectedCategory?.subcategories || selectedCategory?.children || [];

  return (
    <Page title="Upload" eyebrow="Create">
      <form className="upload-layout" onSubmit={submit}>
        <section className="upload-drop">
          <label className="file-picker">
            <input type="file" accept="image/*,video/*" onChange={(event) => update("file", event.target.files?.[0] || null)} />
            {preview ? (form.file?.type?.startsWith("video/") ? <video src={preview} muted playsInline /> : <img src={preview} alt="" />) : <Upload size={42} />}
            <span>{form.file?.name || "Choose media"}</span>
          </label>
          {analysis ? <ChipRow values={[analysis.media_kind, analysis.category_name, ...(analysis.tags || [])]} /> : null}
        </section>
        <section className="stacked-form">
          <label className="field"><span>Title</span><input value={form.title} onChange={(event) => update("title", event.target.value)} required maxLength={160} /></label>
          <label className="field"><span>Description</span><textarea value={form.description} onChange={(event) => update("description", event.target.value)} rows={4} maxLength={2000} /></label>
          <div className="two-col">
            <label className="field"><span>Category</span><select value={form.category_id} onChange={(event) => update("category_id", event.target.value)}><option value="">New category</option>{ctx.lookups.categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}</select></label>
            <label className="field"><span>Subcategory</span><select value={form.subcategory_id} onChange={(event) => update("subcategory_id", event.target.value)} disabled={!subcategories.length}><option value="">None</option>{subcategories.map((subcategory) => <option key={subcategory.id} value={subcategory.id}>{subcategory.name}</option>)}</select></label>
          </div>
          <div className="two-col">
            <label className="field"><span>New category</span><input value={form.category_name} onChange={(event) => update("category_name", event.target.value)} disabled={Boolean(form.category_id)} /></label>
            <label className="field"><span>New subcategory</span><input value={form.subcategory_name} onChange={(event) => update("subcategory_name", event.target.value)} /></label>
          </div>
          <label className="field"><span>Tags</span><input value={form.tags} onChange={(event) => update("tags", event.target.value)} placeholder="comma separated" /></label>
          <div className="two-col">
            <label className="field"><span>Visibility</span><select value={form.visibility} onChange={(event) => update("visibility", event.target.value)}><option value="public">Public</option><option value="unlisted">Unlisted</option><option value="private">Private</option></select></label>
            <div className="check-stack">
              <label className="check-row"><input checked={form.auto_ai} onChange={(event) => update("auto_ai", event.target.checked)} type="checkbox" />AI metadata</label>
              <label className="check-row"><input checked={form.is_adult} onChange={(event) => update("is_adult", event.target.checked)} type="checkbox" />18+</label>
              <label className="check-row"><input checked={form.comments_enabled} onChange={(event) => update("comments_enabled", event.target.checked)} type="checkbox" />Comments</label>
              <label className="check-row"><input checked={form.downloads_enabled} onChange={(event) => update("downloads_enabled", event.target.checked)} type="checkbox" />Downloads</label>
            </div>
          </div>
          <div className="form-actions">
            <button type="button" onClick={analyze} disabled={busy || !form.file}><WandSparkles size={16} />Analyze</button>
            <button className="primary" type="submit" disabled={busy || !form.file}><Upload size={16} />{busy ? "Working" : "Upload"}</button>
          </div>
        </section>
      </form>
    </Page>
  );
}

function SettingsPage({ ctx }) {
  const [profile, setProfile] = useState(() => ({
    display_name: ctx.user?.display_name || ctx.user?.username || "",
    bio: ctx.user?.bio || "",
    website_url: ctx.user?.website_url || "",
    location_label: ctx.user?.location_label || "",
    profile_headline: ctx.user?.profile_headline || "",
    featured_tags: (ctx.user?.featured_tags || []).join(", "),
    profile_color: ctx.user?.profile_color || ctx.settings.accent_color || "#37c9a7",
    public_profile: ctx.user?.public_profile !== false,
    show_liked_count: ctx.user?.show_liked_count !== false,
    show_collections: ctx.user?.show_collections !== false,
    show_recent_uploads: ctx.user?.show_recent_uploads !== false,
    show_friends: ctx.user?.show_friends !== false,
  }));
  const [prefs, setPrefs] = useState(ctx.settings);
  const [email, setEmail] = useState(ctx.user?.email || "");
  const [emailCode, setEmailCode] = useState("");
  const [age, setAge] = useState({ birthdate: "", confirm_over_18: false });
  const [password, setPassword] = useState({ old_password: "", new_password: "" });

  if (!ctx.user) return <RequireLogin />;

  function updateProfile(key, value) {
    setProfile((current) => ({ ...current, [key]: value }));
  }

  function updatePrefs(key, value) {
    setPrefs((current) => ({ ...current, [key]: value }));
  }

  async function saveProfile(event) {
    event.preventDefault();
    try {
      const profilePayload = {
        ...profile,
        featured_tags: profile.featured_tags.split(",").map((tag) => tag.trim()).filter(Boolean),
      };
      let data = await apiFetch("/api/me/profile", { method: "PATCH", body: JSON.stringify(profilePayload) });
      data = await apiFetch("/api/me/settings", { method: "PATCH", body: JSON.stringify(prefs) });
      ctx.setSessionUser(data.user);
      ctx.showToast("Settings saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function saveEmail(event) {
    event.preventDefault();
    try {
      const data = await apiFetch("/api/me/email", { method: "POST", body: JSON.stringify({ email }) });
      ctx.setSessionUser(data.user);
      ctx.showToast(data.email_verification_sent ? "Verification sent." : "Email saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function verifyEmail(event) {
    event.preventDefault();
    try {
      const data = await apiFetch("/api/me/email/verify", { method: "POST", body: JSON.stringify({ code: emailCode }) });
      ctx.setSessionUser(data.user);
      setEmailCode("");
      ctx.showToast("Email verified.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function saveAvatar(event) {
    const file = event.target.files?.[0];
    if (!file) return;
    try {
      const body = new FormData();
      body.set("file", file);
      const data = await apiFetch("/api/me/avatar", { method: "POST", body });
      ctx.setSessionUser(data.user);
      ctx.showToast("Avatar saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function saveAge(event) {
    event.preventDefault();
    try {
      const data = await apiFetch("/api/me/age-verification", { method: "POST", body: JSON.stringify(age) });
      ctx.setSessionUser(data.user);
      ctx.showToast("Age verification saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function changePassword(event) {
    event.preventDefault();
    try {
      await apiFetch("/api/me/password", { method: "POST", body: JSON.stringify(password) });
      setPassword({ old_password: "", new_password: "" });
      ctx.showToast("Password changed.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  return (
    <Page title="Settings" eyebrow="Account">
      <section className="settings-grid">
        <form className="stacked-form side-box" onSubmit={saveProfile}>
          <h2><UserRound size={18} /> Profile</h2>
          <label className="field"><span>Display name</span><input value={profile.display_name} onChange={(event) => updateProfile("display_name", event.target.value)} required /></label>
          <label className="field"><span>Headline</span><input value={profile.profile_headline} onChange={(event) => updateProfile("profile_headline", event.target.value)} /></label>
          <label className="field"><span>Bio</span><textarea value={profile.bio} onChange={(event) => updateProfile("bio", event.target.value)} rows={4} /></label>
          <div className="two-col">
            <label className="field"><span>Website</span><input value={profile.website_url} onChange={(event) => updateProfile("website_url", event.target.value)} /></label>
            <label className="field"><span>Location</span><input value={profile.location_label} onChange={(event) => updateProfile("location_label", event.target.value)} /></label>
          </div>
          <label className="field"><span>Featured tags</span><input value={profile.featured_tags} onChange={(event) => updateProfile("featured_tags", event.target.value)} /></label>
          <label className="field color-field"><span>Color</span><input value={profile.profile_color} onChange={(event) => updateProfile("profile_color", event.target.value)} type="color" /></label>
          <div className="check-stack">
            <label className="check-row"><input checked={profile.public_profile} onChange={(event) => updateProfile("public_profile", event.target.checked)} type="checkbox" />Public profile</label>
            <label className="check-row"><input checked={profile.show_collections} onChange={(event) => updateProfile("show_collections", event.target.checked)} type="checkbox" />Collections</label>
            <label className="check-row"><input checked={profile.show_recent_uploads} onChange={(event) => updateProfile("show_recent_uploads", event.target.checked)} type="checkbox" />Uploads</label>
            <label className="check-row"><input checked={profile.show_friends} onChange={(event) => updateProfile("show_friends", event.target.checked)} type="checkbox" />Friends</label>
          </div>
          <button className="primary" type="submit"><Save size={16} />Save</button>
        </form>
        <form className="stacked-form side-box" onSubmit={saveProfile}>
          <h2><Palette size={18} /> Preferences</h2>
          <div className="two-col">
            <label className="field"><span>Theme</span><select value={prefs.theme_mode} onChange={(event) => updatePrefs("theme_mode", event.target.value)}><option value="system">System</option><option value="dark">Dark</option><option value="light">Light</option></select></label>
            <label className="field"><span>Grid</span><select value={prefs.grid_density} onChange={(event) => updatePrefs("grid_density", event.target.value)}><option value="compact">Compact</option><option value="comfortable">Comfortable</option><option value="large">Large</option></select></label>
          </div>
          <div className="two-col">
            <label className="field"><span>Sort</span><select value={prefs.default_sort} onChange={(event) => updatePrefs("default_sort", event.target.value)}><option value="new">Newest</option><option value="popular">Popular</option><option value="views">Views</option><option value="downloads">Downloads</option></select></label>
            <label className="field"><span>Items</span><input type="number" min="12" max="60" value={prefs.items_per_page} onChange={(event) => updatePrefs("items_per_page", Number(event.target.value))} /></label>
          </div>
          <div className="check-stack">
            <label className="check-row"><input checked={prefs.autoplay_previews} onChange={(event) => updatePrefs("autoplay_previews", event.target.checked)} type="checkbox" />Autoplay</label>
            <label className="check-row"><input checked={prefs.muted_previews} onChange={(event) => updatePrefs("muted_previews", event.target.checked)} type="checkbox" />Muted previews</label>
            <label className="check-row"><input checked={prefs.reduce_motion} onChange={(event) => updatePrefs("reduce_motion", event.target.checked)} type="checkbox" />Reduced motion</label>
            <label className="check-row"><input checked={prefs.open_original_in_new_tab} onChange={(event) => updatePrefs("open_original_in_new_tab", event.target.checked)} type="checkbox" />Originals in new tab</label>
          </div>
          <button className="primary" type="submit"><Save size={16} />Save</button>
        </form>
        <div className="side-box stacked-form">
          <h2><ShieldCheck size={18} /> Identity</h2>
          <label className="field"><span>Avatar</span><input type="file" accept="image/*" onChange={saveAvatar} /></label>
          <form className="mini-form" onSubmit={saveEmail}>
            <label className="field"><span>Email</span><input type="email" value={email} onChange={(event) => setEmail(event.target.value)} /></label>
            <button type="submit"><Mail size={16} />Save Email</button>
          </form>
          <form className="mini-form" onSubmit={verifyEmail}>
            <label className="field"><span>Code</span><input value={emailCode} onChange={(event) => setEmailCode(event.target.value)} /></label>
            <button type="submit"><Check size={16} />Verify</button>
          </form>
          <form className="mini-form" onSubmit={saveAge}>
            <label className="field"><span>Birthdate</span><input type="date" value={age.birthdate} onChange={(event) => setAge((current) => ({ ...current, birthdate: event.target.value }))} /></label>
            <label className="check-row"><input checked={age.confirm_over_18} onChange={(event) => setAge((current) => ({ ...current, confirm_over_18: event.target.checked }))} type="checkbox" />I am 18+</label>
            <button type="submit"><ShieldCheck size={16} />Verify Age</button>
          </form>
        </div>
        <form className="side-box stacked-form" onSubmit={changePassword}>
          <h2><KeyRound size={18} /> Password</h2>
          <label className="field"><span>Current</span><input type="password" value={password.old_password} onChange={(event) => setPassword((current) => ({ ...current, old_password: event.target.value }))} /></label>
          <label className="field"><span>New</span><input type="password" value={password.new_password} onChange={(event) => setPassword((current) => ({ ...current, new_password: event.target.value }))} /></label>
          <button type="submit">Change</button>
        </form>
      </section>
    </Page>
  );
}

function AuthPage({ ctx }) {
  const [mode, setMode] = useState("login");
  const [form, setForm] = useState({ username: "", password: "", email: "", display_name: "" });
  const [busy, setBusy] = useState(false);

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    try {
      const payload = mode === "login"
        ? { username: form.username, password: form.password }
        : form;
      const data = await apiFetch(mode === "login" ? "/api/auth/login" : "/api/auth/register", {
        method: "POST",
        body: JSON.stringify(payload),
        token: "",
      });
      ctx.loginWith(data);
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  return (
    <Page title={mode === "login" ? "Login" : "Register"} eyebrow="Account">
      <form className="auth-card stacked-form" onSubmit={submit}>
        <Segmented value={mode} onChange={setMode} options={[["login", "Login"], ["register", "Register"]]} />
        <label className="field"><span>Username</span><input value={form.username} onChange={(event) => setForm((current) => ({ ...current, username: event.target.value }))} required /></label>
        {mode === "register" ? <label className="field"><span>Display name</span><input value={form.display_name} onChange={(event) => setForm((current) => ({ ...current, display_name: event.target.value }))} /></label> : null}
        {mode === "register" ? <label className="field"><span>Email</span><input type="email" value={form.email} onChange={(event) => setForm((current) => ({ ...current, email: event.target.value }))} /></label> : null}
        <label className="field"><span>Password</span><input type="password" value={form.password} onChange={(event) => setForm((current) => ({ ...current, password: event.target.value }))} required /></label>
        <button className="primary" disabled={busy} type="submit"><LogIn size={16} />{busy ? "Working" : mode === "login" ? "Login" : "Create Account"}</button>
      </form>
    </Page>
  );
}

function MediaGrid({ ctx, items, loading = false, emptyTitle = "No media", onItemUpdated }) {
  if (loading) return <SkeletonGrid count={8} />;
  if (!items?.length) return <EmptyState title={emptyTitle} />;
  return (
    <div className="media-grid">
      {items.map((item) => <MediaCard ctx={ctx} item={item} key={item.id} onItemUpdated={onItemUpdated} />)}
    </div>
  );
}

function MediaCard({ ctx, item, onItemUpdated }) {
  const actions = useMediaActions(ctx, onItemUpdated);
  return (
    <article className={`media-card ${item.locked ? "is-locked" : ""}`}>
      <Link className="media-link" to={`/media/${item.id}`} aria-label={item.title || `Open media ${item.id}`}>
        <div className="thumb-frame">
          {item.locked ? <Lock size={34} /> : item.media_kind === "video" ? <video muted playsInline preload="metadata" src={item.url} poster={thumbUrl(item)} /> : <img src={thumbUrl(item)} alt={item.title || ""} loading="lazy" />}
          <span className="kind-badge">{item.media_kind === "video" ? <Film size={14} /> : <ImageIcon size={14} />}{item.media_kind || "image"}</span>
        </div>
        <div className="media-copy">
          <h3>{item.title || "Untitled"}</h3>
          <p>{item.category_name || "Unsorted"}{item.subcategory_name ? ` / ${item.subcategory_name}` : ""}</p>
        </div>
      </Link>
      <div className="card-meta">
        <Link to={`/users/${item.username || ""}`} className="user-chip"><Avatar user={item} compact />{item.display_name || item.username || "User"}</Link>
        <span>{formatDate(item.created_at || item.uploaded_at)}</span>
      </div>
      <div className="card-actions">
        <button type="button" onClick={() => actions.toggleLike(item)} title={item.liked_by_me ? "Unlike" : "Like"}><Heart size={16} className={item.liked_by_me ? "filled" : ""} />{numberish(item.likes || item.like_count)}</button>
        <button type="button" onClick={() => actions.toggleBookmark(item)} title={item.bookmarked_by_me ? "Remove bookmark" : "Bookmark"}><Bookmark size={16} className={item.bookmarked_by_me ? "filled" : ""} /></button>
        <button type="button" onClick={() => actions.download(item)} title="Download"><Download size={16} /></button>
      </div>
    </article>
  );
}

function MediaControls({ ctx, media, onChanged }) {
  const [draft, setDraft] = useState({
    visibility: media.visibility || "public",
    comments_enabled: media.comments_enabled !== false,
    downloads_enabled: media.downloads_enabled !== false,
    pinned: Boolean(media.pinned_at || media.pinned),
  });

  useEffect(() => {
    setDraft({
      visibility: media.visibility || "public",
      comments_enabled: media.comments_enabled !== false,
      downloads_enabled: media.downloads_enabled !== false,
      pinned: Boolean(media.pinned_at || media.pinned),
    });
  }, [media]);

  async function save() {
    try {
      const data = await apiFetch(`/api/media/${media.id}/controls`, {
        method: "PATCH",
        body: JSON.stringify(draft),
      });
      clearApiCache();
      onChanged(data.media);
      ctx.showToast("Controls saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function remove() {
    try {
      await apiFetch(`/api/media/${media.id}`, { method: "DELETE" });
      ctx.showToast("Post deleted.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function restore() {
    try {
      const data = await apiFetch(`/api/media/${media.id}/restore`, { method: "POST" });
      onChanged(data.media);
      ctx.showToast("Post restored.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  return (
    <section className="side-box">
      <h3>Controls</h3>
      <label className="field"><span>Visibility</span><select value={draft.visibility} onChange={(event) => setDraft((current) => ({ ...current, visibility: event.target.value }))}><option value="public">Public</option><option value="unlisted">Unlisted</option><option value="private">Private</option></select></label>
      <label className="check-row"><input checked={draft.comments_enabled} onChange={(event) => setDraft((current) => ({ ...current, comments_enabled: event.target.checked }))} type="checkbox" />Comments</label>
      <label className="check-row"><input checked={draft.downloads_enabled} onChange={(event) => setDraft((current) => ({ ...current, downloads_enabled: event.target.checked }))} type="checkbox" />Downloads</label>
      <label className="check-row"><input checked={draft.pinned} onChange={(event) => setDraft((current) => ({ ...current, pinned: event.target.checked }))} type="checkbox" />Pinned</label>
      <div className="inline-controls">
        <button type="button" onClick={save}><Save size={16} />Save</button>
        {media.deleted_at ? <button type="button" onClick={restore}><RefreshCw size={16} />Restore</button> : <button type="button" className="danger" onClick={remove}><Trash2 size={16} />Delete</button>}
      </div>
    </section>
  );
}

function StudioItem({ ctx, item, onChanged, onRemoved }) {
  async function remove() {
    try {
      await apiFetch(`/api/media/${item.id}`, { method: "DELETE" });
      onRemoved(item.id);
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  return (
    <article className="studio-item">
      <Link to={`/media/${item.id}`} className="studio-thumb">{item.media_kind === "video" ? <video muted src={item.url} poster={thumbUrl(item)} /> : <img src={thumbUrl(item)} alt="" />}</Link>
      <div>
        <h3>{item.title || "Untitled"}</h3>
        <p>{item.visibility || "public"} / {formatBytes(item.file_size)} / {formatDate(item.created_at || item.uploaded_at)}</p>
        <StatsRow item={item} compact />
      </div>
      <div className="studio-actions">
        <MediaControls ctx={ctx} media={item} onChanged={onChanged} />
        {!item.deleted_at ? <button className="danger" type="button" onClick={remove}><Trash2 size={16} />Delete</button> : null}
      </div>
    </article>
  );
}

function useMediaActions(ctx, onItemUpdated) {
  const navigate = useNavigate();
  const requireAuth = useCallback(() => {
    if (ctx.user) return true;
    navigate("/login");
    return false;
  }, [ctx.user, navigate]);

  const update = useCallback((item) => {
    clearApiCache();
    onItemUpdated?.(item);
  }, [onItemUpdated]);

  return {
    async toggleLike(item) {
      if (!requireAuth()) return;
      try {
        const data = await apiFetch(`/api/media/${item.id}/like`, {
          method: "POST",
          body: JSON.stringify({ liked: !item.liked_by_me }),
        });
        update(data.media);
      } catch (error) {
        ctx.showToast(error.message, "error");
      }
    },
    async toggleBookmark(item) {
      if (!requireAuth()) return;
      try {
        const data = await apiFetch(`/api/media/${item.id}/bookmark`, {
          method: "POST",
          body: JSON.stringify({ bookmarked: !item.bookmarked_by_me }),
        });
        update(data.media);
      } catch (error) {
        ctx.showToast(error.message, "error");
      }
    },
    download(item) {
      if (!item.downloads_enabled && Number(item.user_id) !== Number(ctx.user?.id)) {
        ctx.showToast("Downloads are disabled for this post.", "error");
        return;
      }
      window.open(item.download_url || `/api/media/${item.id}/download`, "_blank", "noopener,noreferrer");
    },
  };
}

function ProfileActions({ ctx, user, onChanged }) {
  async function follow() {
    try {
      await apiFetch(`/api/users/${user.id}/follow`, {
        method: "POST",
        body: JSON.stringify({ following: !user.following_by_me }),
      });
      onChanged();
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function friend() {
    try {
      await apiFetch(`/api/users/${user.id}/friend-request`, { method: "POST" });
      onChanged();
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  if (!ctx.user) return <Link className="button-link" to="/login"><LogIn size={16} />Login</Link>;
  return (
    <div className="profile-actions">
      <button type="button" onClick={follow}><Heart size={16} />{user.following_by_me ? "Unfollow" : "Follow"}</button>
      <button type="button" onClick={friend} disabled={["friends", "pending_out", "self"].includes(user.friend_status)}><UserPlus size={16} />{friendLabel(user.friend_status)}</button>
    </div>
  );
}

function UserCard({ ctx, user }) {
  return (
    <article className="user-card">
      <Avatar user={user} large />
      <div>
        <Link to={`/users/${user.username}`}><h3>{user.display_name || user.username}</h3></Link>
        <p>@{user.username}{user.profile_headline ? ` / ${user.profile_headline}` : ""}</p>
      </div>
      <ProfileActions ctx={ctx} user={user} onChanged={() => clearApiCache("/api/users/search")} />
    </article>
  );
}

function FriendColumn({ title, rows, action }) {
  return (
    <div className="side-box">
      <div className="section-head"><h2>{title}</h2><span>{rows.length}</span></div>
      {rows.map((row) => (
        <article className="friend-request" key={row.id}>
          <UserMini user={row.user || row} />
          {action(row)}
        </article>
      ))}
      {!rows.length ? <EmptyState title="None" /> : null}
    </div>
  );
}

function Page({ title, eyebrow, actions, children }) {
  return (
    <div className="page">
      <header className="page-head">
        <div>
          <p>{eyebrow}</p>
          <h1>{title}</h1>
        </div>
        {actions ? <div className="page-actions">{actions}</div> : null}
      </header>
      {children}
    </div>
  );
}

function Pager({ page, hasNext, loading, onPage }) {
  return (
    <nav className="pager" aria-label="Pages">
      <button type="button" disabled={loading || page <= 1} onClick={() => onPage(Math.max(1, page - 1))}>Previous</button>
      <span>Page {page}</span>
      <button type="button" disabled={loading || !hasNext} onClick={() => onPage(page + 1)}>Next</button>
    </nav>
  );
}

function TagCloud({ tags, onPick }) {
  if (!tags?.length) return null;
  return (
    <section className="tag-cloud">
      <h3>Tags</h3>
      <div>
        {tags.slice(0, 32).map((tag) => {
          const name = tag.name || tag.tag || String(tag);
          return <button type="button" key={name} onClick={() => onPick(tag)}>{name}</button>;
        })}
      </div>
    </section>
  );
}

function Segmented({ value, onChange, options }) {
  return (
    <div className="segmented">
      {options.map(([key, label]) => <button type="button" className={value === key ? "active" : ""} onClick={() => onChange(key)} key={key}>{label}</button>)}
    </div>
  );
}

function Avatar({ user, compact = false, large = false }) {
  const src = user?.avatar_url || user?.user_avatar_url;
  const label = initials(user?.display_name || user?.username || "IG");
  return <span className={`avatar ${compact ? "compact" : ""} ${large ? "large" : ""}`}>{src ? <img src={src} alt="" /> : label}</span>;
}

function UserLine({ user }) {
  return (
    <Link className="owner-line" to={`/users/${user.username || ""}`}>
      <Avatar user={user} />
      <span><strong>{user.display_name || user.username || "User"}</strong><small>@{user.username || "user"}</small></span>
    </Link>
  );
}

function StatsRow({ item, compact = false }) {
  return (
    <div className={`stats-row ${compact ? "compact" : ""}`}>
      <span><Heart size={14} />{numberish(item.likes || item.like_count)}</span>
      <span><Eye size={14} />{numberish(item.views)}</span>
      <span><Download size={14} />{numberish(item.downloads || item.download_count)}</span>
      <span><MessageCircle size={14} />{numberish(item.comment_count)}</span>
    </div>
  );
}

function ChipRow({ values }) {
  const chips = (values || []).filter(Boolean).slice(0, 18);
  if (!chips.length) return null;
  return <div className="chip-row">{chips.map((value) => <span key={`${value}`}>{value}</span>)}</div>;
}

function CollectionCover({ collection }) {
  return <span className="collection-cover">{collection.cover_url ? <img src={collection.cover_url} alt="" /> : <Folder size={20} />}</span>;
}

function CollectionMini({ collection }) {
  return (
    <Link className="mini-row" to="/collections">
      <CollectionCover collection={collection} />
      <span><strong>{collection.name}</strong><small>{collection.item_count || 0} posts</small></span>
    </Link>
  );
}

function UserMini({ user }) {
  return (
    <Link className="mini-row" to={`/users/${user.username || ""}`}>
      <Avatar user={user} compact />
      <span><strong>{user.display_name || user.username || "User"}</strong><small>@{user.username || "user"}</small></span>
    </Link>
  );
}

function Metric({ label, value }) {
  return <article className="metric"><strong>{numberish(value)}</strong><span>{label}</span></article>;
}

function Notice({ kind = "info", children }) {
  return <div className={`notice ${kind}`} role="alert">{children}</div>;
}

function EmptyState({ title }) {
  return <div className="empty-state"><Sparkles size={24} /><h2>{title}</h2></div>;
}

function RequireLogin() {
  return (
    <Page title="Login required" eyebrow="Account">
      <div className="empty-state"><Lock size={26} /><h2>Login required</h2><Link className="button-link primary" to="/login"><LogIn size={16} />Login</Link></div>
    </Page>
  );
}

function NotFound() {
  return <Page title="Not Found" eyebrow="404"><EmptyState title="That page is not available" /></Page>;
}

function SkeletonGrid({ count = 8 }) {
  return <div className="media-grid skeleton-grid">{Array.from({ length: count }, (_, index) => <div className="skeleton-card" key={index} />)}</div>;
}

function SkeletonList() {
  return <div className="skeleton-list">{Array.from({ length: 6 }, (_, index) => <div className="skeleton-row" key={index} />)}</div>;
}

function thumbUrl(item) {
  if (!item) return "";
  if (item.locked) return "";
  if (item.preview_url) return item.preview_url;
  if (item.url) return item.url;
  return `/api/media/${item.id}/thumb?w=640`;
}

function replaceMedia(rows, updated) {
  if (!updated) return rows;
  return rows.map((item) => Number(item.id) === Number(updated.id) ? updated : item);
}

function preloadMediaAssets(items) {
  if (typeof Image === "undefined") return;
  items.forEach((item) => {
    const src = thumbUrl(item);
    if (!src || item.media_kind === "video") return;
    const image = new Image();
    image.decoding = "async";
    image.loading = "eager";
    image.src = src;
  });
}

function formatDate(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

function formatBytes(value) {
  const bytes = Number(value || 0);
  if (!bytes) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  return `${(bytes / (1024 ** index)).toFixed(index ? 1 : 0)} ${units[index]}`;
}

function numberish(value) {
  return new Intl.NumberFormat().format(Number(value || 0));
}

function initials(value) {
  return String(value || "IG").trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "IG";
}

function safeColor(value) {
  return /^#[0-9a-f]{6}$/i.test(value || "") ? value : "#37c9a7";
}

function friendLabel(status) {
  if (status === "friends") return "Friends";
  if (status === "pending_out") return "Pending";
  if (status === "pending_in") return "Respond";
  if (status === "self") return "You";
  return "Friend";
}

export default App;
