import { useCallback, useEffect, useState } from "react";
import { Search } from "lucide-react";
import { cachedApiFetch, toQuery } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { UserCard } from "../components/social.jsx";
import { EmptyState, Page, SkeletonGrid } from "../components/ui.jsx";

// Same class of bug as DiscoverPage's filters (see its FILTERS_SESSION_KEY
// doc comment): plain local state, no URL involved at all here, so
// switching to another tab and back unmounts/remounts this page and the
// search box silently goes blank -- nothing the visitor typed was ever
// actually lost, it just never survived the remount.
const QUERY_SESSION_KEY = "nyxframe_users_query";

export function UsersPage({ ctx }) {
  const [query, setQuery] = useState(() => {
    try {
      return sessionStorage.getItem(QUERY_SESSION_KEY) || "";
    } catch (_error) {
      return "";
    }
  });
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(false);

  const showToast = ctx.showToast;

  const loadUsers = useCallback(async ({ background = false } = {}) => {
    if (!background) setLoading(true);
    try {
      const data = await cachedApiFetch(`/api/users/search${toQuery({ q: query, limit: 42 })}`, {
        ttl: background ? 8_000 : 20_000,
        staleTtl: 30_000,
        allowStale: !background,
      });
      setUsers(data.users || []);
    } catch (error) {
      if (!background) showToast(error.message, "error");
    } finally {
      if (!background) setLoading(false);
    }
  }, [showToast, query]);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      loadUsers();
      try {
        if (query) sessionStorage.setItem(QUERY_SESSION_KEY, query);
        else sessionStorage.removeItem(QUERY_SESSION_KEY);
      } catch (_error) {
        // Private-browsing/storage-disabled -- search just won't survive a
        // tab switch in that case.
      }
    }, 220);
    return () => window.clearTimeout(timer);
  }, [loadUsers, query]);

  useLiveRefresh(() => loadUsers({ background: true }), { interval: 25_000 });

  return (
    <Page
      title="Users"
      eyebrow="People"
      lede="Browse creators, profile identities, and social connections across the gallery."
      className="page-users"
    >
      <div className="toolbar">
        <div className="input-with-icon wide"><Search size={16} /><input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search users" /></div>
      </div>
      {loading ? <SkeletonGrid count={6} /> : (
        <div className="user-grid">
          {users.map((user) => <UserCard ctx={ctx} user={user} onChanged={() => loadUsers({ background: true })} key={user.id} />)}
        </div>
      )}
      {!loading && !users.length ? <EmptyState title="No users found" /> : null}
    </Page>
  );
}
