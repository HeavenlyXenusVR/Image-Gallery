import { useState } from "react";
import { Check, KeyRound, Mail, Palette, Save, ShieldCheck, UserRound } from "lucide-react";
import { apiFetch } from "../api.js";
import { Page, RequireLogin } from "../components/ui.jsx";

export function SettingsPage({ ctx }) {
  const [profile, setProfile] = useState(() => ({
    display_name: ctx.user?.display_name || ctx.user?.username || "",
    bio: ctx.user?.bio || "",
    website_url: ctx.user?.website_url || "",
    location_label: ctx.user?.location_label || "",
    profile_headline: ctx.user?.profile_headline || "",
    featured_tags: (ctx.user?.featured_tags || []).join(", "),
    profile_color: ctx.user?.profile_color || ctx.settings.accent_color || "#37c9a7",
    public_profile: ctx.user?.public_profile !== false,
    show_liked_count: ctx.user?.show_liked_count !== false,
    show_collections: ctx.user?.show_collections !== false,
    show_recent_uploads: ctx.user?.show_recent_uploads !== false,
    show_friends: ctx.user?.show_friends !== false,
  }));
  const [prefs, setPrefs] = useState(ctx.settings);
  const [email, setEmail] = useState(ctx.user?.email || "");
  const [emailCode, setEmailCode] = useState("");
  const [age, setAge] = useState({ birthdate: "", confirm_over_18: false });
  const [password, setPassword] = useState({ old_password: "", new_password: "" });

  if (!ctx.user) return <RequireLogin />;

  function updateProfile(key, value) {
    setProfile((current) => ({ ...current, [key]: value }));
  }

  function updatePrefs(key, value) {
    setPrefs((current) => ({ ...current, [key]: value }));
  }

  async function saveProfile(event) {
    event.preventDefault();
    try {
      const profilePayload = {
        ...profile,
        featured_tags: profile.featured_tags.split(",").map((tag) => tag.trim()).filter(Boolean),
      };
      let data = await apiFetch("/api/me/profile", { method: "PATCH", body: JSON.stringify(profilePayload) });
      data = await apiFetch("/api/me/settings", { method: "PATCH", body: JSON.stringify(prefs) });
      ctx.setSessionUser(data.user);
      ctx.showToast("Settings saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function saveEmail(event) {
    event.preventDefault();
    try {
      const data = await apiFetch("/api/me/email", { method: "POST", body: JSON.stringify({ email }) });
      ctx.setSessionUser(data.user);
      ctx.showToast(data.email_verification_sent ? "Verification sent." : "Email saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function verifyEmail(event) {
    event.preventDefault();
    try {
      const data = await apiFetch("/api/me/email/verify", { method: "POST", body: JSON.stringify({ code: emailCode }) });
      ctx.setSessionUser(data.user);
      setEmailCode("");
      ctx.showToast("Email verified.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function saveAvatar(event) {
    const file = event.target.files?.[0];
    if (!file) return;
    try {
      const body = new FormData();
      body.set("file", file);
      const data = await apiFetch("/api/me/avatar", { method: "POST", body });
      ctx.setSessionUser(data.user);
      ctx.showToast("Avatar saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function saveAge(event) {
    event.preventDefault();
    try {
      const data = await apiFetch("/api/me/age-verification", { method: "POST", body: JSON.stringify(age) });
      ctx.setSessionUser(data.user);
      ctx.showToast("Age verification saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function changePassword(event) {
    event.preventDefault();
    try {
      await apiFetch("/api/me/password", { method: "POST", body: JSON.stringify(password) });
      setPassword({ old_password: "", new_password: "" });
      ctx.showToast("Password changed.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  return (
    <Page title="Settings" eyebrow="Account">
      <section className="settings-grid">
        <form className="stacked-form side-box" onSubmit={saveProfile}>
          <h2><UserRound size={18} /> Profile</h2>
          <label className="field"><span>Display name</span><input value={profile.display_name} onChange={(event) => updateProfile("display_name", event.target.value)} required /></label>
          <label className="field"><span>Headline</span><input value={profile.profile_headline} onChange={(event) => updateProfile("profile_headline", event.target.value)} /></label>
          <label className="field"><span>Bio</span><textarea value={profile.bio} onChange={(event) => updateProfile("bio", event.target.value)} rows={4} /></label>
          <div className="two-col">
            <label className="field"><span>Website</span><input value={profile.website_url} onChange={(event) => updateProfile("website_url", event.target.value)} /></label>
            <label className="field"><span>Location</span><input value={profile.location_label} onChange={(event) => updateProfile("location_label", event.target.value)} /></label>
          </div>
          <label className="field"><span>Featured tags</span><input value={profile.featured_tags} onChange={(event) => updateProfile("featured_tags", event.target.value)} /></label>
          <label className="field color-field"><span>Color</span><input value={profile.profile_color} onChange={(event) => updateProfile("profile_color", event.target.value)} type="color" /></label>
          <div className="check-stack">
            <label className="check-row"><input checked={profile.public_profile} onChange={(event) => updateProfile("public_profile", event.target.checked)} type="checkbox" />Public profile</label>
            <label className="check-row"><input checked={profile.show_collections} onChange={(event) => updateProfile("show_collections", event.target.checked)} type="checkbox" />Collections</label>
            <label className="check-row"><input checked={profile.show_recent_uploads} onChange={(event) => updateProfile("show_recent_uploads", event.target.checked)} type="checkbox" />Uploads</label>
            <label className="check-row"><input checked={profile.show_friends} onChange={(event) => updateProfile("show_friends", event.target.checked)} type="checkbox" />Friends</label>
          </div>
          <button className="primary" type="submit"><Save size={16} />Save</button>
        </form>
        <form className="stacked-form side-box" onSubmit={saveProfile}>
          <h2><Palette size={18} /> Preferences</h2>
          <div className="two-col">
            <label className="field"><span>Theme</span><select value={prefs.theme_mode} onChange={(event) => updatePrefs("theme_mode", event.target.value)}><option value="system">System</option><option value="dark">Dark</option><option value="light">Light</option></select></label>
            <label className="field"><span>Grid</span><select value={prefs.grid_density} onChange={(event) => updatePrefs("grid_density", event.target.value)}><option value="compact">Compact</option><option value="comfortable">Comfortable</option><option value="large">Large</option></select></label>
          </div>
          <div className="two-col">
            <label className="field"><span>Sort</span><select value={prefs.default_sort} onChange={(event) => updatePrefs("default_sort", event.target.value)}><option value="new">Newest</option><option value="popular">Popular</option><option value="views">Views</option><option value="downloads">Downloads</option></select></label>
            <label className="field"><span>Items</span><input type="number" min="12" max="60" value={prefs.items_per_page} onChange={(event) => updatePrefs("items_per_page", Number(event.target.value))} /></label>
          </div>
          <div className="check-stack">
            <label className="check-row"><input checked={prefs.autoplay_previews} onChange={(event) => updatePrefs("autoplay_previews", event.target.checked)} type="checkbox" />Autoplay</label>
            <label className="check-row"><input checked={prefs.muted_previews} onChange={(event) => updatePrefs("muted_previews", event.target.checked)} type="checkbox" />Muted previews</label>
            <label className="check-row"><input checked={prefs.reduce_motion} onChange={(event) => updatePrefs("reduce_motion", event.target.checked)} type="checkbox" />Reduced motion</label>
            <label className="check-row"><input checked={prefs.open_original_in_new_tab} onChange={(event) => updatePrefs("open_original_in_new_tab", event.target.checked)} type="checkbox" />Originals in new tab</label>
          </div>
          <button className="primary" type="submit"><Save size={16} />Save</button>
        </form>
        <div className="side-box stacked-form">
          <h2><ShieldCheck size={18} /> Identity</h2>
          <label className="field"><span>Avatar</span><input type="file" accept="image/*" onChange={saveAvatar} /></label>
          <form className="mini-form" onSubmit={saveEmail}>
            <label className="field"><span>Email</span><input type="email" value={email} onChange={(event) => setEmail(event.target.value)} /></label>
            <button type="submit"><Mail size={16} />Save Email</button>
          </form>
          <form className="mini-form" onSubmit={verifyEmail}>
            <label className="field"><span>Code</span><input value={emailCode} onChange={(event) => setEmailCode(event.target.value)} /></label>
            <button type="submit"><Check size={16} />Verify</button>
          </form>
          <form className="mini-form" onSubmit={saveAge}>
            <label className="field"><span>Birthdate</span><input type="date" value={age.birthdate} onChange={(event) => setAge((current) => ({ ...current, birthdate: event.target.value }))} /></label>
            <label className="check-row"><input checked={age.confirm_over_18} onChange={(event) => setAge((current) => ({ ...current, confirm_over_18: event.target.checked }))} type="checkbox" />I am 18+</label>
            <button type="submit"><ShieldCheck size={16} />Verify Age</button>
          </form>
        </div>
        <form className="side-box stacked-form" onSubmit={changePassword}>
          <h2><KeyRound size={18} /> Password</h2>
          <label className="field"><span>Current</span><input type="password" value={password.old_password} onChange={(event) => setPassword((current) => ({ ...current, old_password: event.target.value }))} /></label>
          <label className="field"><span>New</span><input type="password" value={password.new_password} onChange={(event) => setPassword((current) => ({ ...current, new_password: event.target.value }))} /></label>
          <button type="submit">Change</button>
        </form>
      </section>
    </Page>
  );
}
