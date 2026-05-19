import { useCallback, useEffect, useMemo, useState } from "react";
import { useLocation } from "react-router-dom";
import { MessageCircle, RefreshCw, Search, Send } from "lucide-react";
import { apiFetch, cachedApiFetch, toQuery } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { Avatar, EmptyState, Page, RequireLogin, SkeletonList } from "../components/ui.jsx";

export function MessagesPage({ ctx }) {
  const location = useLocation();
  const [threads, setThreads] = useState([]);
  const [messages, setMessages] = useState([]);
  const [selectedUser, setSelectedUser] = useState(null);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState([]);
  const [body, setBody] = useState("");
  const [loading, setLoading] = useState(true);

  const selectedId = selectedUser?.user_id || selectedUser?.id;

  const loadThreads = useCallback(async ({ background = false } = {}) => {
    if (!ctx.user) return;
    if (!background) setLoading(true);
    try {
      const data = await apiFetch("/api/messages/threads");
      setThreads(data.threads || []);
      if (!selectedUser && data.threads?.length) setSelectedUser(data.threads[0]);
    } catch (error) {
      if (!background) ctx.showToast(error.message, "error");
    } finally {
      if (!background) setLoading(false);
    }
  }, [ctx, selectedUser]);

  const loadMessages = useCallback(async ({ background = false } = {}) => {
    if (!selectedId) return;
    try {
      const data = await apiFetch(`/api/messages/${selectedId}`);
      setMessages(data.messages || []);
      if (background) loadThreads({ background: true });
    } catch (error) {
      if (!background) ctx.showToast(error.message, "error");
    }
  }, [ctx, loadThreads, selectedId]);

  useEffect(() => {
    loadThreads();
  }, [loadThreads]);

  useEffect(() => {
    if (location.state?.user) setSelectedUser(location.state.user);
  }, [location.state]);

  useEffect(() => {
    loadMessages();
  }, [loadMessages]);

  useEffect(() => {
    if (!query.trim()) {
      setResults([]);
      return undefined;
    }
    const timer = window.setTimeout(async () => {
      try {
        const data = await cachedApiFetch(`/api/users/search${toQuery({ q: query, limit: 8 })}`, { ttl: 10_000 });
        setResults((data.users || []).filter((user) => Number(user.id) !== Number(ctx.user?.id)));
      } catch (_error) {
        setResults([]);
      }
    }, 220);
    return () => window.clearTimeout(timer);
  }, [ctx.user?.id, query]);

  useLiveRefresh(() => loadMessages({ background: true }), { enabled: Boolean(selectedId), interval: 12_000 });

  async function sendMessage(event) {
    event.preventDefault();
    if (!selectedId || !body.trim()) return;
    try {
      const data = await apiFetch(`/api/messages/${selectedId}`, {
        method: "POST",
        body: JSON.stringify({ body: body.trim() }),
      });
      setMessages((current) => [...current, data.message]);
      setBody("");
      loadThreads({ background: true });
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  const activeName = useMemo(() => selectedUser?.display_name || selectedUser?.username || "Conversation", [selectedUser]);

  if (!ctx.user) return <RequireLogin />;

  return (
    <Page title="Messages" eyebrow="Social" actions={<button type="button" onClick={() => loadThreads()}><RefreshCw size={16} />Refresh</button>}>
      <section className="split-view">
        <aside className="list-panel">
          <div className="input-with-icon">
            <Search size={16} />
            <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Find a user" />
          </div>
          {results.map((user) => (
            <button type="button" className="collection-row" key={user.id} onClick={() => { setSelectedUser(user); setQuery(""); setResults([]); }}>
              <Avatar user={user} compact />
              <span><strong>{user.display_name || user.username}</strong><small>@{user.username}</small></span>
            </button>
          ))}
          {loading ? <SkeletonList /> : threads.map((thread) => (
            <button type="button" className={`collection-row ${Number(selectedId) === Number(thread.user_id) ? "active" : ""}`} key={thread.user_id} onClick={() => setSelectedUser(thread)}>
              <Avatar user={thread} compact />
              <span><strong>{thread.display_name || thread.username}</strong><small>{thread.unread_count ? `${thread.unread_count} new` : thread.last_message || "No messages"}</small></span>
            </button>
          ))}
          {!loading && !threads.length && !results.length ? <EmptyState title="No conversations yet" /> : null}
        </aside>
        <section className="content-panel">
          <div className="section-head"><h2>{activeName}</h2><MessageCircle size={18} /></div>
          <div className="comments-list">
            {messages.map((message) => (
              <article className="comment" key={message.id}>
                <Avatar user={message} compact />
                <div>
                  <strong>{Number(message.sender_id) === Number(ctx.user.id) ? "You" : (message.display_name || message.username)}</strong>
                  <p>{message.body}</p>
                </div>
              </article>
            ))}
            {!selectedId ? <EmptyState title="Choose someone to message" /> : null}
          </div>
          {selectedId ? (
            <form className="comment-form" onSubmit={sendMessage}>
              <input value={body} onChange={(event) => setBody(event.target.value)} placeholder="Write a message" maxLength={2000} />
              <button type="submit"><Send size={16} />Send</button>
            </form>
          ) : null}
        </section>
      </section>
    </Page>
  );
}
