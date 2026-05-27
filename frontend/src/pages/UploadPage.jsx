import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Upload, WandSparkles } from "lucide-react";
import { apiFetch, clearApiCache } from "../api.js";
import { MAX_UPLOAD_BYTES } from "../config.js";
import { ChipRow, Page, RequireLogin } from "../components/ui.jsx";

const SUBCATEGORY_SLOT_COUNT = 3;

function blankSubcategorySlots() {
  return Array.from({ length: SUBCATEGORY_SLOT_COUNT }, () => "");
}

function normalizeSlots(values) {
  const slots = Array.isArray(values) ? values.slice(0, SUBCATEGORY_SLOT_COUNT) : [];
  while (slots.length < SUBCATEGORY_SLOT_COUNT) slots.push("");
  return slots.map((value) => String(value || ""));
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
    }
  }

  async function submit(event) {
    event.preventDefault();
    if (!form.file) return ctx.showToast("Choose a file first.", "error");
    if (form.file.size > MAX_UPLOAD_BYTES) return ctx.showToast("Upload is over the configured size limit.", "error");
    setBusy(true);
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
  const analysisChips = analysis
    ? [analysis.media_kind, analysis.source, analysis.category_name, ...(analysis.subcategory_names || []), ...((analysis.tags || []).slice(0, 4))].filter(Boolean)
    : [];

  return (
    <Page title="Upload" eyebrow="Create">
      <form className="upload-layout" onSubmit={submit}>
        <section className="upload-drop">
          <label className="file-picker">
            <input type="file" accept="image/*,video/*" onChange={(event) => update("file", event.target.files?.[0] || null)} />
            {preview ? (form.file?.type?.startsWith("video/") ? <video src={preview} muted playsInline /> : <img src={preview} alt="" />) : <Upload size={42} />}
            <span>{form.file?.name || "Choose media"}</span>
          </label>
          {analysis ? <ChipRow values={analysisChips} /> : null}
          {analysis?.reason ? <p className="muted small">{analysis.reason}</p> : null}
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
