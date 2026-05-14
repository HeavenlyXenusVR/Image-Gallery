import { memo, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Bookmark, Download, Film, Heart, Image as ImageIcon, Lock, RefreshCw, Save, Trash2 } from "lucide-react";
import { apiFetch, clearApiCache } from "../api.js";
import { useMediaActions } from "../hooks/useMediaActions.js";
import { formatBytes, formatDate, numberish } from "../utils/format.js";
import { isPerfLiteRuntime, thumbUrl } from "../utils/media.js";
import { Avatar, EmptyState, SkeletonGrid, StatsRow } from "./ui.jsx";

export function MediaGrid({ ctx, items, loading = false, emptyTitle = "No media", onItemUpdated }) {
  if (loading) return <SkeletonGrid count={8} />;
  if (!items?.length) return <EmptyState title={emptyTitle} />;
  const eagerCount = isPerfLiteRuntime() ? 1 : 4;
  return (
    <div className="media-grid">
      {items.map((item, index) => <MediaCard ctx={ctx} item={item} key={item.id} eager={index < eagerCount} onItemUpdated={onItemUpdated} />)}
    </div>
  );
}

export const MediaCard = memo(function MediaCard({ ctx, item, eager = false, onItemUpdated }) {
  const actions = useMediaActions(ctx, onItemUpdated);
  const thumb = thumbUrl(item);
  return (
    <article className={`media-card ${item.locked ? "is-locked" : ""}`}>
      <Link className="media-link" to={`/media/${item.id}`} aria-label={item.title || `Open media ${item.id}`}>
        <div className="thumb-frame">
          {item.locked ? <Lock size={34} /> : item.media_kind === "video" ? <div className="video-thumb-placeholder"><Film size={34} /></div> : <img src={thumb} alt={item.title || ""} loading={eager ? "eager" : "lazy"} decoding="async" fetchPriority={eager ? "high" : "auto"} />}
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
});

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

export function StudioItem({ ctx, item, onChanged, onRemoved }) {
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
      <Link to={`/media/${item.id}`} className="studio-thumb">{item.media_kind === "video" ? <div className="video-thumb-placeholder"><Film size={26} /></div> : <img src={thumbUrl(item)} alt="" loading="lazy" decoding="async" />}</Link>
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
