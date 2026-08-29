import { useEffect, useRef, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { Upload, WandSparkles } from "lucide-react";
import { apiFetch, clearApiCache, readToken, resolveApiUrl } from "../api.js";
import { MAX_UPLOAD_BYTES } from "../config.js";
import { ChipRow, Page, RequireLogin } from "../components/ui.jsx";

const SUBCATEGORY_SLOT_COUNT = 3;
const EDGE_SAFE_UPLOAD_BYTES = 80 * 1024 * 1024;
const DEFAULT_CHUNK_BYTES = 20 * 1024 * 1024;

function blankSubcategorySlots() {
  return Array.from({ length: SUBCATEGORY_SLOT_COUNT }, () => "");
}

function normalizeSlots(values) {
  const slots = Array.isArray(values) ? values.slice(0, SUBCATEGORY_SLOT_COUNT) : [];
  while (slots.length < SUBCATEGORY_SLOT_COUNT) slots.push("");
  return slots.map((value) => String(value || ""));
}

function xhrJson(url, { method = "POST", body, contentType, onProgress } = {}) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    const token = readToken();
    xhr.open(method, url, true);
    if (token) xhr.setRequestHeader("Authorization", `Bearer ${token}`);
    xhr.setRequestHeader("Accept", "application/json");
    if (contentType) xhr.setRequestHeader("Content-Type", contentType);
    xhr.withCredentials = true;
    if (onProgress) xhr.upload.addEventListener("progress", onProgress);
    xhr.addEventListener("load", () => {
      let payload = null;
      try { payload = xhr.responseText ? JSON.parse(xhr.responseText) : null; } catch { /* handled below */ }
      if (xhr.status >= 200 && xhr.status < 300) return resolve(payload);
      const detail = payload?.detail;
      reject(new Error(detail ? (Array.isArray(detail) ? detail.map((item) => item?.msg || item).join("; ") : String(detail)) : `Upload failed (${xhr.status})`));
    });
    xhr.addEventListener("error", () => reject(new Error("Network error during upload.")));
    xhr.addEventListener("abort", () => reject(new Error("Upload cancelled.")));
    xhr.send(body);
  });
}

export function UploadPage({ ctx }) {
  const navigate = useNavigate();
  const [form, setForm] = useState({
    file: null,
    title: "",
    description: "",
    category_id: "",
    category_name: "",
    subcategory_ids: blankSubcategorySlots(),
    subcategory_names: blankSubcategorySlots(),
    tags: "",
    is_adult: false,
    visibility: "public",
    comments_enabled: true,
    downloads_enabled: true,
    pinned: false,
    auto_ai: true,
    publish_at: "",
    check_site_duplicates: true,
  });
  const [preview, setPreview] = useState("");
  const [busy, setBusy] = useState(false);
  const [analyzing, setAnalyzing] = useState(false);
  const [uploadProgress, setUploadProgress] = useState(0); // 0–100
  const [dragActive, setDragActive] = useState(false);
  const [analysis, setAnalysis] = useState(null);
  const [duplicates, setDuplicates] = useState([]);
  const dropZoneRef = useRef(null);

  useEffect(() => {
    if (!form.file) {
      setPreview("");
      return undefined;
    }
    const url = URL.createObjectURL(form.file);
    setPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [form.file]);

  useEffect(() => {
    setDuplicates([]);
  }, [form.file]);

  if (!ctx.user) return <RequireLogin />;

  function handleDragOver(event) {
    event.preventDefault();
    event.stopPropagation();
    setDragActive(true);
  }

  function handleDragLeave(event) {
    event.preventDefault();
    event.stopPropagation();
    // Only deactivate if we've left the drop zone entirely
    if (!dropZoneRef.current?.contains(event.relatedTarget)) {
      setDragActive(false);
    }
  }

  function handleDrop(event) {
    event.preventDefault();
    event.stopPropagation();
    setDragActive(false);
    const file = event.dataTransfer?.files?.[0];
    if (file && (file.type.startsWith("image/") || file.type.startsWith("video/"))) {
      update("file", file);
    } else if (file) {
      ctx.showToast("Only image and video files are accepted.", "error");
    }
  }

  function update(key, value) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  function updateSubcategorySlot(kind, index, value) {
    setForm((current) => {
      const next = normalizeSlots(current[kind]);
      next[index] = value;
      return { ...current, [kind]: next };
    });
  }

  async function analyze() {
    if (!form.file) return;
    setBusy(true);
    setAnalyzing(true);
    try {
      const body = new FormData();
      body.set("file", form.file);
      body.set("title", form.title);
      body.set("description", form.description);
      body.set("tags", form.tags);
      // AI vision analysis can legitimately take up to ai_timeout_seconds+10 on the
      // backend (default 55s) before falling back to local heuristics, well past the
      // default 12s apiFetch timeout — use a longer timeout so real analyses don't abort.
      const data = await apiFetch("/api/media/analyze", { method: "POST", body, timeoutMs: 90_000 });
      setAnalysis(data.analysis);
      setDuplicates(data.possible_duplicates || []);
      setForm((current) => ({
        ...current,
        title: current.title || data.analysis?.title || "",
        category_name: current.category_name || data.analysis?.category_name || "",
        subcategory_names: normalizeSlots(current.subcategory_names).map((value, index) => {
          if (value) return value;
          return String(data.analysis?.subcategory_names?.[index] || "");
        }),
        tags: current.tags || (data.analysis?.tags || []).join(", "),
        is_adult: current.is_adult || Boolean(data.analysis?.is_adult),
      }));
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
      setAnalyzing(false);
    }
  }

  async function submit(event) {
    event.preventDefault();
    if (!form.file) return ctx.showToast("Choose a file first.", "error");
    if (form.file.size > MAX_UPLOAD_BYTES) return ctx.showToast("Upload is over the configured size limit.", "error");
    if (duplicates.length) {
      const proceed = window.confirm(
        `This looks similar to ${duplicates.length} post${duplicates.length === 1 ? "" : "s"} already in your library. Upload anyway?`,
      );
      if (!proceed) return;
    }
    setBusy(true);
    setUploadProgress(0);
    try {
      const body = new FormData();
      if (form.file) body.set("file", form.file);
      body.set("title", form.title);
      body.set("description", form.description);
      body.set("category_id", form.category_id);
      body.set("category_name", form.category_name);
      body.set("subcategory_id", form.subcategory_ids.find(Boolean) || "");
      body.set("subcategory_name", form.subcategory_names.find((value) => value.trim()) || "");
      body.set("subcategory_ids_json", JSON.stringify(normalizeSlots(form.subcategory_ids).filter(Boolean)));
      body.set(
        "subcategory_names_json",
        JSON.stringify(normalizeSlots(form.subcategory_names).map((value) => value.trim()).filter(Boolean)),
      );
      body.set("tags", form.tags);
      body.set("is_adult", String(form.is_adult));
      body.set("visibility", form.visibility);
      body.set("comments_enabled", String(form.comments_enabled));
      body.set("downloads_enabled", String(form.downloads_enabled));
      body.set("pinned", String(form.pinned));
      body.set("auto_ai", String(form.auto_ai));
      body.set("check_site_duplicates", String(form.check_site_duplicates));
      if (form.publish_at) body.set("publish_at", new Date(form.publish_at).toISOString());

      let data;
      if (form.file.size <= EDGE_SAFE_UPLOAD_BYTES) {
        const url = await resolveApiUrl("/api/media");
        data = await xhrJson(url, {
          body,
          onProgress: (progressEvent) => {
            if (progressEvent.lengthComputable) setUploadProgress(Math.round((progressEvent.loaded / progressEvent.total) * 100));
          },
        });
      } else {
        const init = await apiFetch("/api/media/upload/init", {
          method: "POST",
          body: { total_size: form.file.size, filename: form.file.name },
        });
        const chunkSize = Number(init.chunk_size) > 0 ? Number(init.chunk_size) : DEFAULT_CHUNK_BYTES;
        const initUrl = await resolveApiUrl("/api/media/upload/chunk");
        let uploaded = 0;
        for (let index = 0; uploaded < form.file.size; index += 1) {
          const chunk = form.file.slice(uploaded, Math.min(uploaded + chunkSize, form.file.size));
          await xhrJson(`${initUrl}?session_id=${encodeURIComponent(init.session_id)}&index=${index}`, {
            body: chunk,
            contentType: "application/octet-stream",
            onProgress: (progressEvent) => {
              const chunkLoaded = progressEvent.lengthComputable ? progressEvent.loaded : 0;
              setUploadProgress(Math.round(((uploaded + chunkLoaded) / form.file.size) * 100));
            },
          });
          uploaded += chunk.size;
          setUploadProgress(Math.round((uploaded / form.file.size) * 100));
        }
        const metadata = Object.fromEntries([...body.entries()].filter(([key]) => key !== "file"));
        data = await apiFetch("/api/media/upload/finish", {
          method: "POST",
          body: {
            ...metadata,
            session_id: init.session_id,
            total_size: form.file.size,
          },
        });
      }

      clearApiCache();
      ctx.refreshLookups();
      if (!duplicates.length && data.possible_duplicates?.length) {
        ctx.showToast(
          `Uploaded — heads up, ${data.possible_duplicates.length} similar post${data.possible_duplicates.length === 1 ? "" : "s"} already exist in your library.`,
          "info",
        );
      } else if (data.possible_site_duplicates?.length) {
        ctx.showToast(
          `Uploaded — heads up, ${data.possible_site_duplicates.length} similar post${data.possible_site_duplicates.length === 1 ? "" : "s"} already exist elsewhere on the site.`,
          "info",
        );
      } else {
        ctx.showToast("Upload saved.", "success");
      }
      navigate(`/media/${data.media.id}`);
    } catch (error) {
      ctx.showToast(error.message, "error");
      setUploadProgress(0);
    } finally {
      setBusy(false);
    }
  }

  const selectedCategory = ctx.lookups.categories.find((category) => String(category.id) === String(form.category_id));
  const subcategories = selectedCategory?.subcategories || selectedCategory?.children || [];
  const analysisChips = analysis
    ? [analysis.media_kind, analysis.source, analysis.category_name, ...(analysis.subcategory_names || []), ...((analysis.tags || []).slice(0, 4))].filter(Boolean)
    : [];

  return (
    <Page title="Upload" eyebrow="Create">
      <form className="upload-layout" onSubmit={submit}>
        <section
          ref={dropZoneRef}
          className={`upload-drop${dragActive ? " drag-active" : ""}`}
          onDragOver={handleDragOver}
          onDragEnter={handleDragOver}
          onDragLeave={handleDragLeave}
          onDrop={handleDrop}
        >
          <label className="file-picker">
            <input type="file" accept="image/*,video/*" onChange={(event) => update("file", event.target.files?.[0] || null)} />
            {preview ? (form.file?.type?.startsWith("video/") ? <video src={preview} muted playsInline /> : <img src={preview} alt="" />) : (
              <>
                <Upload size={42} />
                <span className="file-picker-hint">{dragActive ? "Drop to upload" : "Click or drag a file here"}</span>
              </>
            )}
            <span>{form.file?.name || ""}</span>
          </label>
          {busy && uploadProgress > 0 && uploadProgress < 100 ? (
            <div className="upload-progress-wrap" aria-label={`Upload progress: ${uploadProgress}%`}>
              <div className="upload-progress-bar" style={{ width: `${uploadProgress}%` }} />
              <span className="upload-progress-label">{uploadProgress}%</span>
            </div>
          ) : null}
          {analysis ? <ChipRow values={analysisChips} /> : null}
          {analysis?.reason ? <p className="muted small">{analysis.reason}</p> : null}
          {duplicates.length ? (
            <div className="upload-duplicate-warning" role="alert">
              <p className="muted small">
                Looks similar to {duplicates.length} post{duplicates.length === 1 ? "" : "s"} already in your library:
              </p>
              <div className="upload-duplicate-thumbs">
                {duplicates.map((dup) => (
                  <Link key={dup.id} to={`/media/${dup.id}`} target="_blank" title={dup.title || `Post #${dup.id}`}>
                    <img src={dup.thumb_url} alt={dup.title || `Post #${dup.id}`} />
                  </Link>
                ))}
              </div>
            </div>
          ) : null}
        </section>
        <section className="stacked-form">
          <label className="field"><span>Title</span><input value={form.title} onChange={(event) => update("title", event.target.value)} required maxLength={160} /></label>
          <label className="field"><span>Description</span><textarea value={form.description} onChange={(event) => update("description", event.target.value)} rows={4} maxLength={2000} /></label>
          <div className="two-col">
            <label className="field"><span>Category</span><select value={form.category_id} onChange={(event) => setForm((current) => ({ ...current, category_id: event.target.value, category_name: event.target.value ? "" : current.category_name, subcategory_ids: blankSubcategorySlots() }))}><option value="">New category</option>{ctx.lookups.categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}</select></label>
            <label className="field"><span>New category</span><input value={form.category_name} onChange={(event) => update("category_name", event.target.value)} disabled={Boolean(form.category_id)} /></label>
          </div>
          {Array.from({ length: SUBCATEGORY_SLOT_COUNT }, (_, index) => (
            <div className="two-col" key={`subcategory-slot-${index}`}>
              <label className="field">
                <span>{`Subcategory ${index + 1}`}</span>
                <select value={normalizeSlots(form.subcategory_ids)[index]} onChange={(event) => updateSubcategorySlot("subcategory_ids", index, event.target.value)} disabled={!subcategories.length}>
                  <option value="">None</option>
                  {subcategories.map((subcategory) => <option key={subcategory.id} value={subcategory.id}>{subcategory.name}</option>)}
                </select>
              </label>
              <label className="field">
                <span>{`New subcategory ${index + 1}`}</span>
                <input value={normalizeSlots(form.subcategory_names)[index]} onChange={(event) => updateSubcategorySlot("subcategory_names", index, event.target.value)} placeholder={index === 0 ? "Series or group" : index === 1 ? "Character or subject" : "Variant or context"} />
              </label>
            </div>
          ))}
          <label className="field"><span>Tags</span><input value={form.tags} onChange={(event) => update("tags", event.target.value)} placeholder="comma separated" /></label>
          <div className="two-col">
            <label className="field"><span>Visibility</span><select value={form.visibility} onChange={(event) => update("visibility", event.target.value)}><option value="public">Public</option><option value="unlisted">Unlisted</option><option value="private">Private</option></select></label>
            <label className="field"><span>Schedule for later <small>(optional)</small></span><input type="datetime-local" value={form.publish_at} onChange={(event) => update("publish_at", event.target.value)} /></label>
          </div>
          <div className="two-col">
            <div className="check-stack">
              <label className="check-row"><input checked={form.auto_ai} onChange={(event) => update("auto_ai", event.target.checked)} type="checkbox" />AI metadata</label>
              <label className="check-row"><input checked={form.is_adult} onChange={(event) => update("is_adult", event.target.checked)} type="checkbox" />18+</label>
              <label className="check-row"><input checked={form.comments_enabled} onChange={(event) => update("comments_enabled", event.target.checked)} type="checkbox" />Comments</label>
              <label className="check-row"><input checked={form.downloads_enabled} onChange={(event) => update("downloads_enabled", event.target.checked)} type="checkbox" />Downloads</label>
              <label className="check-row"><input checked={form.check_site_duplicates} onChange={(event) => update("check_site_duplicates", event.target.checked)} type="checkbox" />Check across the whole site</label>
            </div>
          </div>
          <div className="form-actions">
            <button type="button" onClick={analyze} disabled={busy || !form.file}><WandSparkles size={16} />{analyzing ? "Analyzing…" : "Analyze"}</button>
            <button className="primary" type="submit" disabled={busy || !form.file}><Upload size={16} />{busy ? "Working" : "Upload"}</button>
          </div>
        </section>
      </form>
    </Page>
  );
}
