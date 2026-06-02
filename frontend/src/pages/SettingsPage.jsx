import { useEffect, useState } from "react";
import { Check, Eye, KeyRound, Mail, Palette, Save, ShieldCheck, UserRound } from "lucide-react";
import { apiFetch, clearApiCache } from "../api.js";
import { Avatar, ChipRow, Page, RequireLogin } from "../components/ui.jsx";
import { profileClassName, profileStyle } from "../utils/appearance.js";

function profileFromUser(user, settings) {
  return {
    display_name: user?.display_name || user?.username || "",
    bio: user?.bio || "",
    profile_quote: user?.profile_quote || "",
    website_url: user?.website_url || "",
    location_label: user?.location_label || "",
    profile_headline: user?.profile_headline || "",
    featured_tags: (user?.featured_tags || []).join(", "),
    profile_color: user?.profile_color || settings.accent_color || "#37c9a7",
    public_profile: user?.public_profile !== false,
    show_liked_count: user?.show_liked_count !== false,
    show_collections: user?.show_collections !== false,
    show_recent_uploads: user?.show_recent_uploads !== false,
    show_friends: user?.show_friends !== false,
  };
}

export function SettingsPage({ ctx }) {
  const [profile, setProfile] = useState(() => profileFromUser(ctx.user, ctx.settings));
  const [prefs, setPrefs] = useState(ctx.settings);
  const [email, setEmail] = useState(ctx.user?.email || "");
  const [emailCode, setEmailCode] = useState("");
  const [age, setAge] = useState({ birthdate: "", confirm_over_18: false });
  const [password, setPassword] = useState({ old_password: "", new_password: "" });

  useEffect(() => {
    if (!ctx.user) return;
    setProfile(profileFromUser(ctx.user, ctx.settings));
    setPrefs(ctx.settings);
    setEmail(ctx.user.email || "");
  }, [ctx.settings, ctx.user]);

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
      const profileData = await apiFetch("/api/me/profile", { method: "PATCH", body: JSON.stringify(profilePayload) });
      ctx.setSessionUser(profileData.user);
      clearApiCache();
      ctx.showToast("Profile saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function savePrefs(event) {
    event.preventDefault();
    try {
      const prefsData = await apiFetch("/api/me/settings", { method: "PATCH", body: JSON.stringify(prefs) });
      ctx.setSessionUser(prefsData.user);
      clearApiCache();
      ctx.showToast("Preferences saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function saveEmail(event) {
    event.preventDefault();
    try {
      const data = await apiFetch("/api/me/email", { method: "POST", body: JSON.stringify({ email }) });
      ctx.setSessionUser(data.user);
      clearApiCache();
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
      clearApiCache();
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
      clearApiCache();
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
      clearApiCache();
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
    <Page
      title="Settings"
      eyebrow="Account"
      lede="Shape how your gallery identity looks, feels, and behaves across public profile, discover, and playback surfaces."
      className="page-settings"
    >
      <section className="settings-page-layout">
        <div className="settings-preview-column">
          <aside className={`side-box profile-settings-preview ${profileClassName(prefs)}`} style={profileStyle({ ...prefs, accent_color: profile.profile_color || prefs.accent_color })}>
            <div className="section-head"><h2><Eye size={18} /> Profile Preview</h2></div>
            <div className="profile-preview-hero">
              <Avatar user={{ ...ctx.user, ...profile, featured_tags: undefined }} large />
              <div>
                <strong>{profile.profile_headline || profile.display_name || ctx.user.username}</strong>
                <p>{profile.bio || "No bio yet."}</p>
                <ChipRow values={profile.featured_tags.split(",").map((tag) => tag.trim()).filter(Boolean)} />
              </div>
            </div>
            <div className="profile-social-preview settings-preview-metrics">
              <div><strong>{prefs.profile_layout}</strong><span>Layout</span></div>
              <div><strong>{prefs.profile_banner_style}</strong><span>Banner</span></div>
              <div><strong>{prefs.profile_featured_panel}</strong><span>Feature</span></div>
            </div>
            <div className="chip-row settings-preview-chips">
              <span>{prefs.theme_mode}</span>
              <span>{prefs.grid_density}</span>
              <span>{prefs.profile_social_layout}</span>
              <span>{prefs.profile_card_style}</span>
            </div>
          </aside>
          <section className="side-box settings-status-card">
            <div className="section-head"><h2>Command Snapshot</h2></div>
            <div className="settings-status-grid">
              <div><strong>{profile.public_profile ? "Public" : "Private"}</strong><span>Visibility</span></div>
              <div><strong>{ctx.user.age_verified_at ? "Verified" : "Pending"}</strong><span>Age Gate</span></div>
              <div><strong>{prefs.autoplay_previews ? "Auto" : "Manual"}</strong><span>Preview Motion</span></div>
              <div><strong>{prefs.open_original_in_new_tab ? "New Tab" : "Inline"}</strong><span>Originals</span></div>
            </div>
          </section>
        </div>
        <div className="settings-stack">
          <form className="stacked-form side-box settings-form-card" onSubmit={saveProfile}>
            <h2><UserRound size={18} /> Profile</h2>
            <div className="settings-cluster">
            <div className="settings-cluster-head"><h3>Identity</h3><p>The public-facing copy and metadata visitors see first.</p></div>
            <label className="field"><span>Display name</span><input value={profile.display_name} onChange={(event) => updateProfile("display_name", event.target.value)} required /></label>
            <label className="field"><span>Headline</span><input value={profile.profile_headline} onChange={(event) => updateProfile("profile_headline", event.target.value)} placeholder="What should your profile lead with?" /></label>
            <label className="field"><span>Bio</span><textarea value={profile.bio} onChange={(event) => updateProfile("bio", event.target.value)} rows={4} /></label>
            <label className="field"><span>Signature / Quote <small>(shown under your name)</small></span><input value={profile.profile_quote} onChange={(event) => updateProfile("profile_quote", event.target.value)} placeholder="A line that captures your vibe or aesthetic" maxLength={200} /></label>
            <div className="two-col">
              <label className="field"><span>Website</span><input value={profile.website_url} onChange={(event) => updateProfile("website_url", event.target.value)} /></label>
              <label className="field"><span>Location</span><input value={profile.location_label} onChange={(event) => updateProfile("location_label", event.target.value)} /></label>
            </div>
            <label className="field"><span>Featured tags</span><input value={profile.featured_tags} onChange={(event) => updateProfile("featured_tags", event.target.value)} placeholder="artist, wallpapers, retro, edits" /></label>
            <label className="field color-field settings-color-field"><span>Color</span><input value={profile.profile_color} onChange={(event) => updateProfile("profile_color", event.target.value)} type="color" /></label>
          </div>
            <div className="settings-cluster">
            <div className="settings-cluster-head"><h3>Visibility</h3><p>Choose which counts and profile sections remain public.</p></div>
            <div className="check-stack settings-check-grid">
              <label className="check-row"><input checked={profile.public_profile} onChange={(event) => updateProfile("public_profile", event.target.checked)} type="checkbox" />Public profile</label>
              <label className="check-row"><input checked={profile.show_liked_count} onChange={(event) => updateProfile("show_liked_count", event.target.checked)} type="checkbox" />Liked count</label>
              <label className="check-row"><input checked={profile.show_collections} onChange={(event) => updateProfile("show_collections", event.target.checked)} type="checkbox" />Collections</label>
              <label className="check-row"><input checked={profile.show_recent_uploads} onChange={(event) => updateProfile("show_recent_uploads", event.target.checked)} type="checkbox" />Uploads</label>
              <label className="check-row"><input checked={profile.show_friends} onChange={(event) => updateProfile("show_friends", event.target.checked)} type="checkbox" />Friends</label>
            </div>
          </div>
            <div className="form-actions settings-actions">
              <button className="primary" type="submit"><Save size={16} />Save Profile</button>
            </div>
          </form>
          <form className="stacked-form side-box settings-form-card" onSubmit={savePrefs}>
            <h2><Palette size={18} /> Preferences</h2>
            <div className="settings-cluster">
            <div className="settings-cluster-head"><h3>Gallery Defaults</h3><p>Control theme, density, sorting, and how much of the deck is visible at once.</p></div>
            <div className="two-col">
              <label className="field"><span>Theme</span><select value={prefs.theme_mode} onChange={(event) => updatePrefs("theme_mode", event.target.value)}><option value="system">System</option><option value="dark">Dark</option><option value="light">Light</option></select></label>
              <label className="field color-field settings-color-field"><span>Accent</span><input value={prefs.accent_color || "#37c9a7"} onChange={(event) => updatePrefs("accent_color", event.target.value)} type="color" /></label>
            </div>
            <div className="two-col">
              <label className="field color-field settings-color-field"><span>Secondary Accent <small>(gradient end)</small></span><input value={prefs.accent_secondary || ""} onChange={(event) => updatePrefs("accent_secondary", event.target.value)} type="color" /></label>
              <label className="field color-field settings-color-field"><span>Gallery Background</span><input value={prefs.gallery_bg_color || ""} onChange={(event) => updatePrefs("gallery_bg_color", event.target.value)} type="color" /></label>
            </div>
            <div className="two-col">
              <label className="field"><span>Grid</span><select value={prefs.grid_density} onChange={(event) => updatePrefs("grid_density", event.target.value)}><option value="compact">Compact</option><option value="comfortable">Comfortable</option><option value="wide">Wide</option></select></label>
              <label className="field"><span>Sort</span><select value={prefs.default_sort} onChange={(event) => updatePrefs("default_sort", event.target.value)}><option value="new">Newest</option><option value="popular">Popular</option><option value="views">Views</option><option value="downloads">Downloads</option><option value="old">Oldest</option></select></label>
            </div>
            <div className="two-col">
              <label className="field"><span>Items</span><input type="number" min="12" max="60" value={prefs.items_per_page} onChange={(event) => updatePrefs("items_per_page", Number(event.target.value))} /></label>
              <label className="field"><span>Profile layout</span><select value={prefs.profile_layout} onChange={(event) => updatePrefs("profile_layout", event.target.value)}><option value="spotlight">Spotlight</option><option value="magazine">Magazine</option><option value="stack">Stack</option><option value="split">Split</option><option value="mosaic">Mosaic</option><option value="timeline">Timeline</option></select></label>
            </div>
          </div>
            <div className="settings-cluster">
            <div className="settings-cluster-head"><h3>Gallery Personality</h3><p>How cards look, feel, and animate in the feed — pick a style that matches how you present your work.</p></div>
            <div className="two-col">
              <label className="field"><span>Card Hover Effect</span><select value={prefs.card_hover_effect ?? "lift"} onChange={(event) => updatePrefs("card_hover_effect", event.target.value)}><option value="lift">Lift</option><option value="zoom">Zoom</option><option value="reveal">Reveal</option><option value="glow">Glow</option><option value="none">None</option></select></label>
              <label className="field"><span>Card Aspect Ratio</span><select value={prefs.card_aspect_ratio ?? "free"} onChange={(event) => updatePrefs("card_aspect_ratio", event.target.value)}><option value="free">Free</option><option value="16:9">16:9 Widescreen</option><option value="4:3">4:3 Standard</option><option value="1:1">1:1 Square</option><option value="3:4">3:4 Portrait</option></select></label>
            </div>
            <div className="two-col">
              <label className="field"><span>Media Border</span><select value={prefs.media_border_style ?? "none"} onChange={(event) => updatePrefs("media_border_style", event.target.value)}><option value="none">None</option><option value="soft">Soft</option><option value="crisp">Crisp</option><option value="glow">Glow</option><option value="neon">Neon</option></select></label>
              <label className="field"><span>Card Info</span><select value={prefs.card_info_display ?? "below"} onChange={(event) => updatePrefs("card_info_display", event.target.value)}><option value="below">Below</option><option value="overlay">Overlay</option><option value="minimal">Minimal</option><option value="hidden">Hidden</option></select></label>
            </div>
            <div className="two-col">
              <label className="field"><span>Gallery Font</span><select value={prefs.gallery_font ?? "system"} onChange={(event) => updatePrefs("gallery_font", event.target.value)}><option value="system">System</option><option value="serif">Serif</option><option value="mono">Mono</option><option value="rounded">Rounded</option></select></label>
              <label className="field"><span>Column Gap</span><select value={prefs.column_gap ?? "normal"} onChange={(event) => updatePrefs("column_gap", event.target.value)}><option value="none">None</option><option value="tight">Tight</option><option value="normal">Normal</option><option value="wide">Wide</option></select></label>
            </div>
          </div>
            <div className="settings-cluster">
            <div className="settings-cluster-head"><h3>Profile Signature</h3><p>Fine-tune how your public profile header looks and what name style carries your brand.</p></div>
            <div className="two-col">
              <label className="field"><span>Name Style</span><select value={prefs.profile_name_style ?? "display"} onChange={(event) => updatePrefs("profile_name_style", event.target.value)}><option value="display">Display</option><option value="gradient">Gradient</option><option value="glow">Glow</option><option value="outline">Outline</option></select></label>
              <label className="field"><span>Header Style</span><select value={prefs.profile_header_style ?? "solid"} onChange={(event) => updatePrefs("profile_header_style", event.target.value)}><option value="solid">Solid</option><option value="glass">Glass</option><option value="blur">Blur</option><option value="transparent">Transparent</option><option value="gradient">Gradient</option></select></label>
            </div>
            <label className="field color-field settings-color-field"><span>Profile Background Color</span><input value={prefs.profile_bg_color || ""} onChange={(event) => updatePrefs("profile_bg_color", event.target.value)} type="color" /></label>
            <label className="field"><span>Watermark / Signature Text <small>(overlaid on your uploads)</small></span><input value={prefs.watermark_text ?? ""} onChange={(event) => updatePrefs("watermark_text", event.target.value)} placeholder="Optional text on your uploads (e.g. @handle)" maxLength={40} /></label>
          </div>
            <div className="settings-cluster">
            <div className="settings-cluster-head"><h3>Profile Language</h3><p>Decide how the public profile should frame your work and social presence.</p></div>
            <div className="two-col">
              <label className="field"><span>Banner</span><select value={prefs.profile_banner_style} onChange={(event) => updatePrefs("profile_banner_style", event.target.value)}><option value="gradient">Gradient</option><option value="mesh">Mesh</option><option value="frame">Frame</option><option value="aurora">Aurora</option><option value="spotlight">Spotlight</option><option value="poster">Poster</option></select></label>
              <label className="field"><span>Cards</span><select value={prefs.profile_card_style} onChange={(event) => updatePrefs("profile_card_style", event.target.value)}><option value="glass">Glass</option><option value="solid">Solid</option><option value="outline">Outline</option><option value="elevated">Elevated</option><option value="soft">Soft</option><option value="edge">Edge</option></select></label>
            </div>
            <div className="two-col">
              <label className="field"><span>Stats</span><select value={prefs.profile_stat_style} onChange={(event) => updatePrefs("profile_stat_style", event.target.value)}><option value="tiles">Tiles</option><option value="ribbon">Ribbon</option><option value="minimal">Minimal</option></select></label>
              <label className="field"><span>Focus</span><select value={prefs.profile_content_focus} onChange={(event) => updatePrefs("profile_content_focus", event.target.value)}><option value="balanced">Balanced</option><option value="gallery">Gallery</option><option value="collections">Collections</option><option value="social">Social</option></select></label>
            </div>
            <label className="field"><span>Hero alignment</span><select value={prefs.profile_hero_alignment} onChange={(event) => updatePrefs("profile_hero_alignment", event.target.value)}><option value="split">Split</option><option value="start">Start</option><option value="center">Center</option></select></label>
            <div className="two-col">
              <label className="field"><span>Avatar shape</span><select value={prefs.profile_avatar_shape} onChange={(event) => updatePrefs("profile_avatar_shape", event.target.value)}><option value="circle">Circle</option><option value="rounded">Rounded</option><option value="square">Square</option></select></label>
              <label className="field"><span>Media shape</span><select value={prefs.profile_media_shape} onChange={(event) => updatePrefs("profile_media_shape", event.target.value)}><option value="soft">Soft</option><option value="crisp">Crisp</option><option value="poster">Poster</option></select></label>
            </div>
            <div className="two-col">
              <label className="field"><span>Surface</span><select value={prefs.profile_surface_style} onChange={(event) => updatePrefs("profile_surface_style", event.target.value)}><option value="standard">Standard</option><option value="quiet">Quiet</option><option value="contrast">Contrast</option><option value="editorial">Editorial</option></select></label>
              <label className="field"><span>Social layout</span><select value={prefs.profile_social_layout} onChange={(event) => updatePrefs("profile_social_layout", event.target.value)}><option value="rail">Rail</option><option value="cards">Cards</option><option value="compact">Compact</option></select></label>
            </div>
            <div className="two-col">
              <label className="field"><span>Featured panel</span><select value={prefs.profile_featured_panel} onChange={(event) => updatePrefs("profile_featured_panel", event.target.value)}><option value="uploads">Uploads</option><option value="collections">Collections</option><option value="friends">Friends</option></select></label>
              <label className="field"><span>Backdrop strength</span><input type="range" min="0" max="0.55" step="0.01" value={prefs.profile_backdrop_strength ?? 0.18} onChange={(event) => updatePrefs("profile_backdrop_strength", Number(event.target.value))} /></label>
            </div>
            <label className="field"><span>Backdrop image URL</span><input value={prefs.profile_backdrop_image_url || ""} onChange={(event) => updatePrefs("profile_backdrop_image_url", event.target.value)} placeholder="https://..." /></label>
          </div>
            <div className="settings-cluster">
            <div className="settings-cluster-head"><h3>Playback and Visibility</h3><p>Small quality-of-life switches for browsing, preview behavior, and public sections.</p></div>
            <div className="check-stack settings-check-grid">
              <label className="check-row"><input checked={prefs.profile_show_joined_date} onChange={(event) => updatePrefs("profile_show_joined_date", event.target.checked)} type="checkbox" />Joined date</label>
              <label className="check-row"><input checked={prefs.profile_show_uploads} onChange={(event) => updatePrefs("profile_show_uploads", event.target.checked)} type="checkbox" />Profile uploads</label>
              <label className="check-row"><input checked={prefs.profile_show_collections} onChange={(event) => updatePrefs("profile_show_collections", event.target.checked)} type="checkbox" />Profile collections</label>
              <label className="check-row"><input checked={prefs.profile_show_friends} onChange={(event) => updatePrefs("profile_show_friends", event.target.checked)} type="checkbox" />Profile friends</label>
              <label className="check-row"><input checked={prefs.profile_show_follow_counts} onChange={(event) => updatePrefs("profile_show_follow_counts", event.target.checked)} type="checkbox" />Follow counts</label>
              <label className="check-row"><input checked={prefs.autoplay_previews} onChange={(event) => updatePrefs("autoplay_previews", event.target.checked)} type="checkbox" />Autoplay</label>
              <label className="check-row"><input checked={prefs.muted_previews} onChange={(event) => updatePrefs("muted_previews", event.target.checked)} type="checkbox" />Muted previews</label>
              <label className="check-row"><input checked={prefs.blur_video_previews} onChange={(event) => updatePrefs("blur_video_previews", event.target.checked)} type="checkbox" />Blur video previews</label>
              <label className="check-row"><input checked={prefs.reduce_motion} onChange={(event) => updatePrefs("reduce_motion", event.target.checked)} type="checkbox" />Reduced motion</label>
              <label className="check-row"><input checked={prefs.open_original_in_new_tab} onChange={(event) => updatePrefs("open_original_in_new_tab", event.target.checked)} type="checkbox" />Originals in new tab</label>
            </div>
          </div>
            <div className="form-actions settings-actions">
              <button className="primary" type="submit"><Save size={16} />Save Preferences</button>
            </div>
          </form>
          <div className="side-box stacked-form settings-form-card">
            <h2><ShieldCheck size={18} /> Identity</h2>
            <div className="field">
              <span>Avatar</span>
              <label className="settings-file-picker">
                <input type="file" accept="image/*" onChange={saveAvatar} />
                <Avatar user={{ ...ctx.user, ...profile }} large />
                <div>
                  <strong>Choose a new avatar</strong>
                  <small>PNG, JPG, GIF, or WEBP. The preview updates after upload.</small>
                </div>
              </label>
            </div>
            <form className="mini-form settings-inline-form" onSubmit={saveEmail}>
              <label className="field"><span>Email</span><input type="email" value={email} onChange={(event) => setEmail(event.target.value)} /></label>
              <div className="form-actions settings-actions"><button type="submit"><Mail size={16} />Save Email</button></div>
            </form>
            <form className="mini-form settings-inline-form" onSubmit={verifyEmail}>
              <label className="field"><span>Code</span><input value={emailCode} onChange={(event) => setEmailCode(event.target.value)} /></label>
              <div className="form-actions settings-actions"><button type="submit"><Check size={16} />Verify</button></div>
            </form>
            {ctx.user.age_verified_at ? (
              <div className="verified-state"><ShieldCheck size={18} /><strong>Age Verified</strong><span>Adult-content access is enabled for this account.</span></div>
            ) : (
              <form className="mini-form settings-inline-form" onSubmit={saveAge}>
                <label className="field"><span>Birthdate</span><input type="date" value={age.birthdate} onChange={(event) => setAge((current) => ({ ...current, birthdate: event.target.value }))} /></label>
                <label className="check-row"><input checked={age.confirm_over_18} onChange={(event) => setAge((current) => ({ ...current, confirm_over_18: event.target.checked }))} type="checkbox" />I am 18+</label>
                <div className="form-actions settings-actions"><button type="submit"><ShieldCheck size={16} />Verify Age</button></div>
              </form>
            )}
          </div>
          <form className="side-box stacked-form settings-form-card" onSubmit={changePassword}>
            <h2><KeyRound size={18} /> Password</h2>
            <label className="field"><span>Current</span><input type="password" value={password.old_password} onChange={(event) => setPassword((current) => ({ ...current, old_password: event.target.value }))} /></label>
            <label className="field"><span>New</span><input type="password" value={password.new_password} onChange={(event) => setPassword((current) => ({ ...current, new_password: event.target.value }))} /></label>
            <div className="form-actions settings-actions"><button type="submit">Change Password</button></div>
          </form>
        </div>
      </section>
    </Page>
  );
}
