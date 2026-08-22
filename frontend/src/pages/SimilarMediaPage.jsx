import { useCallback, useEffect, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { ArrowLeft } from "lucide-react";
import { apiFetch, toQuery } from "../api.js";
import { MediaGrid } from "../components/media.jsx";
import { Page } from "../components/ui.jsx";
import { replaceMedia } from "../utils/media.js";

const PAGE_SIZE = 24;

// The single-item "More like this" rail on MediaDetailPage always capped
// at 12 -- this is the same tag/category-overlap scoring
// (compute_similar_media in routes.lua, now shared between both instead
// of two independently-drifting copies), just paginated into a real
// scrollable feed instead of a fixed-size strip.
export function SimilarMediaPage({ ctx }) {
  const { mediaId } = useParams();
  const [items, setItems] = useState([]);
  const [hasNext, setHasNext] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState("");
  const pageRef = useRef(1);
  const sentinelRef = useRef(null);

  const handleItemUpdated = useCallback((item) => setItems((rows) => replaceMedia(rows, item)), []);

  const load = useCallback(async ({ page = 1, append = false } = {}) => {
    if (!append) setLoading(true);
    try {
      const data = await apiFetch(`/api/media/${mediaId}/similar${toQuery({ limit: PAGE_SIZE + 1, offset: (page - 1) * PAGE_SIZE })}`);
      const rows = data.media || [];
      const pageItems = rows.slice(0, PAGE_SIZE);
      setItems((prev) => (append ? [...prev, ...pageItems] : pageItems));
      setHasNext(rows.length > PAGE_SIZE);
    } catch (err) {
      if (!append) { setError(err.message); setItems([]); setHasNext(false); }
    } finally {
      if (!append) setLoading(false);
      else setLoadingMore(false);
    }
  }, [mediaId]);

  useEffect(() => {
    pageRef.current = 1;
    load({ page: 1, append: false });
  }, [load]);

  useEffect(() => {
    const sentinel = sentinelRef.current;
    if (!sentinel) return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting && hasNext && !loadingMore && !loading) {
          const nextPage = pageRef.current + 1;
          pageRef.current = nextPage;
          setLoadingMore(true);
          load({ page: nextPage, append: true });
        }
      },
      { rootMargin: "300px" },
    );
    observer.observe(sentinel);
    return () => observer.disconnect();
  }, [hasNext, loadingMore, loading, load]);

  return (
    <Page
      title="More like this"
      eyebrow="Similar"
      lede="Posts related by tags and category."
      actions={<Link to={`/media/${mediaId}`} className="icon-button" title="Back to post"><ArrowLeft size={16} />Back to post</Link>}
    >
      {error ? <p className="muted-copy">{error}</p> : null}
      <MediaGrid ctx={ctx} items={items} loading={loading} emptyTitle="Nothing similar found yet" onItemUpdated={handleItemUpdated} />
      {hasNext ? <div ref={sentinelRef} className="scroll-sentinel" aria-hidden="true" /> : null}
    </Page>
  );
}
