import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Download, Eye, Folder, Heart, Lock, LogIn, MessageCircle, Sparkles } from "lucide-react";
import { formatDate, initials, numberish } from "../utils/format.js";
import { reportMediaLoadDiagnostic } from "../utils/media.js";

export function Page({ title, eyebrow, lede = "", actions, className = "", children }) {
  return (
    <div className={`page ${className}`.trim()}>
      <header className="page-head">
        <div>
          <p>{eyebrow}</p>
          <h1>{title}</h1>
          {lede ? <span className="page-lede">{lede}</span> : null}
        </div>
        {actions ? <div className="page-actions">{actions}</div> : null}
      </header>
      {children}
    </div>
  );
}

export function Pager({ page, hasNext, loading, onPage }) {
  return (
    <nav className="pager" aria-label="Pages">
      <button type="button" disabled={loading || page <= 1} onClick={() => onPage(Math.max(1, page - 1))}>Previous</button>
      <span>Page {page}</span>
      <button type="button" disabled={loading || !hasNext} onClick={() => onPage(page + 1)}>Next</button>
    </nav>
  );
}

export function TagCloud({ tags, onPick }) {
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

export function Segmented({ value, onChange, options }) {
  return (
    <div className="segmented">
      {options.map(([key, label]) => <button type="button" className={value === key ? "active" : ""} onClick={() => onChange(key)} key={key}>{label}</button>)}
    </div>
  );
}

export function Avatar({ user, compact = false, large = false }) {
  const src = user?.avatar_url || user?.user_avatar_url;
  const label = initials(user?.display_name || user?.username || "IG");
  const knownPresence = typeof user?.is_online === "boolean";
  const [failed, setFailed] = useState(false);
  return (
    <span className={`avatar ${compact ? "compact" : ""} ${large ? "large" : ""}`}>
      {src && !failed ? <img src={src} alt="" loading="lazy" decoding="async" onError={() => setFailed(true)} /> : label}
      {knownPresence ? <span className={`presence-dot ${user.is_online ? "online" : "inactive"}`} /> : null}
    </span>
  );
}

export function PresencePill({ user }) {
  const online = Boolean(user?.is_online);
  return <span className={`presence-pill ${online ? "online" : "inactive"}`}><span />{online ? "Online and active" : "Inactive"}</span>;
}

export function UserLine({ user }) {
  return (
    <Link className="owner-line" to={`/users/${user.username || ""}`}>
      <Avatar user={user} />
      <span><strong>{user.display_name || user.username || "User"}</strong><small>@{user.username || "user"}</small></span>
    </Link>
  );
}

export function StatsRow({ item, compact = false }) {
  return (
    <div className={`stats-row ${compact ? "compact" : ""}`}>
      <span><Heart size={14} />{numberish(item.likes || item.like_count)}</span>
      <span><Eye size={14} />{numberish(item.views)}</span>
      <span><Download size={14} />{numberish(item.downloads || item.download_count)}</span>
      <span><MessageCircle size={14} />{numberish(item.comment_count)}</span>
    </div>
  );
}

export function ChipRow({ values }) {
  const chips = (values || []).filter(Boolean).slice(0, 18);
  if (!chips.length) return null;
  return <div className="chip-row">{chips.map((value) => <span key={`${value}`}>{value}</span>)}</div>;
}

export function CollectionCover({ collection }) {
  const [failed, setFailed] = useState(false);
  return <span className="collection-cover">{collection.cover_url && !failed ? <img src={collection.cover_url} alt="" loading="lazy" decoding="async" onError={() => setFailed(true)} /> : <Folder size={20} />}</span>;
}

export function ResilientImage({ sources = [], fallback = null, diagnostics = null, ...props }) {
  const usableSources = (sources || []).filter(Boolean);
  const [index, setIndex] = useState(0);
  const externalOnError = props.onError;
  const externalOnLoad = props.onLoad;
  // Reset to first source whenever the source list changes
  const sourcesKey = usableSources.join("|");
  useEffect(() => {
    setIndex(0);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sourcesKey]);
  if (index >= usableSources.length) return fallback;
  const src = usableSources[index] || "";
  if (!src) return fallback;
  return (
    <img
      {...props}
      src={src}
      onLoad={(event) => {
        if (typeof externalOnLoad === "function") externalOnLoad(event);
        if (diagnostics && index > 0) {
          reportMediaLoadDiagnostic({
            mediaId: diagnostics.mediaId,
            mediaKind: diagnostics.mediaKind,
            context: diagnostics.context,
            outcome: "fallback-success",
            sourceIndex: index,
            sources: usableSources,
          });
        }
      }}
      onError={(event) => {
        if (typeof externalOnError === "function") externalOnError(event);
        if (diagnostics && index + 1 >= usableSources.length) {
          reportMediaLoadDiagnostic({
            mediaId: diagnostics.mediaId,
            mediaKind: diagnostics.mediaKind,
            context: diagnostics.context,
            outcome: "all-failed",
            sourceIndex: index,
            sources: usableSources,
          });
        }
        setIndex((current) => current + 1);
      }}
    />
  );
}

export function CollectionMini({ collection }) {
  return (
    <Link className="mini-row" to="/collections">
      <CollectionCover collection={collection} />
      <span><strong>{collection.name}</strong><small>{collection.item_count || 0} posts</small></span>
    </Link>
  );
}

export function UserMini({ user }) {
  return (
    <Link className="mini-row" to={`/users/${user.username || ""}`}>
      <Avatar user={user} compact />
      <span><strong>{user.display_name || user.username || "User"}</strong><small>@{user.username || "user"}</small></span>
    </Link>
  );
}

export function Metric({ label, value }) {
  return <article className="metric"><strong>{numberish(value)}</strong><span>{label}</span></article>;
}

export function Notice({ kind = "info", children }) {
  return <div className={`notice ${kind}`} role="alert">{children}</div>;
}

export function EmptyState({ title }) {
  return <div className="empty-state"><Sparkles size={24} /><h2>{title}</h2></div>;
}

export function RequireLogin() {
  return (
    <Page title="Login required" eyebrow="Account">
      <div className="empty-state"><Lock size={26} /><h2>Login required</h2><Link className="button-link primary" to="/login"><LogIn size={16} />Login</Link></div>
    </Page>
  );
}

export function NotFound() {
  return <Page title="Not Found" eyebrow="404"><EmptyState title="That page is not available" /></Page>;
}

export function SkeletonGrid({ count = 8 }) {
  const tips = [
    "Large galleries load faster after the first warm cache pass.",
    "Friend and profile changes refresh while you browse.",
    "Uploads can use AI metadata before publishing.",
  ];
  return (
    <div>
      <div className="loading-tip">{tips[count % tips.length]}</div>
      <div className="media-grid skeleton-grid">{Array.from({ length: count }, (_, index) => <div className="skeleton-card" key={`sk-${index}`} aria-hidden="true" />)}</div>
    </div>
  );
}

export function SkeletonList() {
  return <div className="skeleton-list">{Array.from({ length: 6 }, (_, index) => <div className="skeleton-row" key={`skr-${index}`} aria-hidden="true" />)}</div>;
}
