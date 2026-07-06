import { memo, useMemo, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Bookmark, Copy, Download, ExternalLink, Film, FolderPlus, Heart, Image as ImageIcon, Link as LinkIcon, Lock, RefreshCw, Save, Trash2 } from "lucide-react";
import { apiFetch, clearApiCache } from "../api.js";
import { useMediaActions } from "../hooks/useMediaActions.js";
import { formatBytes, formatDate, numberish } from "../utils/format.js";
import { isGifMedia, isPerfLiteRuntime, mediaImageSources, thumbUrl, videoQualityUrl } from "../utils/media.js";
import { Avatar, EmptyState, ResilientImage, SkeletonGrid, StatsRow } from "./ui.jsx";

function subcategoryNames(item) {
  if (Array.isArray(item?.subcategory_names) && item.subcategory_names.length) return item.subcategory_names;
  if (Array.isArray(item?.subcategories) && item.subcategories.length) return item.subcategories.map((row) => row?.name).filter(Boolean);
  return item?.subcategory_name ? [item.subcategory_name] : [];
}

export function MediaGrid({ ctx, items, loading = false, emptyTitle = "No media", onItemUpdated, onOpen, extraClass = "" }) {
  if (loading) return <SkeletonGrid count={8} />;
  if (!items?.length) return <EmptyState title={emptyTitle} />;
  const eagerCount = isPerfLiteRuntime() ? 1 : 4;
  const densityClass = `media-grid-${ctx.settings.grid_density || "comfortable"}`;
  return (
    <div className={["media-grid", densityClass, extraClass].filter(Boolean).join(" ")}>
      {items.map((item, index) => (
        <MediaCard
          ctx={ctx}
          item={item}
          key={item.id}
          eager={index < eagerCount}
          onItemUpdated={onItemUpdated}
          onOpen={onOpen ? () => onOpen(items, index) : undefined}
        />
      ))}
    </div>
  );
}

export const MediaCard = memo(function MediaCard({ ctx, item, eager = false, onItemUpdated, onOpen }) {
  const actions = useMediaActions(ctx, onItemUpdated);
  const thumb = useMemo(() => (item.media_kind === "video" ? thumbUrl(item, 420) : thumbUrl(item)), [item]);
  const mutedPreview = ctx.settings.muted_previews !== false;
  const liveVideoPreview = item.media_kind === "video" && ctx.settings.autoplay_previews && item.url && !isPerfLiteRuntime();
  const previewSrc = useMemo(() => (liveVideoPreview ? videoQualityUrl(item, "low") : ""), [liveVideoPreview, item]);
  const categoryLine = useMemo(() => [item.category_name || "Unsorted", ...subcategoryNames(item)].filter(Boolean).join(" / "), [item]);
  const imageSources = useMemo(() => mediaImageSources(item, { width: eager ? 720 : 640, previewSize: "detail" }), [item, eager]);
  const videoThumbSources = useMemo(() => mediaImageSources(item, { width: 420, previewSize: "card" }), [item]);
  return (
    <article className={`media-card ${item.locked ? "is-locked" : ""}`}>
      <Link
        className="media-link"
        to={`/media/${item.id}`}
        aria-label={item.title || `Open media ${item.id}`}
        onClick={onOpen ? (e) => { if (!e.ctrlKey && !e.metaKey && !e.shiftKey && !e.altKey) { e.preventDefault(); onOpen(); } } : undefined}
      >
        <div className="thumb-frame">
          {item.locked ? <Lock size={34} /> : item.media_kind === "video" ? (
            liveVideoPreview ? (
              <video
                className={`video-thumb ${ctx.settings.blur_video_previews ? "blurred-video-thumb" : ""}`}
                key={previewSrc}
                src={previewSrc}
                poster={thumb}
                muted={mutedPreview}
                autoPlay={mutedPreview}
                controls={!mutedPreview}
                loop
                playsInline
                preload="metadata"
              />
            ) : thumb ? <ResilientImage className={`video-thumb ${ctx.settings.blur_video_previews ? "blurred-video-thumb" : ""}`} sources={videoThumbSources} diagnostics={{ mediaId: item.id, mediaKind: item.media_kind, context: "grid-video-thumb" }} alt="" loading={eager ? "eager" : "lazy"} decoding="async" fetchPriority={eager ? "high" : "auto"} fallback={<div className="video-thumb-placeholder"><Film size={34} /></div>} /> : <div className="video-thumb-placeholder"><Film size={34} /></div>
          ) : <ResilientImage className={isGifMedia(item) ? "gif-thumb" : ""} sources={imageSources} diagnostics={{ mediaId: item.id, mediaKind: item.media_kind, context: "grid-image" }} alt={item.title || ""} loading={eager ? "eager" : "lazy"} decoding="async" fetchPriority={eager ? "high" : "auto"} fallback={<div className="video-thumb-placeholder"><ImageIcon size={34} /></div>} />}
          <span className="kind-badge">{item.media_kind === "video" ? <Film size={14} /> : <ImageIcon size={14} />}{item.media_kind || "image"}</span>
        </div>
        <div className="media-copy">
          <h3>{item.title || "Untitled"}</h3>
          <p>{categoryLine}</p>
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
        <button type="button" onClick={() => actions.copyAddress(item)} title="Copy media URL"><Copy size={16} /></button>
        <CollectionSaveControl ctx={ctx} media={item} compact />
      </div>
    </article>
  );
});

export function CollectionSaveControl({ ctx, media, compact = false, openLabel = "Collect" }) {
  const [open, setOpen] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [collections, setCollections] = useState([]);
  const [collectionId, setCollectionId] = useState("");

  async function loadCollections() {
    if (!ctx.user) return;
    setLoading(true);
    try {
      const data = await apiFetch("/api/collections?mine=true");
      const rows = data.collections || [];
      setCollections(rows);
      setCollectionId((current) => current || String(rows[0]?.id || ""));
      setLoaded(true);
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setLoading(false);
    }
  }

  async function togglePanel() {
    if (!ctx.user) {
      ctx.showToast("Login required to use collections.", "error");
      return;
    }
    const nextOpen = !open;
    setOpen(nextOpen);
    if (nextOpen && !loaded && !loading) await loadCollections();
  }

  async function saveToCollection() {
    if (!collectionId || !media?.id) return;
    setSaving(true);
    try {
      await apiFetch(`/api/collections/${collectionId}/items`, {
        method: "POST",
        body: JSON.stringify({ media_id: media.id, saved: true }),
      });
      clearApiCache();
      const target = collections.find((collection) => String(collection.id) === String(collectionId));
      ctx.showToast(`Added to ${target?.name || "collection"}.`, "success");
      setOpen(false);
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setSaving(false);
    }
  }

  return (
    <>
      <button className="collection-save-toggle" type="button" onClick={togglePanel} title="Add to collection">
        <FolderPlus size={16} />{compact ? <span className="sr-only">{openLabel}</span> : openLabel}
      </button>
      {open ? (
        <div className="collection-inline-panel">
          <strong>Add this post to a collection</strong>
          {loading ? <p>Loading collections…</p> : collections.length ? (
            <div className="inline-controls collection-save-controls">
              <select value={collectionId} onChange={(event) => setCollectionId(event.target.value)} aria-label="Choose collection">
                {collections.map((collection) => <option key={collection.id} value={collection.id}>{collection.name}</option>)}
              </select>
              <button type="button" onClick={saveToCollection} disabled={saving || !collectionId}>
                <Save size={16} />{saving ? "Adding" : "Add"}
              </button>
            </div>
          ) : (
            <div className="collection-empty-hint">
              <p>You do not have any collections yet.</p>
              <Link className="button-link" to="/collections">Create one</Link>
            </div>
          )}
        </div>
      ) : null}
    </>
  );
}

export function MediaControls({ ctx, media, onChanged }) {
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
    if (!window.confirm("Delete this post? This cannot be undone from here.")) return;
    try {
      await apiFetch(`/api/media/${media.id}`, { method: "DELETE" });
      ctx.showToast("Post deleted.", "success");
      onChanged(null);
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

export function MediaActionPanel({ ctx, media, actions }) {
  return (
    <section className="side-box media-action-panel">
      <h3>Post Actions</h3>
      <button type="button" onClick={() => actions.copyAddress(media)}><Copy size={16} />Copy Media URL</button>
      <button type="button" onClick={() => actions.copyPageLink(media)}><LinkIcon size={16} />Copy Page Link</button>
      <button type="button" onClick={() => actions.openOriginal(media)}><ExternalLink size={16} />Open Original</button>
      <button type="button" onClick={() => actions.download(media)}><Download size={16} />Save File</button>
      <CollectionSaveControl ctx={ctx} media={media} openLabel="Add to Collection" />
    </section>
  );
}

export function StudioItem({ ctx, item, onChanged, onRemoved, selected = false, onToggleSelect }) {
  async function remove() {
    if (!window.confirm("Delete this post? This cannot be undone from here.")) return;
    try {
      await apiFetch(`/api/media/${item.id}`, { method: "DELETE" });
      onRemoved(item.id);
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  return (
    <article className={`studio-item ${selected ? "is-selected" : ""}`}>
      {onToggleSelect ? (
        <label className="studio-select">
          <input type="checkbox" checked={selected} onChange={onToggleSelect} aria-label={`Select ${item.title || "post"}`} />
        </label>
      ) : null}
      <Link to={`/media/${item.id}`} className="studio-thumb">
        {item.media_kind === "video"
          ? <ResilientImage className={ctx.settings.blur_video_previews ? "blurred-video-thumb" : ""} sources={mediaImageSources(item, { width: 420, previewSize: "card" })} diagnostics={{ mediaId: item.id, mediaKind: item.media_kind, context: "studio-video-thumb" }} alt="" loading="lazy" decoding="async" fallback={<div className="video-thumb-placeholder"><Film size={34} /></div>} />
          : <ResilientImage sources={mediaImageSources(item, { width: 640, previewSize: "detail" })} diagnostics={{ mediaId: item.id, mediaKind: item.media_kind, context: "studio-image" }} alt="" loading="lazy" decoding="async" fallback={<div className="video-thumb-placeholder"><ImageIcon size={34} /></div>} />}
      </Link>
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
