import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { CheckCircle2, RefreshCw, ShieldAlert, Trash2, XCircle } from "lucide-react";
import { apiFetch, clearApiCache } from "../api.js";
import { EmptyState, Notice, Page, Segmented, SkeletonList } from "../components/ui.jsx";
import { formatDate } from "../utils/format.js";

const STATUS_FILTERS = [["open", "Open"], ["reviewed", "Reviewed"], ["dismissed", "Dismissed"], ["", "All"]];

export function AdminPage({ ctx }) {
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
      title="Moderation Reports"
      eyebrow="Admin"
      lede="Review reported posts, dismiss non-issues, or remove the media and close the report."
      actions={(
        <>
          <Segmented value={status} onChange={setStatus} options={STATUS_FILTERS} />
          <button type="button" onClick={loadReports} disabled={loading}><RefreshCw size={16} />Refresh</button>
        </>
      )}
    >
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
    </Page>
  );
}
