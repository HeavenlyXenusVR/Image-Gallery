import { useEffect, useState } from "react";
import { Search } from "lucide-react";
import { cachedApiFetch, toQuery } from "../api.js";
import { UserCard } from "../components/social.jsx";
import { EmptyState, Page, SkeletonGrid } from "../components/ui.jsx";

export function UsersPage({ ctx }) {
  const [query, setQuery] = useState("");
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const timer = window.setTimeout(async () => {
      setLoading(true);
      try {
        const data = await cachedApiFetch(`/api/users/search${toQuery({ q: query, limit: 42 })}`, { ttl: 20_000 });
        setUsers(data.users || []);
      } catch (error) {
        ctx.showToast(error.message, "error");
      } finally {
        setLoading(false);
      }
    }, 220);
    return () => window.clearTimeout(timer);
  }, [ctx, query]);

  return (
    <Page title="Users" eyebrow="People">
      <div className="toolbar">
        <div className="input-with-icon wide"><Search size={16} /><input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search users" /></div>
      </div>
      {loading ? <SkeletonGrid count={6} /> : (
        <div className="user-grid">
          {users.map((user) => <UserCard ctx={ctx} user={user} key={user.id} />)}
        </div>
      )}
      {!loading && !users.length ? <EmptyState title="No users found" /> : null}
    </Page>
  );
}
