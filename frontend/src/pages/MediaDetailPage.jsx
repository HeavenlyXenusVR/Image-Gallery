import { useCallback, useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { Bookmark, Download, Heart, Lock, MessageCircle, Save, Trash2 } from "lucide-react";
import { apiFetch } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { useMediaActions } from "../hooks/useMediaActions.js";
import { MediaControls } from "../components/media.jsx";
import { Avatar, ChipRow, EmptyState, Notice, NotFound, Page, SkeletonGrid, StatsRow, UserLine } from "../components/ui.jsx";
import { thumbUrl } from "../utils/media.js";

export function MediaDetailPage({ ctx }) {
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

  const loadDetail = useCallback(async ({ background = false } = {}) => {
    if (!background) {
      setLoading(true);
      setError("");
    }
    try {
      const data = await apiFetch(`/api/media/${mediaId}`);
      setMedia(data.media);
      setComments(data.comments || []);
      if (ctx.user) {
        const mine = await apiFetch("/api/collections?mine=true").catch(() => ({ collections: [] }));
        setCollections(mine.collections || []);
      }
    } catch (fetchError) {
      if (!background) {
        setError(fetchError.message);
        setMedia(null);
      }
    } finally {
      if (!background) setLoading(false);
    }
  }, [ctx.user, mediaId]);

  useEffect(() => {
    loadDetail();
  }, [loadDetail]);

  useLiveRefresh(() => loadDetail({ background: true }), { enabled: Boolean(mediaId), interval: 24_000 });

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
