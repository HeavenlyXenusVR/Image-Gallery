import { useCallback, useEffect, useRef, useState } from "react";
import { useParams } from "react-router-dom";
import { Bookmark, Copy, Download, Heart, Link as LinkIcon, Lock, MessageCircle, Trash2 } from "lucide-react";
import { apiFetch } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { useMediaActions } from "../hooks/useMediaActions.js";
import { MediaActionPanel, MediaControls } from "../components/media.jsx";
import { Avatar, ChipRow, EmptyState, Notice, NotFound, Page, ResilientImage, SkeletonGrid, StatsRow, UserLine } from "../components/ui.jsx";
import { imageQualityUrl, isGifMedia, thumbUrl, videoQualityUrl } from "../utils/media.js";

function subcategoryNames(item) {
  if (Array.isArray(item?.subcategory_names) && item.subcategory_names.length) return item.subcategory_names;
  if (Array.isArray(item?.subcategories) && item.subcategories.length) return item.subcategories.map((row) => row?.name).filter(Boolean);
  return item?.subcategory_name ? [item.subcategory_name] : [];
}

export function MediaDetailPage({ ctx }) {
  const { mediaId } = useParams();
  const [media, setMedia] = useState(null);
  const [comments, setComments] = useState([]);
  const [commentBody, setCommentBody] = useState("");
  const [report, setReport] = useState({ reason: "", details: "" });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [imageQuality, setImageQuality] = useState("medium");
  const [videoQuality, setVideoQuality] = useState("high");
  const actions = useMediaActions(ctx, (updated) => setMedia(updated));
  const abortRef = useRef(null);

  const loadDetail = useCallback(async ({ background = false } = {}) => {
    if (abortRef.current) abortRef.current.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    if (!background) {
      setLoading(true);
      setError("");
    }
    try {
      const data = await apiFetch(`/api/media/${mediaId}`, { signal: controller.signal });
      if (controller.signal.aborted) return;
      setMedia(data.media);
      setComments(data.comments || []);
    } catch (fetchError) {
      if (controller.signal.aborted) return;
      if (!background) {
        setError(fetchError.message);
        setMedia(null);
      }
    } finally {
      if (!controller.signal.aborted && !background) setLoading(false);
    }
  }, [mediaId]);

  useEffect(() => {
    loadDetail();
    return () => { if (abortRef.current) abortRef.current.abort(); };
  }, [loadDetail]);

  useEffect(() => {
    setVideoQuality("high");
    setImageQuality("medium");
  }, [mediaId]);

  useLiveRefresh(() => loadDetail({ background: true }), { enabled: Boolean(mediaId) && media?.media_kind !== "video", interval: 45_000 });

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
  const gif = isGifMedia(media);
  const videoSrc = media.media_kind === "video" ? videoQualityUrl(media, videoQuality) : "";
  const metadataChips = [media.category_name, ...subcategoryNames(media), ...(media.tags || [])].filter(Boolean);
  const detailImageSources = gif
    ? [media.url, media.preview_url, media.thumb_url].filter(Boolean)
    : (
        imageQuality === "high"
          ? [media.url, imageQualityUrl(media, "medium"), imageQualityUrl(media, "low")]
          : imageQuality === "low"
            ? [imageQualityUrl(media, "low"), imageQualityUrl(media, "medium"), media.url]
            : [imageQualityUrl(media, "medium"), imageQualityUrl(media, "low"), media.url]
      ).filter(Boolean);

  return (
    <Page title={media.title || `Media ${media.id}`} eyebrow={media.media_kind || "Media"} actions={(
      <>
        <button type="button" onClick={() => actions.toggleLike(media)}><Heart size={16} />{media.liked_by_me ? "Unlike" : "Like"}</button>
        <button type="button" onClick={() => actions.toggleBookmark(media)}><Bookmark size={16} />{media.bookmarked_by_me ? "Saved" : "Save"}</button>
        <button type="button" onClick={() => actions.copyAddress(media)}><Copy size={16} />Copy URL</button>
        <button type="button" onClick={() => actions.copyPageLink(media)}><LinkIcon size={16} />Copy Link</button>
        <button type="button" onClick={() => actions.download(media)}><Download size={16} />Download</button>
      </>
    )}>
      <section className="detail-layout">
        <article className="media-stage">
          {media.locked ? (
            <div className="locked-state"><Lock size={38} /><h2>Age verification required</h2></div>
          ) : media.media_kind === "video" ? (
            <>
              <div className="quality-bar">
                <span>Video quality</span>
                <select value={videoQuality} onChange={(event) => setVideoQuality(event.target.value)}>
                  <option value="high">Original / full</option>
                  <option value="medium">Medium</option>
                  <option value="low">Low / fast</option>
                </select>
              </div>
              <video key={videoSrc} controls playsInline preload="metadata" src={videoSrc} poster={thumbUrl(media, 640)} />
            </>
          ) : (
            <>
              {!gif ? (
                <div className="quality-bar">
                  <span>Image quality</span>
                  <select value={imageQuality} onChange={(event) => setImageQuality(event.target.value)}>
                    <option value="high">High / full</option>
                    <option value="medium">Medium</option>
                    <option value="low">Low</option>
                  </select>
                </div>
              ) : null}
              <ResilientImage className={gif ? "gif-full" : ""} sources={detailImageSources} diagnostics={{ mediaId: media.id, mediaKind: media.media_kind, context: `detail-image-${imageQuality}` }} alt={media.title || ""} fallback={<div className="locked-state"><Notice kind="error">Media preview failed to load.</Notice></div>} />
            </>
          )}
        </article>
        <aside className="detail-side">
          <UserLine user={media} />
          {media.description ? <p className="description">{media.description}</p> : null}
          <StatsRow item={media} />
          <ChipRow values={metadataChips} />
          <MediaActionPanel ctx={ctx} media={media} actions={actions} />
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
