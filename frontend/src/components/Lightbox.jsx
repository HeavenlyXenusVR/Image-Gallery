import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { Bookmark, ChevronLeft, ChevronRight, Copy, Download, ExternalLink, Heart, X } from "lucide-react";
import { apiFetch } from "../api.js";
import { useMediaActions } from "../hooks/useMediaActions.js";
import { Avatar, ChipRow, ResilientImage, StatsRow } from "./ui.jsx";
import { VideoPlayer } from "./VideoPlayer.jsx";
import { isGifMedia, mediaImageSources, thumbUrl, videoQualityUrl } from "../utils/media.js";

export function Lightbox({ ctx }) {
  const { lightbox, closeLightbox } = ctx;
  const items = lightbox?.items || [];

  const [currentIndex, setCurrentIndex] = useState(lightbox?.index ?? 0);
  const [item, setItem] = useState(() => items[lightbox?.index ?? 0] || null);
  const [videoQuality, setVideoQuality] = useState("original");
  const cacheRef = useRef(new Map());
  const currentIndexRef = useRef(currentIndex);
  currentIndexRef.current = currentIndex;

  // Reset when lightbox opens with a new payload
  useEffect(() => {
    if (!lightbox) return;
    const idx = lightbox.index ?? 0;
    setCurrentIndex(idx);
    setItem(lightbox.items[idx] || null);
    setVideoQuality("original");
  }, [lightbox]);

  const actions = useMediaActions(ctx, (updated) => {
    if (!updated) return;
    cacheRef.current.set(updated.id, updated);
    setItem((current) => (current?.id === updated.id ? updated : current));
  });

  // Load full API detail for richer data (like counts, description, tags)
  useEffect(() => {
    const target = items[currentIndex];
    if (!target) return;
    const { id } = target;
    if (cacheRef.current.has(id)) {
      setItem(cacheRef.current.get(id));
      return;
    }
    let cancelled = false;
    apiFetch(`/api/media/${id}`).then((data) => {
      if (cancelled) return;
      const m = data.media || target;
      cacheRef.current.set(id, m);
      setItem(m);
    }).catch(() => {
      if (!cancelled) {
        cacheRef.current.set(id, target);
      }
    });
    return () => { cancelled = true; };
  }, [currentIndex, items]);

  const goTo = useCallback((idx) => {
    if (!lightbox) return;
    if (idx < 0 || idx >= lightbox.items.length) return;
    setCurrentIndex(idx);
    setItem(lightbox.items[idx] || null);
    setVideoQuality("original");
  }, [lightbox]);

  // Keyboard navigation — use ref so effect is stable
  useEffect(() => {
    const onKey = (e) => {
      if (e.key === "Escape") { closeLightbox(); return; }
      if (e.key === "ArrowLeft") goTo(currentIndexRef.current - 1);
      if (e.key === "ArrowRight") goTo(currentIndexRef.current + 1);
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [closeLightbox, goTo]);

  // Body scroll lock
  useEffect(() => {
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => { document.body.style.overflow = prev; };
  }, []);

  if (!lightbox || !item) return null;

  const gif = isGifMedia(item);
  const isVideo = item.media_kind === "video";
  const imageSources = gif
    ? [item.url, item.preview_url, item.thumb_url].filter(Boolean)
    : mediaImageSources(item, { width: 1280, previewSize: "detail" });
  const videoSrc = isVideo ? videoQualityUrl(item, videoQuality) : "";
  const chips = [item.category_name, ...(item.tags || [])].filter(Boolean);
  const canPrev = currentIndex > 0;
  const canNext = currentIndex < items.length - 1;

  return (
    <div
      className="lb-backdrop"
      onClick={closeLightbox}
      role="dialog"
      aria-modal="true"
      aria-label="Media preview"
    >
      <div className="lb-panel" onClick={(e) => e.stopPropagation()}>
        <button className="lb-close icon-button" type="button" onClick={closeLightbox} aria-label="Close preview">
          <X size={18} />
        </button>

        {canPrev && (
          <button className="lb-nav lb-nav-prev" type="button" onClick={() => goTo(currentIndex - 1)} aria-label="Previous media">
            <ChevronLeft size={24} />
          </button>
        )}
        {canNext && (
          <button className="lb-nav lb-nav-next" type="button" onClick={() => goTo(currentIndex + 1)} aria-label="Next media">
            <ChevronRight size={24} />
          </button>
        )}

        <div className="lb-media">
          {isVideo ? (
            <VideoPlayer
              src={videoSrc}
              poster={thumbUrl(item, 1024)}
              quality={videoQuality}
              onQualityChange={setVideoQuality}
              qualityOptions={[["original", "Original"], ["1080p", "1080p HD"], ["720p", "720p"], ["480p", "480p"]]}
              title={item.title}
            />
          ) : (
            <ResilientImage
              className={gif ? "gif-full" : "lb-img"}
              sources={imageSources}
              alt={item.title || ""}
            />
          )}
        </div>

        <div className="lb-info">
          <div className="lb-info-top">
            <Link className="lb-user" to={`/users/${item.username || ""}`} onClick={closeLightbox}>
              <Avatar user={item} compact />
              <span>{item.display_name || item.username || "User"}</span>
            </Link>
            <Link className="button-link lb-fullpage" to={`/media/${item.id}`} onClick={closeLightbox}>
              <ExternalLink size={13} />Full page
            </Link>
          </div>
          <h2 className="lb-title">{item.title || "Untitled"}</h2>
          {item.description ? <p className="lb-desc">{item.description}</p> : null}
          <StatsRow item={item} />
          {chips.length ? <ChipRow values={chips} /> : null}
          <div className="lb-actions">
            <button type="button" className={item.liked_by_me ? "primary" : ""} onClick={() => actions.toggleLike(item)}>
              <Heart size={15} className={item.liked_by_me ? "filled" : ""} />
              {item.liked_by_me ? "Unlike" : "Like"}
            </button>
            <button type="button" className={item.bookmarked_by_me ? "primary" : ""} onClick={() => actions.toggleBookmark(item)}>
              <Bookmark size={15} className={item.bookmarked_by_me ? "filled" : ""} />
              {item.bookmarked_by_me ? "Saved" : "Save"}
            </button>
            <button type="button" onClick={() => actions.download(item)}>
              <Download size={15} />Download
            </button>
            <button type="button" onClick={() => actions.copyAddress(item)}>
              <Copy size={15} />Copy URL
            </button>
          </div>
          {items.length > 1 ? (
            <div className="lb-counter">
              <button type="button" className="lb-counter-prev" disabled={!canPrev} onClick={() => goTo(currentIndex - 1)}>‹</button>
              <span>{currentIndex + 1} / {items.length}</span>
              <button type="button" className="lb-counter-next" disabled={!canNext} onClick={() => goTo(currentIndex + 1)}>›</button>
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}
