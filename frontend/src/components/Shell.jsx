import { useEffect, useState } from "react";
import { Link, NavLink } from "react-router-dom";
import { AlertTriangle, Folder, Grid3X3, Heart, Home, Image as ImageIcon, LogIn, LogOut, MessageCircle, Moon, Rocket, Settings, ShieldAlert, Sparkles, Sun, SunMoon, TrendingUp, Upload, UserPlus, Users, X as XIcon } from "lucide-react";
import { apiFetch, cachedApiFetch } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { getPendingUploadJobs, removePendingUploadJob } from "../uploadJobs.js";
import { Avatar, GlassFilterDefs, glassPointerMove } from "./ui.jsx";
import { NotificationBell } from "./NotificationBell.jsx";

const THEME_ICONS = { dark: Moon, light: Sun, "": SunMoon };
const THEME_LABELS = { dark: "Switch to light theme", light: "Switch to system theme", "": "Switch to dark theme" };

export function Shell({ ctx, children, className = "", style }) {
  const checks = Array.isArray(ctx.lookups.live?.checks) ? ctx.lookups.live.checks : [];
  const telegram = checks.find((item) => item.id === "telegram");
  const liveOk = ctx.lookups.live?.ok ?? ctx.lookups.live?.check_map?.db ?? ctx.lookups.live?.check_map?.api;
  const healthText = liveOk ? "Live" : "Checking";
  const username = ctx.user?.username || "guest";
  const [site, setSite] = useState(null);
  const [bannerDismissed, setBannerDismissed] = useState(false);

  useLiveRefresh(async () => {
    try {
      setSite(await cachedApiFetch("/api/site/announcement", { ttl: 30_000 }));
    } catch (_error) {
      // Non-critical — keep the last known state rather than erroring the shell.
    }
  }, { interval: 60_000, immediate: true });

  // Backgrounded uploads (UploadPage's chunked path hands off to
  // upload_chunk_finish's background job once its fast dry-run passes, then
  // navigates away immediately) get polled here instead of on the upload
  // page itself, since the whole point is the uploader no longer has to
  // stay there. Lives in Shell rather than UploadPage so a job queued
  // before navigating away still gets its completion toast wherever the
  // user ends up. Short interval, but the callback itself no-ops in one
  // localStorage read when nothing's pending, so this is cheap at idle.
  useLiveRefresh(async () => {
    const jobs = getPendingUploadJobs();
    if (!jobs.length) return;
    for (const job of jobs) {
      try {
        const data = await apiFetch(`/api/media/upload/job/${encodeURIComponent(job.jobId)}`);
        if (data.status === "processing") continue;
        removePendingUploadJob(job.jobId);
        if (data.status === "done") {
          ctx.showToast(`"${job.filename}" finished uploading.`, "success");
          ctx.refreshLookups();
        } else {
          ctx.showToast(`Upload of "${job.filename}" failed: ${data.detail || "unknown error"}`, "error");
        }
      } catch (_error) {
        // Job lookup itself failed (expired past the 24h job TTL, or a
        // network blip) -- drop it rather than retrying forever. The
        // actual upload already ran (or is running) server-side regardless
        // of whether anyone's still watching for the result; losing just
        // the toast isn't losing the upload.
        removePendingUploadJob(job.jobId);
      }
    }
  }, { interval: 6_000, immediate: true, enabled: Boolean(ctx.user) });

  useEffect(() => {
    setBannerDismissed(false);
  }, [site?.announcement_message]);

  const isOwner = Boolean(ctx.user?.site_owner);
  if (site?.maintenance_mode && !isOwner) {
    return (
      <div className={`app-shell ${className}`.trim()} style={style}>
        <main className="main-stage maintenance-gate">
          <div className="locked-state">
            <AlertTriangle size={42} />
            <h2>Under maintenance</h2>
            <p>{site.maintenance_message || "Nyxframe is temporarily unavailable. Please check back soon."}</p>
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className={`app-shell ${className}`.trim()} style={style}>
      <GlassFilterDefs />
      {site?.announcement_active && site.announcement_message && !bannerDismissed ? (
        <div className={`site-announcement-banner level-${site.announcement_level || "info"}`}>
          <span>{site.announcement_message}</span>
          <button type="button" className="icon-button" onClick={() => setBannerDismissed(true)} title="Dismiss">
            <XIcon size={16} />
          </button>
        </div>
      ) : null}
      <header className="topbar liquid-glass" onPointerMove={glassPointerMove}>
        <Link className="brand" to="/">
          <span className="brand-mark"><ImageIcon size={18} /></span>
          <span className="brand-copy">
            <strong>Nyxframe</strong>
            <small>Curated Media Deck</small>
          </span>
        </Link>
        <nav className="primary-nav" aria-label="Main">
          <NavItem to="/" icon={Home} label="Discover" />
          <NavItem to="/trending" icon={TrendingUp} label="Trending" />
          <NavItem to="/collections" icon={Folder} label="Collections" />
          <NavItem to="/users" icon={Users} label="Users" />
          <NavItem to="/following" icon={Sparkles} label="Following" />
          <NavItem to="/liked" icon={Heart} label="Liked" />
          {ctx.user ? <NavItem to="/friends" icon={UserPlus} label="Friends" /> : null}
          {ctx.user ? <NavItem to="/messages" icon={MessageCircle} label="Messages" /> : null}
          {ctx.user ? <NavItem to="/studio" icon={Grid3X3} label="Studio" /> : null}
          {ctx.user ? <NavItem to="/upload" icon={Upload} label="Upload" accent /> : null}
          {ctx.user?.site_owner ? <NavItem to="/admin" icon={ShieldAlert} label="Admin" /> : null}
          <NavItem to="/other-projects" icon={Rocket} label="My Other Projects" />
        </nav>
        <div className="account-actions">
          <span className={`health-pill ${liveOk ? "is-live" : ""}`} title={telegram?.detail || ""}>{healthText}</span>
          <ThemeToggle quickTheme={ctx.quickTheme} onCycle={ctx.cycleTheme} />
          <NotificationBell ctx={ctx} />
          {ctx.user ? (
            <>
              <Link className="account-badge" to={`/users/${ctx.user.username}`} title="Profile">
                <span className="account-badge-kicker">@{username}</span>
                <strong>{ctx.user.display_name || ctx.user.username}</strong>
              </Link>
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
      <footer className="site-footer">
        <span>Nyxframe // HeavenlyXenusVR</span>
        <a href="https://discord.com/users/1304564041863266347" target="_blank" rel="noreferrer">Discord</a>
      </footer>
    </div>
  );
}

function NavItem({ to, icon: Icon, label, accent = false }) {
  return (
    <NavLink
      className={({ isActive }) => `nav-item ${isActive ? "active" : ""} ${accent ? "accent liquid-glass" : ""}`}
      to={to}
      end={to === "/"}
      onPointerMove={accent ? glassPointerMove : undefined}
    >
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

function ThemeToggle({ quickTheme, onCycle }) {
  const Icon = THEME_ICONS[quickTheme] ?? SunMoon;
  const label = THEME_LABELS[quickTheme] ?? "Toggle theme";
  return (
    <button className="icon-button theme-toggle" type="button" onClick={onCycle} title={label} aria-label={label}>
      <Icon size={16} />
    </button>
  );
}
