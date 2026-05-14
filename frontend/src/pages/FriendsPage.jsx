import { useCallback, useEffect, useState } from "react";
import { Check, RefreshCw, X } from "lucide-react";
import { apiFetch } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { FriendColumn } from "../components/social.jsx";
import { EmptyState, Page, RequireLogin, SkeletonGrid, UserMini } from "../components/ui.jsx";

export function FriendsPage({ ctx }) {
  const [state, setState] = useState({ incoming: [], outgoing: [], friends: [] });
  const [loading, setLoading] = useState(true);

  const loadFriends = useCallback(async ({ background = false } = {}) => {
    if (!ctx.user) return;
    if (!background) setLoading(true);
    try {
      const [requests, friends] = await Promise.all([
        apiFetch("/api/friends/requests"),
        apiFetch("/api/me/friends"),
      ]);
      setState({ incoming: requests.incoming || [], outgoing: requests.outgoing || [], friends: friends.friends || [] });
    } catch (error) {
      if (!background) ctx.showToast(error.message, "error");
    } finally {
      if (!background) setLoading(false);
    }
  }, [ctx]);

  useEffect(() => {
    loadFriends();
  }, [loadFriends]);

  useLiveRefresh(() => loadFriends({ background: true }), { enabled: Boolean(ctx.user), interval: 20_000 });

  async function respond(id, action) {
    try {
      await apiFetch(`/api/friends/requests/${id}`, { method: "POST", body: JSON.stringify({ action }) });
      await loadFriends();
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  if (!ctx.user) return <RequireLogin />;

  return (
    <Page title="Friends" eyebrow="Social" actions={<button type="button" onClick={loadFriends}><RefreshCw size={16} />Refresh</button>}>
      {loading ? <SkeletonGrid count={3} /> : (
        <section className="three-columns">
          <FriendColumn title="Incoming" rows={state.incoming} action={(row) => (
            <span className="inline-controls">
              <button type="button" onClick={() => respond(row.id, "accept")}><Check size={16} />Accept</button>
              <button type="button" onClick={() => respond(row.id, "decline")}><X size={16} />Decline</button>
            </span>
          )} />
          <FriendColumn title="Outgoing" rows={state.outgoing} action={(row) => <button type="button" onClick={() => respond(row.id, "cancel")}><X size={16} />Cancel</button>} />
          <div className="side-box"><div className="section-head"><h2>Friends</h2><span>{state.friends.length}</span></div>{state.friends.map((friend) => <UserMini user={friend} key={friend.id} />)}{!state.friends.length ? <EmptyState title="No friends yet" /> : null}</div>
        </section>
      )}
    </Page>
  );
}
