import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Upload, WandSparkles } from "lucide-react";
import { apiFetch, clearApiCache } from "../api.js";
import { MAX_UPLOAD_BYTES } from "../config.js";
import { ChipRow, Page, RequireLogin } from "../components/ui.jsx";

export function UploadPage({ ctx }) {
  const navigate = useNavigate();
  const [form, setForm] = useState({
    file: null,
    title: "",
    description: "",
    category_id: "",
    category_name: "",
    subcategory_id: "",
    subcategory_name: "",
    tags: "",
    is_adult: false,
    visibility: "public",
    comments_enabled: true,
    downloads_enabled: true,
    pinned: false,
    auto_ai: true,
  });
  const [preview, setPreview] = useState("");
  const [busy, setBusy] = useState(false);
  const [analysis, setAnalysis] = useState(null);

  useEffect(() => {
    if (!form.file) {
      setPreview("");
      return undefined;
    }
    const url = URL.createObjectURL(form.file);
    setPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [form.file]);

  if (!ctx.user) return <RequireLogin />;

  function update(key, value) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  async function analyze() {
    if (!form.file) return;
    setBusy(true);
    try {
      const body = new FormData();
      body.set("file", form.file);
      body.set("title", form.title);
      body.set("description", form.description);
      body.set("tags", form.tags);
      const data = await apiFetch("/api/media/analyze", { method: "POST", body });
      setAnalysis(data.analysis);
      setForm((current) => ({
        ...current,
        title: current.title || data.analysis?.title || "",
        description: current.description || data.analysis?.description || "",
        category_name: current.category_name || data.analysis?.category_name || "",
        subcategory_name: current.subcategory_name || data.analysis?.subcategory_name || "",
        tags: current.tags || (data.analysis?.tags || []).join(", "),
        is_adult: current.is_adult || Boolean(data.analysis?.is_adult),
      }));
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  async function submit(event) {
    event.preventDefault();
    if (!form.file) return ctx.showToast("Choose a file first.", "error");
    if (form.file.size > MAX_UPLOAD_BYTES) return ctx.showToast("Upload is over the configured size limit.", "error");
    setBusy(true);
    try {
      const body = new FormData();
      Object.entries(form).forEach(([key, value]) => {
        if (key === "file" && value) body.set("file", value);
        else if (value !== null && value !== undefined) body.set(key, String(value));
      });
      const data = await apiFetch("/api/media", { method: "POST", body });
      clearApiCache();
      ctx.refreshLookups();
      ctx.showToast("Upload saved.", "success");
      navigate(`/media/${data.media.id}`);
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  const selectedCategory = ctx.lookups.categories.find((category) => String(category.id) === String(form.category_id));
  const subcategories = selectedCategory?.subcategories || selectedCategory?.children || [];

  return (
    <Page title="Upload" eyebrow="Create">
      <form className="upload-layout" onSubmit={submit}>
        <section className="upload-drop">
          <label className="file-picker">
            <input type="file" accept="image/*,video/*" onChange={(event) => update("file", event.target.files?.[0] || null)} />
            {preview ? (form.file?.type?.startsWith("video/") ? <video src={preview} muted playsInline /> : <img src={preview} alt="" />) : <Upload size={42} />}
            <span>{form.file?.name || "Choose media"}</span>
          </label>
          {analysis ? <ChipRow values={[analysis.media_kind, analysis.category_name, ...(analysis.tags || [])]} /> : null}
        </section>
        <section className="stacked-form">
          <label className="field"><span>Title</span><input value={form.title} onChange={(event) => update("title", event.target.value)} required maxLength={160} /></label>
          <label className="field"><span>Description</span><textarea value={form.description} onChange={(event) => update("description", event.target.value)} rows={4} maxLength={2000} /></label>
          <div className="two-col">
            <label className="field"><span>Category</span><select value={form.category_id} onChange={(event) => update("category_id", event.target.value)}><option value="">New category</option>{ctx.lookups.categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}</select></label>
            <label className="field"><span>Subcategory</span><select value={form.subcategory_id} onChange={(event) => update("subcategory_id", event.target.value)} disabled={!subcategories.length}><option value="">None</option>{subcategories.map((subcategory) => <option key={subcategory.id} value={subcategory.id}>{subcategory.name}</option>)}</select></label>
          </div>
          <div className="two-col">
            <label className="field"><span>New category</span><input value={form.category_name} onChange={(event) => update("category_name", event.target.value)} disabled={Boolean(form.category_id)} /></label>
            <label className="field"><span>New subcategory</span><input value={form.subcategory_name} onChange={(event) => update("subcategory_name", event.target.value)} /></label>
          </div>
          <label className="field"><span>Tags</span><input value={form.tags} onChange={(event) => update("tags", event.target.value)} placeholder="comma separated" /></label>
          <div className="two-col">
            <label className="field"><span>Visibility</span><select value={form.visibility} onChange={(event) => update("visibility", event.target.value)}><option value="public">Public</option><option value="unlisted">Unlisted</option><option value="private">Private</option></select></label>
            <div className="check-stack">
              <label className="check-row"><input checked={form.auto_ai} onChange={(event) => update("auto_ai", event.target.checked)} type="checkbox" />AI metadata</label>
              <label className="check-row"><input checked={form.is_adult} onChange={(event) => update("is_adult", event.target.checked)} type="checkbox" />18+</label>
              <label className="check-row"><input checked={form.comments_enabled} onChange={(event) => update("comments_enabled", event.target.checked)} type="checkbox" />Comments</label>
              <label className="check-row"><input checked={form.downloads_enabled} onChange={(event) => update("downloads_enabled", event.target.checked)} type="checkbox" />Downloads</label>
            </div>
          </div>
          <div className="form-actions">
            <button type="button" onClick={analyze} disabled={busy || !form.file}><WandSparkles size={16} />Analyze</button>
            <button className="primary" type="submit" disabled={busy || !form.file}><Upload size={16} />{busy ? "Working" : "Upload"}</button>
          </div>
        </section>
      </form>
    </Page>
  );
}
