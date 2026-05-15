import { Link, NavLink } from "react-router-dom";
import { Folder, Grid3X3, Heart, Home, Image as ImageIcon, LogIn, LogOut, Settings, Sparkles, Upload, UserPlus, Users } from "lucide-react";
import { Avatar } from "./ui.jsx";

export function Shell({ ctx, children }) {
  const checks = Array.isArray(ctx.lookups.live?.checks) ? ctx.lookups.live.checks : [];
  const telegram = checks.find((item) => item.id === "telegram");
  const liveOk = ctx.lookups.live?.ok ?? ctx.lookups.live?.check_map?.db ?? ctx.lookups.live?.check_map?.api;
  const healthText = telegram ? (telegram.ok ? "Telegram Live" : "Telegram Sync") : (liveOk ? "Live" : "Checking");
  return (
    <div className="app-shell">
      <header className="topbar">
        <Link className="brand" to="/">
          <span className="brand-mark"><ImageIcon size={18} /></span>
          <span>Image Gallery</span>
        </Link>
        <nav className="primary-nav" aria-label="Main">
          <NavItem to="/" icon={Home} label="Discover" />
          <NavItem to="/collections" icon={Folder} label="Collections" />
          <NavItem to="/users" icon={Users} label="Users" />
          <NavItem to="/following" icon={Sparkles} label="Following" />
          <NavItem to="/liked" icon={Heart} label="Liked" />
          {ctx.user ? <NavItem to="/friends" icon={UserPlus} label="Friends" /> : null}
          {ctx.user ? <NavItem to="/studio" icon={Grid3X3} label="Studio" /> : null}
          {ctx.user ? <NavItem to="/upload" icon={Upload} label="Upload" accent /> : null}
        </nav>
        <div className="account-actions">
          <span className={`health-pill ${liveOk ? "is-live" : ""}`} title={telegram?.detail || ""}>{healthText}</span>
          {ctx.user ? (
            <>
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
