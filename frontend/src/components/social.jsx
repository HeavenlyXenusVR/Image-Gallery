import { Link } from "react-router-dom";
import { Heart, LogIn, UserPlus } from "lucide-react";
import { apiFetch, clearApiCache } from "../api.js";
import { friendLabel } from "../utils/format.js";
import { Avatar, EmptyState, UserMini } from "./ui.jsx";

export function ProfileActions({ ctx, user, onChanged }) {
  async function follow() {
    try {
      await apiFetch(`/api/users/${user.id}/follow`, {
        method: "POST",
        body: JSON.stringify({ following: !user.following_by_me }),
      });
      onChanged();
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function friend() {
    try {
      await apiFetch(`/api/users/${user.id}/friend-request`, { method: "POST" });
      onChanged();
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  if (!ctx.user) return <Link className="button-link" to="/login"><LogIn size={16} />Login</Link>;
  return (
    <div className="profile-actions">
      <button type="button" onClick={follow}><Heart size={16} />{user.following_by_me ? "Unfollow" : "Follow"}</button>
      <button type="button" onClick={friend} disabled={["friends", "pending_out", "self"].includes(user.friend_status)}><UserPlus size={16} />{friendLabel(user.friend_status)}</button>
    </div>
  );
}

export function UserCard({ ctx, user }) {
  return (
    <article className="user-card">
      <Avatar user={user} large />
      <div>
        <Link to={`/users/${user.username}`}><h3>{user.display_name || user.username}</h3></Link>
        <p>@{user.username}{user.profile_headline ? ` / ${user.profile_headline}` : ""}</p>
      </div>
      <ProfileActions ctx={ctx} user={user} onChanged={() => clearApiCache("/api/users/search")} />
    </article>
  );
}

export function FriendColumn({ title, rows, action }) {
  return (
    <div className="side-box">
      <div className="section-head"><h2>{title}</h2><span>{rows.length}</span></div>
      {rows.map((row) => (
        <article className="friend-request" key={row.id}>
          <UserMini user={row.user || row} />
          {action(row)}
        </article>
      ))}
      {!rows.length ? <EmptyState title="None" /> : null}
    </div>
  );
}
