import { Link, NavLink } from "react-router-dom";
import { Folder, Grid3X3, Heart, Home, Image as ImageIcon, LogIn, LogOut, MessageCircle, Moon, Settings, Sparkles, Sun, SunMoon, Upload, UserPlus, Users } from "lucide-react";
import { Avatar } from "./ui.jsx";

const THEME_ICONS = { dark: Moon, light: Sun, "": SunMoon };
const THEME_LABELS = { dark: "Switch to light theme", light: "Switch to system theme", "": "Switch to dark theme" };

export function Shell({ ctx, children, className = "", style }) {
  const checks = Array.isArray(ctx.lookups.live?.checks) ? ctx.lookups.live.checks : [];
  const telegram = checks.find((item) => item.id === "telegram");
  const liveOk = ctx.lookups.live?.ok ?? ctx.lookups.live?.check_map?.db ?? ctx.lookups.live?.check_map?.api;
  const healthText = liveOk ? "Live" : "Checking";
  const username = ctx.user?.username || "guest";
  return (
    <div className={`app-shell ${className}`.trim()} style={style}>
      <header className="topbar">
        <Link className="brand" to="/">
          <span className="brand-mark"><ImageIcon size={18} /></span>
          <span className="brand-copy">
            <strong>Image Gallery</strong>
            <small>Curated Media Deck</small>
          </span>
        </Link>
        <nav className="primary-nav" aria-label="Main">
          <NavItem to="/" icon={Home} label="Discover" />
          <NavItem to="/collections" icon={Folder} label="Collections" />
          <NavItem to="/users" icon={Users} label="Users" />
          <NavItem to="/following" icon={Sparkles} label="Following" />
          <NavItem to="/liked" icon={Heart} label="Liked" />
          {ctx.user ? <NavItem to="/friends" icon={UserPlus} label="Friends" /> : null}
          {ctx.user ? <NavItem to="/messages" icon={MessageCircle} label="Messages" /> : null}
          {ctx.user ? <NavItem to="/studio" icon={Grid3X3} label="Studio" /> : null}
          {ctx.user ? <NavItem to="/upload" icon={Upload} label="Upload" accent /> : null}
        </nav>
        <div className="account-actions">
          <span className={`health-pill ${liveOk ? "is-live" : ""}`} title={telegram?.detail || ""}>{healthText}</span>
          <ThemeToggle quickTheme={ctx.quickTheme} onCycle={ctx.cycleTheme} />
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
        <span>Image Gallery // HeavenlyXenusVR</span>
        <a href="https://discord.com/users/1304564041863266347" target="_blank" rel="noreferrer">Discord</a>
      </footer>
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

function ThemeToggle({ quickTheme, onCycle }) {
  const Icon = THEME_ICONS[quickTheme] ?? SunMoon;
  const label = THEME_LABELS[quickTheme] ?? "Toggle theme";
  return (
    <button className="icon-button theme-toggle" type="button" onClick={onCycle} title={label} aria-label={label}>
      <Icon size={16} />
    </button>
  );
}
