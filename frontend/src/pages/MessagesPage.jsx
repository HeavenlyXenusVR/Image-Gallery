import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useLocation } from "react-router-dom";
import { MessageCircle, Plus, RefreshCw, Search, Send, Users, X as XIcon } from "lucide-react";
import { apiFetch, cachedApiFetch, toQuery } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { Avatar, EmptyState, Page, RequireLogin, SkeletonList } from "../components/ui.jsx";

export function MessagesPage({ ctx }) {
  const location = useLocation();
  const [threads, setThreads] = useState([]);
  const [groups, setGroups] = useState([]);
  const [messages, setMessages] = useState([]);
  const [selectedUser, setSelectedUser] = useState(null);
  const [selectedGroup, setSelectedGroup] = useState(null);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState([]);
  const [body, setBody] = useState("");
  const [loading, setLoading] = useState(true);
  const [showNewGroup, setShowNewGroup] = useState(false);
  const [groupName, setGroupName] = useState("");
  const [groupQuery, setGroupQuery] = useState("");
  const [groupResults, setGroupResults] = useState([]);
  const [groupMembers, setGroupMembers] = useState([]);
  const [creatingGroup, setCreatingGroup] = useState(false);
  const messagesEndRef = useRef(null);

  const selectedId = selectedUser?.user_id || selectedUser?.id;
  const activeGroupId = selectedGroup?.id;
  const didAutoSelect = useRef(false);
  const showToast = ctx.showToast;
  const userId = ctx.user?.id;

  // Auto-scroll to bottom when messages change
  useEffect(() => {
    if (messagesEndRef.current) {
      messagesEndRef.current.scrollIntoView({ behavior: "smooth" });
    }
  }, [messages]);

  const loadThreads = useCallback(async ({ background = false } = {}) => {
    if (!userId) return;
    if (!background) setLoading(true);
    try {
      const [dmData, groupData] = await Promise.all([
        apiFetch("/api/messages/threads"),
        apiFetch("/api/threads").catch(() => ({ threads: [] })),
      ]);
      setThreads(dmData.threads || []);
      setGroups(groupData.threads || []);
      if (!didAutoSelect.current && (dmData.threads?.length || groupData.threads?.length)) {
        didAutoSelect.current = true;
        if (dmData.threads?.length) setSelectedUser(dmData.threads[0]);
        else setSelectedGroup(groupData.threads[0]);
      }
    } catch (error) {
      if (!background) showToast(error.message, "error");
    } finally {
      if (!background) setLoading(false);
    }
  }, [userId, showToast]);

  const loadMessages = useCallback(async ({ background = false } = {}) => {
    if (activeGroupId) {
      try {
        const data = await apiFetch(`/api/threads/${activeGroupId}/messages`);
        setMessages(data.messages || []);
        if (background) loadThreads({ background: true });
      } catch (error) {
        if (!background) showToast(error.message, "error");
      }
      return;
    }
    if (!selectedId) return;
    try {
      const data = await apiFetch(`/api/messages/${selectedId}`);
      setMessages(data.messages || []);
      if (background) loadThreads({ background: true });
    } catch (error) {
      if (!background) showToast(error.message, "error");
    }
  }, [selectedId, activeGroupId, loadThreads, showToast]);

  useEffect(() => {
    loadThreads();
  }, [loadThreads]);

  useEffect(() => {
    if (location.state?.user) {
      setSelectedGroup(null);
      setSelectedUser(location.state.user);
    }
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
        setResults((data.users || []).filter((user) => Number(user.id) !== Number(userId)));
      } catch (_error) {
        setResults([]);
      }
    }, 220);
    return () => window.clearTimeout(timer);
  }, [userId, query]);

  useEffect(() => {
    if (!groupQuery.trim()) {
      setGroupResults([]);
      return undefined;
    }
    const timer = window.setTimeout(async () => {
      try {
        const data = await cachedApiFetch(`/api/users/search${toQuery({ q: groupQuery, limit: 8 })}`, { ttl: 10_000 });
        const chosenIds = new Set(groupMembers.map((member) => Number(member.id)));
        setGroupResults((data.users || []).filter((user) => Number(user.id) !== Number(userId) && !chosenIds.has(Number(user.id))));
      } catch (_error) {
        setGroupResults([]);
      }
    }, 220);
    return () => window.clearTimeout(timer);
  }, [userId, groupQuery, groupMembers]);

  useLiveRefresh(() => loadMessages({ background: true }), { enabled: Boolean(selectedId || activeGroupId), interval: 12_000 });

  function selectDm(thread) {
    setSelectedGroup(null);
    setSelectedUser(thread);
  }

  function selectGroup(group) {
    setSelectedUser(null);
    setSelectedGroup(group);
  }

  async function sendMessage(event) {
    event.preventDefault();
    if (!body.trim()) return;
    try {
      if (activeGroupId) {
        const data = await apiFetch(`/api/threads/${activeGroupId}/messages`, {
          method: "POST",
          body: JSON.stringify({ body: body.trim() }),
        });
        setMessages((current) => [...current, data.message]);
      } else if (selectedId) {
        const data = await apiFetch(`/api/messages/${selectedId}`, {
          method: "POST",
          body: JSON.stringify({ body: body.trim() }),
        });
        setMessages((current) => [...current, data.message]);
      } else {
        return;
      }
      setBody("");
      loadThreads({ background: true });
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  function addGroupMember(user) {
    setGroupMembers((current) => (current.some((member) => Number(member.id) === Number(user.id)) ? current : [...current, user]));
    setGroupQuery("");
    setGroupResults([]);
  }

  function removeGroupMember(userIdToRemove) {
    setGroupMembers((current) => current.filter((member) => Number(member.id) !== Number(userIdToRemove)));
  }

  async function createGroup(event) {
    event.preventDefault();
    if (groupMembers.length < 1) {
      ctx.showToast("Add at least one other member to start a group.", "error");
      return;
    }
    setCreatingGroup(true);
    try {
      const data = await apiFetch("/api/threads", {
        method: "POST",
        body: JSON.stringify({ member_ids: groupMembers.map((member) => member.id), name: groupName.trim() || null }),
      });
      setGroups((current) => [data.thread, ...current]);
      selectGroup(data.thread);
      setShowNewGroup(false);
      setGroupName("");
      setGroupMembers([]);
      ctx.showToast("Group created.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setCreatingGroup(false);
    }
  }

  const activeName = useMemo(() => {
    if (activeGroupId) return selectedGroup?.display_name || selectedGroup?.name || "Group";
    return selectedUser?.display_name || selectedUser?.username || "Conversation";
  }, [activeGroupId, selectedGroup, selectedUser]);

  if (!ctx.user) return <RequireLogin />;

  return (
    <Page
      title="Messages"
      eyebrow="Social"
      actions={(
        <>
          <button type="button" onClick={() => setShowNewGroup((current) => !current)}>
            <Plus size={16} />New group
          </button>
          <button type="button" onClick={() => loadThreads()} disabled={loading}><RefreshCw size={16} />Refresh</button>
        </>
      )}
    >
      <section className="split-view">
        <aside className="list-panel">
          {showNewGroup ? (
            <form className="stacked-form create-box" onSubmit={createGroup}>
              <strong>New group</strong>
              <input value={groupName} onChange={(event) => setGroupName(event.target.value)} placeholder="Group name (optional)" maxLength={120} />
              <div className="input-with-icon">
                <Search size={16} />
                <input value={groupQuery} onChange={(event) => setGroupQuery(event.target.value)} placeholder="Add members" />
              </div>
              {groupResults.length ? (
                <div className="group-member-picker">
                  {groupResults.map((user) => (
                    <button type="button" key={user.id} className="collection-row" onClick={() => addGroupMember(user)}>
                      <Avatar user={user} compact />
                      <span><strong>{user.display_name || user.username}</strong><small>@{user.username}</small></span>
                    </button>
                  ))}
                </div>
              ) : null}
              {groupMembers.length ? (
                <div className="chip-row">
                  {groupMembers.map((member) => (
                    <span key={member.id}>
                      {member.display_name || member.username}
                      <button type="button" onClick={() => removeGroupMember(member.id)} aria-label={`Remove ${member.username}`}><XIcon size={12} /></button>
                    </span>
                  ))}
                </div>
              ) : null}
              <button type="submit" disabled={creatingGroup || !groupMembers.length}><Users size={16} />{creatingGroup ? "Creating…" : "Create group"}</button>
            </form>
          ) : null}
          <div className="input-with-icon">
            <Search size={16} />
            <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Find a user" />
          </div>
          {results.map((user) => (
            <button type="button" className="collection-row" key={`search-${user.id}`} onClick={() => { selectDm(user); setQuery(""); setResults([]); }}>
              <Avatar user={user} compact />
              <span><strong>{user.display_name || user.username}</strong><small>@{user.username}</small></span>
            </button>
          ))}
          {loading ? <SkeletonList /> : (
            <>
              {groups.map((group) => (
                <button type="button" className={`collection-row ${!selectedUser && Number(activeGroupId) === Number(group.id) ? "active" : ""}`} key={`group-${group.id}`} onClick={() => selectGroup(group)}>
                  <span className="avatar compact group-avatar"><Users size={16} /></span>
                  <span><strong>{group.display_name || group.name || "Group"}</strong><small>{group.last_message || `${group.members?.length || 0} members`}</small></span>
                </button>
              ))}
              {threads.map((thread) => (
                <button type="button" className={`collection-row ${!selectedGroup && Number(selectedId) === Number(thread.user_id) ? "active" : ""}`} key={`dm-${thread.user_id}`} onClick={() => selectDm(thread)}>
                  <Avatar user={thread} compact />
                  <span><strong>{thread.display_name || thread.username}</strong><small>{thread.unread_count ? `${thread.unread_count} new` : thread.last_message || "No messages"}</small></span>
                </button>
              ))}
            </>
          )}
          {!loading && !threads.length && !groups.length && !results.length ? <EmptyState title="No conversations yet" /> : null}
        </aside>
        <section className="content-panel">
          <div className="section-head"><h2>{activeName}</h2>{activeGroupId ? <Users size={18} /> : <MessageCircle size={18} />}</div>
          <div className="comments-list messages-list">
            {messages.map((message) => (
              <article className="comment" key={message.id}>
                <Avatar user={activeGroupId ? { ...message, avatar_path: message.user_avatar_path } : message} compact />
                <div>
                  <strong>{Number(message.sender_id) === Number(ctx.user.id) ? "You" : (message.display_name || message.username)}</strong>
                  <p>{message.body}</p>
                </div>
              </article>
            ))}
            {!selectedId && !activeGroupId ? <EmptyState title="Choose someone to message" /> : null}
            <div ref={messagesEndRef} />
          </div>
          {selectedId || activeGroupId ? (
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
