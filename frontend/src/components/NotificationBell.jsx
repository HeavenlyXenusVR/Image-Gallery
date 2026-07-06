import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Bell, Heart, MessageCircle, MessageSquare, UserPlus, Users } from "lucide-react";
import { apiFetch } from "../api.js";
import { Avatar } from "./ui.jsx";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { timeAgo } from "../utils/format.js";

const KIND_ICON = {
  follow: UserPlus,
  friend_request: Users,
  friend_accept: Heart,
  comment: MessageSquare,
  message: MessageCircle,
};

function notificationText(item) {
  const name = item.actor_display_name || item.actor_username || "Someone";
  switch (item.kind) {
    case "follow":
      return `${name} followed you.`;
    case "friend_request":
      return `${name} sent you a friend request.`;
    case "friend_accept":
      return `${name} accepted your friend request.`;
    case "comment":
      return `${name} commented${item.media_title ? ` on "${item.media_title}"` : " on your post"}.`;
    case "message":
      return `${name} sent you a message.`;
    default:
      return `${name} did something.`;
  }
}

function notificationLink(item) {
  switch (item.kind) {
    case "follow":
    case "friend_accept":
      return item.actor_username ? `/users/${item.actor_username}` : null;
    case "friend_request":
      return "/friends";
    case "comment":
      return item.media_id ? `/media/${item.media_id}` : null;
    case "message":
      return "/messages";
    default:
      return null;
  }
}

export function NotificationBell({ ctx }) {
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(false);
  const [unreadCount, setUnreadCount] = useState(0);
  const rootRef = useRef(null);

  const refreshUnreadCount = useCallback(async () => {
    if (!ctx.user) return;
    try {
      const data = await apiFetch("/api/notifications/unread-count");
      setUnreadCount(Number(data?.unread_count || 0));
    } catch (_error) {
      // Notification polling is non-critical; stay quiet on failure.
    }
  }, [ctx.user]);

  useEffect(() => {
    if (!ctx.user) {
      setUnreadCount(0);
      setItems([]);
      setOpen(false);
    }
  }, [ctx.user]);

  useLiveRefresh(refreshUnreadCount, { enabled: Boolean(ctx.user), interval: 30_000, immediate: true });

  useEffect(() => {
    if (!open) return undefined;
    const onPointerDown = (event) => {
      if (rootRef.current && !rootRef.current.contains(event.target)) setOpen(false);
    };
    const onKeyDown = (event) => {
      if (event.key === "Escape") setOpen(false);
    };
    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [open]);

  const loadNotifications = useCallback(async () => {
    setLoading(true);
    try {
      const data = await apiFetch("/api/notifications?limit=30");
      setItems(Array.isArray(data?.notifications) ? data.notifications : []);
      setUnreadCount(Number(data?.unread_count || 0));
    } catch (_error) {
      ctx.showToast?.("Could not load notifications.", "error");
    } finally {
      setLoading(false);
    }
  }, [ctx]);

  const toggleOpen = useCallback(() => {
    setOpen((current) => {
      const next = !current;
      if (next) void loadNotifications();
      return next;
    });
  }, [loadNotifications]);

  const handleSelect = useCallback(async (item) => {
    setOpen(false);
    if (!item.read_at) {
      setItems((current) => current.map((row) => (row.id === item.id ? { ...row, read_at: new Date().toISOString() } : row)));
      setUnreadCount((current) => Math.max(0, current - 1));
      apiFetch(`/api/notifications/${item.id}/read`, { method: "POST" }).catch(() => {});
    }
    const link = notificationLink(item);
    if (link) navigate(link);
  }, [navigate]);

  const markAllRead = useCallback(async (event) => {
    event.stopPropagation();
    setItems((current) => current.map((row) => (row.read_at ? row : { ...row, read_at: new Date().toISOString() })));
    setUnreadCount(0);
    try {
      await apiFetch("/api/notifications/read-all", { method: "POST" });
    } catch (_error) {
      ctx.showToast?.("Could not mark notifications read.", "error");
    }
  }, [ctx]);

  if (!ctx.user) return null;

  return (
    <div className="notification-bell" ref={rootRef}>
      <button
        className="icon-button notification-bell-trigger"
        type="button"
        onClick={toggleOpen}
        aria-haspopup="true"
        aria-expanded={open}
        title="Notifications"
      >
        <Bell size={18} />
        {unreadCount > 0 ? <span className="notification-badge">{unreadCount > 9 ? "9+" : unreadCount}</span> : null}
        <span className="sr-only">Notifications</span>
      </button>
      {open ? (
        <div className="notification-panel" role="menu">
          <div className="notification-panel-header">
            <strong>Notifications</strong>
            {unreadCount > 0 ? (
              <button type="button" className="notification-mark-all" onClick={markAllRead}>Mark all read</button>
            ) : null}
          </div>
          <div className="notification-panel-list">
            {loading ? (
              <p className="notification-empty">Loading...</p>
            ) : items.length === 0 ? (
              <p className="notification-empty">You're all caught up.</p>
            ) : (
              items.map((item) => {
                const Icon = KIND_ICON[item.kind] || Bell;
                return (
                  <button
                    key={item.id}
                    type="button"
                    className={`notification-row ${item.read_at ? "" : "is-unread"}`}
                    onClick={() => handleSelect(item)}
                  >
                    {item.actor_id ? (
                      <Avatar user={{ id: item.actor_id, avatar_url: item.actor_avatar_url, display_name: item.actor_display_name, username: item.actor_username }} compact />
                    ) : (
                      <span className="notification-row-icon"><Icon size={16} /></span>
                    )}
                    <span className="notification-row-copy">
                      <span>{notificationText(item)}</span>
                      {item.preview ? <small className="notification-row-preview">"{item.preview}"</small> : null}
                      <small className="notification-row-time">{timeAgo(item.created_at)}</small>
                    </span>
                  </button>
                );
              })
            )}
          </div>
        </div>
      ) : null}
    </div>
  );
}
