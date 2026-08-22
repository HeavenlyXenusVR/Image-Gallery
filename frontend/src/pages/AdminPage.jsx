import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Ban, CheckCircle2, Flag, HardDrive, History, Megaphone, Music, RefreshCw, ShieldAlert, Trash2, Upload, Users, XCircle } from "lucide-react";
import { apiFetch, clearApiCache } from "../api.js";
import { EmptyState, Notice, Page, Segmented, SkeletonList } from "../components/ui.jsx";
import { formatDate, formatBytes } from "../utils/format.js";

const STATUS_FILTERS = [["open", "Open"], ["reviewed", "Reviewed"], ["dismissed", "Dismissed"], ["", "All"]];
const TABS = [
  ["reports", "Reports"],
  ["flagged", "Flagged Uploads"],
  ["users", "Users & Bans"],
  ["storage", "Storage"],
  ["site", "Site Settings"],
  ["music", "Background Music"],
  ["audit", "Audit Log"],
];

export function AdminPage({ ctx }) {
  const [tab, setTab] = useState("reports");

  if (!ctx.user) {
    return (
      <Page title="Admin" eyebrow="Moderation">
        <EmptyState title="Login required" />
      </Page>
    );
  }
  if (!ctx.user.site_owner) {
    return (
      <Page title="Admin" eyebrow="Moderation">
        <EmptyState title="You do not have access to this page" />
      </Page>
    );
  }

  return (
    <Page
      title="Admin"
      eyebrow="Moderation"
      lede="Review reports and flagged uploads, manage accounts, watch storage, and control site-wide messaging."
      actions={<Segmented value={tab} onChange={setTab} options={TABS} />}
    >
      {tab === "reports" ? <ReportsTab ctx={ctx} /> : null}
      {tab === "flagged" ? <FlaggedTab ctx={ctx} /> : null}
      {tab === "users" ? <UsersTab ctx={ctx} /> : null}
      {tab === "storage" ? <StorageTab ctx={ctx} /> : null}
      {tab === "site" ? <SiteSettingsTab ctx={ctx} /> : null}
      {tab === "music" ? <MusicTab ctx={ctx} /> : null}
      {tab === "audit" ? <AuditLogTab /> : null}
    </Page>
  );
}

function ReportsTab({ ctx }) {
  const [status, setStatus] = useState("open");
  const [reports, setReports] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [busyId, setBusyId] = useState("");

  const showToast = ctx.showToast;

  const loadReports = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const query = status ? `?status=${encodeURIComponent(status)}` : "";
      const data = await apiFetch(`/api/admin/reports${query}`);
      setReports(data.reports || []);
    } catch (fetchError) {
      setError(fetchError.message);
    } finally {
      setLoading(false);
    }
  }, [status]);

  useEffect(() => {
    loadReports();
  }, [loadReports]);

  async function resolveReport(report, nextStatus, { deleteMedia = false } = {}) {
    if (deleteMedia && !window.confirm("Delete the reported media? This cannot be undone from here.")) return;
    setBusyId(String(report.id));
    try {
      await apiFetch(`/api/admin/reports/${report.id}/resolve`, {
        method: "POST",
        body: JSON.stringify({ status: nextStatus, delete_media: deleteMedia }),
      });
      clearApiCache();
      showToast(deleteMedia ? "Media deleted and report resolved." : `Report marked ${nextStatus}.`, "success");
      setReports((rows) => rows.filter((row) => Number(row.id) !== Number(report.id)));
    } catch (resolveError) {
      showToast(resolveError.message, "error");
    } finally {
      setBusyId("");
    }
  }

  return (
    <div className="admin-tab">
      <div className="admin-tab-head">
        <Segmented value={status} onChange={setStatus} options={STATUS_FILTERS} />
        <button type="button" onClick={loadReports} disabled={loading}><RefreshCw size={16} />Refresh</button>
      </div>
      {error ? <Notice kind="error">{error}</Notice> : null}
      {loading ? <SkeletonList /> : (
        <div className="admin-reports-list">
          {reports.map((report) => (
            <article className="admin-report-row" key={report.id}>
              <Link to={`/media/${report.media_id}`} className="admin-report-thumb">
                {report.media_thumb_url ? <img src={report.media_thumb_url} alt="" loading="lazy" decoding="async" /> : <ShieldAlert size={28} />}
              </Link>
              <div className="admin-report-body">
                <strong>{report.media_title || `Media #${report.media_id}`}</strong>
                <p className="admin-report-reason">{report.reason}{report.details ? ` — ${report.details}` : ""}</p>
                <p className="muted-copy">
                  Reported by {report.reporter_display_name || report.reporter_username || "someone"} on {formatDate(report.created_at)}
                  {" · "}Uploaded by {report.media_owner_display_name || report.media_owner_username || "unknown"}
                  {report.media_deleted_at ? " · Already deleted" : ""}
                </p>
                <span className={`report-status-pill status-${report.status}`}>{report.status}</span>
              </div>
              <div className="admin-report-actions">
                <button type="button" onClick={() => resolveReport(report, "reviewed")} disabled={busyId === String(report.id)}>
                  <CheckCircle2 size={16} />Mark reviewed
                </button>
                <button type="button" onClick={() => resolveReport(report, "dismissed")} disabled={busyId === String(report.id)}>
                  <XCircle size={16} />Dismiss
                </button>
                <button
                  type="button"
                  className="danger"
                  onClick={() => resolveReport(report, "reviewed", { deleteMedia: true })}
                  disabled={busyId === String(report.id) || Boolean(report.media_deleted_at)}
                >
                  <Trash2 size={16} />Delete &amp; resolve
                </button>
              </div>
            </article>
          ))}
          {!loading && !reports.length ? <EmptyState title="No reports here" /> : null}
        </div>
      )}
    </div>
  );
}

function FlaggedTab({ ctx }) {
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState("");
  const showToast = ctx.showToast;

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const data = await apiFetch("/api/admin/flagged-media");
      setItems(data.media || []);
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setLoading(false);
    }
  }, [showToast]);

  useEffect(() => {
    load();
  }, [load]);

  async function resolve(item, decision) {
    setBusyId(String(item.id));
    try {
      await apiFetch(`/api/admin/flagged-media/${item.id}/resolve`, {
        method: "POST",
        body: JSON.stringify({ decision }),
      });
      clearApiCache();
      showToast(`Marked ${decision}.`, "success");
      setItems((rows) => rows.filter((row) => Number(row.id) !== Number(item.id)));
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setBusyId("");
    }
  }

  return (
    <div className="admin-tab">
      <div className="admin-tab-head"><button type="button" onClick={load} disabled={loading}><RefreshCw size={16} />Refresh</button></div>
      {loading ? <SkeletonList /> : (
        <div className="admin-reports-list">
          {items.map((item) => (
            <article className="admin-report-row" key={item.id}>
              <Link to={`/media/${item.id}`} className="admin-report-thumb">
                {item.thumb_url ? <img src={item.thumb_url} alt="" loading="lazy" decoding="async" /> : <Flag size={28} />}
              </Link>
              <div className="admin-report-body">
                <strong>{item.title || `Media #${item.id}`}</strong>
                <p className="admin-report-reason">{item.moderation_reason || "AI/keyword flagged as adult content without uploader confirmation."}</p>
                <p className="muted-copy">Uploaded by {item.owner_display_name || item.owner_username || "unknown"} on {formatDate(item.created_at)}</p>
              </div>
              <div className="admin-report-actions">
                <button type="button" onClick={() => resolve(item, "adult")} disabled={busyId === String(item.id)}><CheckCircle2 size={16} />Confirm 18+</button>
                <button type="button" onClick={() => resolve(item, "clear")} disabled={busyId === String(item.id)}><XCircle size={16} />Clear</button>
              </div>
            </article>
          ))}
          {!loading && !items.length ? <EmptyState title="Nothing flagged for review" /> : null}
        </div>
      )}
    </div>
  );
}

function UsersTab({ ctx }) {
  const [query, setQuery] = useState("");
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(false);
  const [busyId, setBusyId] = useState("");
  const showToast = ctx.showToast;

  async function search(event) {
    event?.preventDefault();
    setLoading(true);
    try {
      const data = await apiFetch(`/api/users/search?q=${encodeURIComponent(query)}&limit=30`);
      setUsers(data.users || []);
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    search();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function ban(user) {
    const reason = window.prompt(`Reason for banning @${user.username}?`, "");
    if (reason === null) return;
    const untilInput = window.prompt("Ban until (YYYY-MM-DD), or leave blank for permanent:", "");
    setBusyId(String(user.id));
    try {
      await apiFetch(`/api/admin/users/${user.id}/ban`, {
        method: "POST",
        body: JSON.stringify({ reason, until: untilInput || null }),
      });
      showToast(`@${user.username} banned.`, "success");
      search();
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setBusyId("");
    }
  }

  async function unban(user) {
    setBusyId(String(user.id));
    try {
      await apiFetch(`/api/admin/users/${user.id}/unban`, { method: "POST" });
      showToast(`@${user.username} unbanned.`, "success");
      search();
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setBusyId("");
    }
  }

  return (
    <div className="admin-tab">
      <form className="mini-form settings-inline-form" onSubmit={search}>
        <label className="field"><span>Search users</span><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="username or display name" /></label>
        <div className="form-actions settings-actions"><button type="submit"><Users size={16} />Search</button></div>
      </form>
      {loading ? <SkeletonList /> : (
        <div className="admin-reports-list">
          {users.map((user) => (
            <article className="admin-report-row" key={user.id}>
              <div className="admin-report-body">
                <strong>{user.display_name || user.username} <small>@{user.username}</small></strong>
                <p className="muted-copy">{user.banned_at ? `Banned${user.banned_until ? ` until ${formatDate(user.banned_until)}` : " permanently"}${user.ban_reason ? ` — ${user.ban_reason}` : ""}` : "Active account"}</p>
              </div>
              <div className="admin-report-actions">
                {user.banned_at ? (
                  <button type="button" onClick={() => unban(user)} disabled={busyId === String(user.id)}><CheckCircle2 size={16} />Unban</button>
                ) : (
                  <button type="button" className="danger" onClick={() => ban(user)} disabled={busyId === String(user.id) || user.site_owner}><Ban size={16} />Ban</button>
                )}
              </div>
            </article>
          ))}
          {!loading && !users.length ? <EmptyState title="No users found" /> : null}
        </div>
      )}
    </div>
  );
}

function StorageTab({ ctx }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [purging, setPurging] = useState(false);
  const showToast = ctx.showToast;

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setData(await apiFetch("/api/admin/storage"));
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setLoading(false);
    }
  }, [showToast]);

  useEffect(() => {
    load();
  }, [load]);

  async function purge() {
    if (!window.confirm("Purge orphaned thumbnail/video cache files older than 24h? Originals are never touched.")) return;
    setPurging(true);
    try {
      const result = await apiFetch("/api/admin/storage/purge-orphans", { method: "POST" });
      showToast(`Removed ${result.removed} file(s), freed ${formatBytes(result.freed_bytes)}.`, "success");
      load();
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setPurging(false);
    }
  }

  if (loading) return <SkeletonList />;
  if (!data) return <EmptyState title="Storage data unavailable" />;

  return (
    <div className="admin-tab">
      <div className="settings-status-grid">
        <div><strong>{formatBytes(data.total_bytes)}</strong><span>Tracked media</span></div>
        <div><strong>{data.total_items}</strong><span>Active items</span></div>
        <div><strong>{formatBytes(data.cache_total_bytes)}</strong><span>Cache size</span></div>
        <div><strong>{formatBytes(data.orphan_bytes)}</strong><span>Orphaned cache ({data.orphan_count})</span></div>
      </div>
      <div className="form-actions settings-actions">
        <button type="button" onClick={purge} disabled={purging || !data.orphan_count}><HardDrive size={16} />{purging ? "Purging..." : "Purge cache orphans"}</button>
      </div>
      <h3>Top storage users</h3>
      <div className="admin-reports-list">
        {(data.by_user || []).map((row) => (
          <article className="admin-report-row" key={row.user_id}>
            <div className="admin-report-body">
              <strong>{row.display_name || row.username}</strong>
              <p className="muted-copy">{row.item_count} item(s)</p>
            </div>
            <strong>{formatBytes(row.total_bytes)}</strong>
          </article>
        ))}
      </div>
    </div>
  );
}

function SiteSettingsTab({ ctx }) {
  const [form, setForm] = useState(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const showToast = ctx.showToast;

  useEffect(() => {
    (async () => {
      setLoading(true);
      try {
        setForm(await apiFetch("/api/site/announcement"));
      } catch (error) {
        showToast(error.message, "error");
      } finally {
        setLoading(false);
      }
    })();
  }, [showToast]);

  async function save(event) {
    event.preventDefault();
    setSaving(true);
    try {
      const data = await apiFetch("/api/admin/site-settings", { method: "PATCH", body: JSON.stringify(form) });
      setForm((current) => ({ ...current, ...data.settings }));
      clearApiCache("/api/site/announcement");
      showToast("Site settings saved.", "success");
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setSaving(false);
    }
  }

  if (loading || !form) return <SkeletonList />;

  return (
    <form className="admin-tab stacked-form" onSubmit={save}>
      <div className="settings-cluster">
        <div className="settings-cluster-head"><h3><Megaphone size={16} /> Site-wide announcement</h3><p>Shows as a dismissible banner to every visitor.</p></div>
        <label className="check-row"><input type="checkbox" checked={Boolean(form.announcement_active)} onChange={(event) => setForm((c) => ({ ...c, announcement_active: event.target.checked }))} />Active</label>
        <label className="field"><span>Message</span><input value={form.announcement_message || ""} onChange={(event) => setForm((c) => ({ ...c, announcement_message: event.target.value }))} maxLength={500} /></label>
        <label className="field"><span>Level</span>
          <select value={form.announcement_level || "info"} onChange={(event) => setForm((c) => ({ ...c, announcement_level: event.target.value }))}>
            <option value="info">Info</option>
            <option value="warning">Warning</option>
            <option value="critical">Critical</option>
          </select>
        </label>
      </div>
      <div className="settings-cluster">
        <div className="settings-cluster-head"><h3>Maintenance mode</h3><p>Shows a full-page maintenance screen to everyone except you.</p></div>
        <label className="check-row"><input type="checkbox" checked={Boolean(form.maintenance_mode)} onChange={(event) => setForm((c) => ({ ...c, maintenance_mode: event.target.checked }))} />Enabled</label>
        <label className="field"><span>Message</span><input value={form.maintenance_message || ""} onChange={(event) => setForm((c) => ({ ...c, maintenance_message: event.target.value }))} maxLength={500} /></label>
      </div>
      <div className="form-actions settings-actions">
        <button className="primary" type="submit" disabled={saving}>{saving ? "Saving..." : "Save site settings"}</button>
      </div>
    </form>
  );
}

function MusicTab({ ctx }) {
  const [tracks, setTracks] = useState([]);
  const [maxTracks, setMaxTracks] = useState(10);
  const [loading, setLoading] = useState(true);
  const [uploading, setUploading] = useState(false);
  const [busyId, setBusyId] = useState("");
  const [title, setTitle] = useState("");
  const [file, setFile] = useState(null);
  const showToast = ctx.showToast;

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const data = await apiFetch("/api/admin/background-music");
      setTracks(data.tracks || []);
      setMaxTracks(data.max_tracks || 10);
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setLoading(false);
    }
  }, [showToast]);

  useEffect(() => {
    load();
  }, [load]);

  async function upload(event) {
    event.preventDefault();
    if (!file) return showToast("Choose an audio file first.", "error");
    setUploading(true);
    try {
      const body = new FormData();
      body.set("file", file);
      body.set("title", title);
      await apiFetch("/api/admin/background-music", { method: "POST", body });
      setTitle("");
      setFile(null);
      const input = document.getElementById("bg-music-file-input");
      if (input) input.value = "";
      showToast("Track added.", "success");
      load();
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setUploading(false);
    }
  }

  async function remove(trackId) {
    if (!window.confirm("Remove this background track?")) return;
    setBusyId(trackId);
    try {
      await apiFetch(`/api/admin/background-music/${trackId}`, { method: "DELETE" });
      setTracks((current) => current.filter((track) => track.id !== trackId));
      showToast("Track removed.", "success");
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      setBusyId("");
    }
  }

  if (loading) return <SkeletonList />;

  return (
    <div className="admin-tab">
      <div className="settings-cluster">
        <div className="settings-cluster-head">
          <h3><Music size={16} /> Background music</h3>
          <p>Shuffled ambient tracks visitors hear while browsing. Ducks out automatically when a video with sound starts playing. Up to {maxTracks} tracks.</p>
        </div>
        {tracks.length < maxTracks ? (
          <form className="stacked-form" onSubmit={upload}>
            <label className="field"><span>Title (optional)</span>
              <input value={title} onChange={(event) => setTitle(event.target.value)} maxLength={120} placeholder="Uses the filename if left blank" />
            </label>
            <label className="field"><span>Audio file</span>
              <input id="bg-music-file-input" type="file" accept="audio/*,.mp3,.wav,.ogg,.flac,.m4a" onChange={(event) => setFile(event.target.files?.[0] || null)} />
            </label>
            <div className="form-actions settings-actions">
              <button className="primary" type="submit" disabled={uploading || !file}><Upload size={16} />{uploading ? "Uploading..." : "Add track"}</button>
            </div>
          </form>
        ) : (
          <p className="muted-copy">Track limit reached — remove one below to add another.</p>
        )}
      </div>

      {tracks.length === 0 ? (
        <EmptyState title="No background tracks yet" description="Add one above to start the ambient shuffle for visitors." />
      ) : (
        <div className="admin-reports-list">
          {tracks.map((track) => (
            <article className="admin-report-row" key={track.id}>
              <div className="admin-report-body">
                <strong>{track.title}</strong>
                <p className="muted-copy">{track.original_filename} · {formatBytes(track.file_size)} · added by {track.uploaded_by_username || "unknown"} · {formatDate(track.created_at)}</p>
                <audio controls preload="none" src={track.url} style={{ marginTop: 8, maxWidth: 320 }} />
              </div>
              <button type="button" onClick={() => remove(track.id)} disabled={busyId === track.id}><Trash2 size={16} />{busyId === track.id ? "Removing..." : "Remove"}</button>
            </article>
          ))}
        </div>
      )}
    </div>
  );
}

function AuditLogTab() {
  const [entries, setEntries] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      setLoading(true);
      try {
        const data = await apiFetch("/api/admin/audit-log?limit=100");
        setEntries(data.entries || []);
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  if (loading) return <SkeletonList />;

  return (
    <div className="admin-tab">
      <div className="admin-reports-list">
        {entries.map((entry) => (
          <article className="admin-report-row" key={entry.id}>
            <History size={20} />
            <div className="admin-report-body">
              <strong>{entry.action} — {entry.target_type}{entry.target_id ? ` #${entry.target_id}` : ""}</strong>
              <p className="muted-copy">
                {entry.actor_display_name || entry.actor_username || "System"} · {formatDate(entry.created_at)}
                {entry.detail ? ` — ${entry.detail}` : ""}
              </p>
            </div>
          </article>
        ))}
        {!entries.length ? <EmptyState title="No moderation activity yet" /> : null}
      </div>
    </div>
  );
}
