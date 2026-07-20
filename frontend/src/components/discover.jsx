import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Eye, Flame, Heart, Lock } from "lucide-react";
import { cachedApiFetch } from "../api.js";
import { ResilientImage } from "./ui.jsx";
import { mediaImageSources } from "../utils/media.js";
import { numberish } from "../utils/format.js";

// Self-contained (own fetch) trending strip for the Discover front page: the
// single hottest post as a big spotlight banner, then the rest of the week's
// top posts as a horizontal ranked rail. Kept independent of DiscoverPage's
// own filtered /api/media query so switching filters there never disturbs
// this section.
export function DiscoverTrending() {
  const [items, setItems] = useState(null); // null = still loading

  useEffect(() => {
    let cancelled = false;
    cachedApiFetch("/api/media/trending?days=7&limit=11", { ttl: 30_000, staleTtl: 5 * 60_000 })
      .then((data) => { if (!cancelled) setItems(data.media || []); })
      .catch(() => { if (!cancelled) setItems([]); });
    return () => { cancelled = true; };
  }, []);

  if (items && items.length === 0) return null;

  const [spotlight, ...rail] = items || [];

  return (
    <section className="discover-trending">
      <div className="discover-trending-head">
        <h2><Flame size={18} />Trending this week</h2>
        <Link className="button-link" to="/trending">See all</Link>
      </div>
      <div className="discover-trending-body">
        {items ? (
          <>
            {spotlight ? <SpotlightCard item={spotlight} /> : null}
            <div className="trending-rail">
              {rail.map((item, index) => <TrendingRailCard key={item.id} item={item} rank={index + 2} />)}
            </div>
          </>
        ) : (
          <>
            <div className="discover-spotlight skeleton-card" aria-hidden="true" />
            <div className="trending-rail">
              {Array.from({ length: 6 }, (_, index) => (
                <div className="trending-rail-card skeleton-card" key={`trsk-${index}`} aria-hidden="true" />
              ))}
            </div>
          </>
        )}
      </div>
    </section>
  );
}

function SpotlightCard({ item }) {
  const sources = mediaImageSources(item, { width: 900, previewSize: "detail" });
  return (
    <Link className="discover-spotlight" to={`/media/${item.id}`}>
      {item.locked ? (
        <div className="video-thumb-placeholder"><Lock size={30} /></div>
      ) : (
        <ResilientImage sources={sources} alt={item.title || ""} loading="eager" decoding="async" fallback={<div className="video-thumb-placeholder" />} />
      )}
      <div className="discover-spotlight-copy">
        <span className="discover-spotlight-kicker"><Flame size={12} />#1 this week</span>
        <h3>{item.title || "Untitled"}</h3>
        <div className="discover-spotlight-stats">
          <span><Heart size={14} />{numberish(item.likes || item.like_count)}</span>
          <span><Eye size={14} />{numberish(item.views)}</span>
        </div>
      </div>
    </Link>
  );
}

function TrendingRailCard({ item, rank }) {
  const sources = mediaImageSources(item, { width: 360, previewSize: "card" });
  return (
    <Link className="trending-rail-card" to={`/media/${item.id}`}>
      <span className="trending-rank">#{rank}</span>
      {item.locked ? (
        <div className="video-thumb-placeholder"><Lock size={22} /></div>
      ) : (
        <ResilientImage sources={sources} alt={item.title || ""} loading="lazy" decoding="async" fallback={<div className="video-thumb-placeholder" />} />
      )}
      <div className="trending-rail-copy">
        <strong>{item.title || "Untitled"}</strong>
        <span><Heart size={12} />{numberish(item.likes || item.like_count)}</span>
      </div>
    </Link>
  );
}

// Quick one-tap category switcher shown above the main grid. Only ever sets
// category_id — picking a specific subcategory still requires the sidebar
// select, same division of labor as the iOS app's CategoryChipsRow.
export function CategoryPills({ categories, selectedId, onSelect }) {
  if (!categories?.length) return null;
  return (
    <div className="category-pills">
      <button type="button" className={`category-pill ${!selectedId ? "active" : ""}`} onClick={() => onSelect("")}>
        All
      </button>
      {categories.map((category) => (
        <button
          type="button"
          key={category.id}
          className={`category-pill ${String(selectedId) === String(category.id) ? "active" : ""}`}
          onClick={() => onSelect(category.id)}
        >
          {category.name}
        </button>
      ))}
    </div>
  );
}
