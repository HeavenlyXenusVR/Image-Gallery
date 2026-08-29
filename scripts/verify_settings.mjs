// Comprehensive live-preview verification of every Settings customization
// option. Must run against a real HTTPS origin, not the local Vite dev
// server -- the app authenticates via a Secure session cookie (see
// App.jsx's loginWith()), and browsers never set Secure cookies over plain
// HTTP, so localhost:5174 can never hold a session at all. Logs in via the
// server-rendered /login page (pages_auth.lua shadows the SPA's own
// client-side /login route on a hard navigation -- see main.lua), then
// exercises every control on /settings, checks the live preview reacts,
// saves, verifies persistence via a reload + API refetch, then restores
// the account's original profile/settings on exit (success or failure).
//
// Usage: NYXFRAME_TEST_USERNAME=... NYXFRAME_TEST_PASSWORD=... node scripts/verify_settings.mjs
import { chromium } from "playwright";

// The web app authenticates via a Secure, HttpOnly session cookie (see
// App.jsx's loginWith()) -- Secure cookies are never set by the browser
// over plain HTTP, so this MUST run against the real HTTPS origin; the
// local Vite dev server (http://) cannot authenticate at all.
const BASE = process.env.NYXFRAME_TEST_URL || "https://gallery.xenusanimations.studio";
const USERNAME = process.env.NYXFRAME_TEST_USERNAME;
const PASSWORD = process.env.NYXFRAME_TEST_PASSWORD;
if (!USERNAME || !PASSWORD) {
  console.error("Set NYXFRAME_TEST_USERNAME and NYXFRAME_TEST_PASSWORD (a real account -- this exercises the live Settings page end-to-end and restores its prior state on exit).");
  process.exit(2);
}

const results = []; // { field, status: PASS|FAIL, detail }
function record(field, ok, detail) {
  results.push({ field, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${field}${detail ? " -- " + detail : ""}`);
}

async function main() {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  page.on("pageerror", (err) => console.log("PAGE ERROR:", err.message));
  page.on("console", (msg) => { if (msg.type() === "error") console.log("CONSOLE ERROR:", msg.text()); });

  // ---- Login ----
  // GET /login is intentionally intercepted server-side by pages_auth.lua
  // (a plain server-rendered form) on a hard navigation, ahead of the SPA's
  // own client-side /login route -- see main.lua's comment above that
  // route registration. So a fresh page.goto("/login") hits the
  // server-rendered form, not React. It sets the same session cookie
  // (routes.login under the hood), so log in there, then navigate into the
  // SPA at /settings directly.
  await page.goto(`${BASE}/login`, { waitUntil: "networkidle" });
  await page.locator('#username').fill(USERNAME);
  await page.locator('#password').fill(PASSWORD);
  await page.click('form[action="/login"] button[type="submit"], form[action="/login"] input[type="submit"]');
  await page.waitForLoadState("load");
  await page.waitForTimeout(1500);

  const originalMe = await page.evaluate(async () => {
    const res = await fetch("/api/me");
    return res.ok ? res.json() : null;
  });
  console.log("original /api/me ok:", !!originalMe, originalMe?.user?.username);
  if (!originalMe?.user) throw new Error("Login did not establish a session -- aborting before touching any settings.");
  const originalSettings = originalMe.user.user_settings;
  const originalProfile = {
    display_name: originalMe.user.display_name,
    bio: originalMe.user.bio,
    profile_quote: originalMe.user.profile_quote,
    website_url: originalMe.user.website_url,
    location_label: originalMe.user.location_label,
    profile_headline: originalMe.user.profile_headline,
    featured_tags: originalMe.user.featured_tags,
    profile_color: originalMe.user.profile_color,
    public_profile: originalMe.user.public_profile,
    show_liked_count: originalMe.user.show_liked_count,
    show_collections: originalMe.user.show_collections,
    show_recent_uploads: originalMe.user.show_recent_uploads,
    show_friends: originalMe.user.show_friends,
  };

  try {
  await page.goto(`${BASE}/settings`, { waitUntil: "load" });
  await page.waitForSelector(".profile-settings-preview", { timeout: 15000 });

  const asideSel = ".profile-settings-preview";

  async function asideClasses() {
    return page.$eval(asideSel, (el) => el.className);
  }
  async function asideStyleVar(varName) {
    return page.$eval(asideSel, (el, v) => el.style.getPropertyValue(v), varName);
  }
  async function chipTexts() {
    return page.$$eval(".settings-preview-chips span", (els) => els.map((e) => e.textContent.trim()));
  }
  async function metricTexts() {
    return page.$$eval(".settings-preview-metrics > div", (els) => els.map((e) => e.querySelector("strong")?.textContent?.trim()));
  }
  async function statusTexts() {
    return page.$$eval(".settings-status-grid > div", (els) => els.map((e) => e.querySelector("strong")?.textContent?.trim()));
  }

  function selectByLabel(labelText) {
    return page.locator(`label.field:has(span:text-is("${labelText}")) select`);
  }
  function inputByLabel(labelText, type = null) {
    const base = page.locator(`label.field:has(span:text-is("${labelText}")) input`);
    return type ? base.and(page.locator(`[type="${type}"]`)) : base;
  }
  function checkboxByText(text) {
    return page.locator(`label.check-row:has-text("${text}") input[type="checkbox"]`);
  }
  // Setting `.value` directly on a controlled React input doesn't survive
  // React's own tracked setter -- the DOM shows the new value for a moment,
  // but since React's component state never actually changed, the very
  // next re-render snaps it back. Going through the native setter React
  // itself patched (same trick React Testing Library's fireEvent uses) is
  // what actually reaches the onChange handler and updates state for real.
  async function setNativeInputValue(locator, value) {
    await locator.evaluate((el, v) => {
      const proto = el.tagName === "TEXTAREA" ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
      setter.call(el, v);
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    }, value);
  }

  // -----------------------------------------------------------------
  // Group 1: selects that drive profileClassName() on the preview aside
  // -----------------------------------------------------------------
  const classDrivenSelects = [
    { label: "Banner", prefix: "profile-banner-" },
    { label: "Cards", prefix: "profile-card-" },
    { label: "Stats", prefix: "profile-stat-" },
    { label: "Focus", prefix: "profile-focus-" },
    { label: "Hero alignment", prefix: "profile-align-" },
    { label: "Avatar shape", prefix: "profile-avatar-" },
    { label: "Media shape", prefix: "profile-media-" },
    { label: "Surface", prefix: "profile-surface-" },
    { label: "Social layout", prefix: "profile-social-" },
    { label: "Featured panel", prefix: "profile-feature-" },
    { label: "Name Style", prefix: "profile-name-" },
    { label: "Header Style", prefix: "profile-header-" },
  ];

  for (const { label, prefix } of classDrivenSelects) {
    const select = selectByLabel(label);
    const count = await select.count();
    if (count === 0) { record(label, false, "select not found"); continue; }
    const optionValues = await select.locator("option").evaluateAll((opts) => opts.map((o) => o.value));
    let allOk = true;
    const before = await asideClasses();
    for (const value of optionValues) {
      await select.selectOption(value);
      await page.waitForTimeout(80);
      const classes = await asideClasses();
      const expectedClass = `${prefix}${value.toLowerCase()}`;
      const ok = classes.split(/\s+/).includes(expectedClass);
      if (!ok) { allOk = false; console.log(`   -> ${label}=${value}: expected class "${expectedClass}" in [${classes}]`); }
    }
    record(label, allOk, `${optionValues.length} options cycled`);
  }

  // -----------------------------------------------------------------
  // Group 2: style-var driven controls on the preview aside
  // -----------------------------------------------------------------
  // Accent color feeds --accent via profile.profile_color (Profile form) taking priority.
  {
    const colorInput = inputByLabel("Color"); // Profile section "Color" field (profile_color)
    await setNativeInputValue(colorInput, "#ff3366");
    await page.waitForTimeout(80);
    const accent = await asideStyleVar("--accent");
    record("Profile Color (profile_color) -> --accent", accent.toLowerCase() === "#ff3366", `got ${accent}`);
  }

  {
    const range = inputByLabel("Backdrop strength");
    await setNativeInputValue(range, "0.4");
    await page.waitForTimeout(80);
    const val = await asideStyleVar("--profile-backdrop-strength");
    record("Backdrop strength (profile_backdrop_strength)", val === "40%", `got ${val}`);
  }

  {
    const range = inputByLabel("Panel opacity");
    await setNativeInputValue(range, "0.75");
    await page.waitForTimeout(80);
    const val = await asideStyleVar("--profile-surface-opacity");
    record("Panel opacity (profile_surface_opacity)", val === "0.75", `got ${val}`);
  }

  {
    const range = inputByLabel("Panel blur");
    await setNativeInputValue(range, "12");
    await page.waitForTimeout(80);
    const val = await asideStyleVar("--profile-surface-blur");
    record("Panel blur (profile_surface_blur)", val === "12px", `got ${val}`);
  }

  {
    // Profile Background Color: click "Set color" button first to reveal the color input.
    const setBtn = page.locator('label.field:has(span:text-is("Profile Background Color")) button.opt-color-set');
    if (await setBtn.count()) await setBtn.click();
    await page.waitForTimeout(80);
    const colorInput = page.locator('label.field:has(span:text-is("Profile Background Color")) input[type="color"]');
    await setNativeInputValue(colorInput, "#112233");
    await page.waitForTimeout(80);
    const val = await asideStyleVar("--profile-bg-override");
    record("Profile Background Color (profile_bg_color)", val.toLowerCase() === "#112233", `got ${val}`);
  }

  {
    const input = inputByLabel("Backdrop image URL");
    await input.fill("https://example.com/test-backdrop.jpg");
    await page.waitForTimeout(80);
    const val = await asideStyleVar("--profile-backdrop");
    record("Backdrop image URL (profile_backdrop_image_url)", val.includes("example.com/test-backdrop.jpg"), `got ${val}`);
  }

  // -----------------------------------------------------------------
  // Group 3: profile hero text/tag/avatar fields (Profile form) reflected
  // in the preview hero directly.
  // -----------------------------------------------------------------
  {
    const headline = inputByLabel("Headline");
    await headline.fill("Playwright Live Preview Check");
    await page.waitForTimeout(80);
    const text = await page.$eval(`${asideSel} .profile-preview-hero strong`, (el) => el.textContent);
    record("Headline (profile_headline)", text.includes("Playwright Live Preview Check"), `got "${text}"`);
  }
  {
    const bio = page.locator('label.field:has(span:text-is("Bio")) textarea');
    await bio.fill("This is a Playwright smoke-test bio.");
    await page.waitForTimeout(80);
    const text = await page.$eval(`${asideSel} .profile-preview-hero p`, (el) => el.textContent);
    record("Bio", text.includes("Playwright smoke-test bio"), `got "${text}"`);
  }
  {
    const tags = inputByLabel("Featured tags");
    await tags.fill("playwrighttest, livepreview");
    await page.waitForTimeout(80);
    const chipText = await page.$eval(`${asideSel} .profile-preview-hero .chip-row`, (el) => el.textContent);
    record("Featured tags", chipText.includes("playwrighttest") && chipText.includes("livepreview"), `got "${chipText}"`);
  }

  // -----------------------------------------------------------------
  // Group 4: text-chip / metric-driven selects (raw text in preview, not class)
  // -----------------------------------------------------------------
  {
    const select = selectByLabel("Theme");
    await select.selectOption("dark");
    await page.waitForTimeout(80);
    const chips = await chipTexts();
    record("Theme (theme_mode) chip text", chips.includes("dark"), `chips=${JSON.stringify(chips)}`);
  }
  {
    const select = selectByLabel("Grid");
    await select.selectOption("wide");
    await page.waitForTimeout(80);
    const chips = await chipTexts();
    record("Grid (grid_density) chip text", chips.includes("wide"), `chips=${JSON.stringify(chips)}`);
  }
  {
    const select = selectByLabel("Profile layout");
    const optionValues = await select.locator("option").evaluateAll((opts) => opts.map((o) => o.value));
    let allOk = true;
    for (const value of optionValues) {
      await select.selectOption(value);
      await page.waitForTimeout(80);
      const metrics = await metricTexts();
      const classes = await asideClasses();
      const classOk = classes.split(/\s+/).includes(`profile-layout-${value}`);
      const metricOk = metrics.includes(value);
      if (!classOk || !metricOk) { allOk = false; console.log(`   -> Profile layout=${value}: classOk=${classOk} metricOk=${metricOk} metrics=${JSON.stringify(metrics)}`); }
    }
    record("Profile layout (profile_layout)", allOk, `${optionValues.length} options cycled`);
  }

  // -----------------------------------------------------------------
  // Group 5: Command Snapshot status-card toggles
  // -----------------------------------------------------------------
  {
    const cb = checkboxByText("Public profile");
    const wasChecked = await cb.isChecked();
    await cb.setChecked(!wasChecked);
    await page.waitForTimeout(80);
    const statuses = await statusTexts();
    const expected = wasChecked ? "Private" : "Public";
    record("Public profile toggle -> status card", statuses.includes(expected), `statuses=${JSON.stringify(statuses)}`);
    await cb.setChecked(wasChecked); // restore immediately
  }
  {
    const cb = checkboxByText("Autoplay");
    const wasChecked = await cb.isChecked();
    await cb.setChecked(!wasChecked);
    await page.waitForTimeout(80);
    const statuses = await statusTexts();
    const expected = wasChecked ? "Manual" : "Auto";
    record("Autoplay toggle -> status card", statuses.includes(expected), `statuses=${JSON.stringify(statuses)}`);
    await cb.setChecked(wasChecked);
  }
  {
    const cb = checkboxByText("Originals in new tab");
    const wasChecked = await cb.isChecked();
    await cb.setChecked(!wasChecked);
    await page.waitForTimeout(80);
    const statuses = await statusTexts();
    const expected = wasChecked ? "Inline" : "New Tab";
    record("Originals in new tab toggle -> status card", statuses.includes(expected), `statuses=${JSON.stringify(statuses)}`);
    await cb.setChecked(wasChecked);
  }

  // -----------------------------------------------------------------
  // Group 6: pure form-state checkboxes with no dedicated live-preview
  // element on this page -- verify the control itself toggles correctly.
  // -----------------------------------------------------------------
  const plainCheckboxes = [
    "Liked count", "Collections", "Uploads", "Friends", // profile visibility (note: ambiguous text, scope below)
  ];
  // Profile visibility checkboxes (scoped under the Profile form's Visibility cluster)
  const profileVisibilityLabels = ["Liked count", "Collections", "Uploads", "Friends"];
  for (const label of profileVisibilityLabels) {
    const cb = page.locator(`form:has(h2:has-text("Profile")) label.check-row:has-text("${label}") input[type="checkbox"]`).first();
    if (await cb.count() === 0) { record(`Profile visibility: ${label}`, false, "not found"); continue; }
    const before = await cb.isChecked();
    await cb.setChecked(!before);
    const after = await cb.isChecked();
    record(`Profile visibility: ${label}`, after === !before, `${before} -> ${after}`);
    await cb.setChecked(before);
  }

  const playbackLabels = [
    "Joined date", "Profile uploads", "Profile collections", "Profile friends", "Follow counts",
    "Muted previews", "Blur video previews", "Reduced motion",
  ];
  for (const label of playbackLabels) {
    const cb = checkboxByText(label);
    if (await cb.count() === 0) { record(`Playback/visibility: ${label}`, false, "not found"); continue; }
    const before = await cb.isChecked();
    await cb.setChecked(!before);
    const after = await cb.isChecked();
    record(`Playback/visibility: ${label}`, after === !before, `${before} -> ${after}`);
    await cb.setChecked(before);
  }

  // -----------------------------------------------------------------
  // Group 7: Gallery Personality selects -- NOT reflected on this page's
  // preview aside at all (they drive galleryClassName/galleryStyle on the
  // app Shell, not profileClassName/profileStyle on this aside). Verify
  // the control changes, then verify real integration after Save by
  // checking .app-shell picks up the class/style once persisted.
  // -----------------------------------------------------------------
  const galleryPersonality = [
    { label: "Card Hover Effect", candidates: ["glow", "zoom"], classFor: (v) => `gallery-hover-${v}` },
    { label: "Media Border", candidates: ["neon", "crisp"], classFor: (v) => `gallery-border-${v}` },
    { label: "Card Info", candidates: ["overlay", "minimal"], classFor: (v) => `gallery-info-${v}` },
    { label: "Gallery Font", candidates: ["mono", "serif"], classFor: (v) => `gallery-font-${v}` },
  ];
  for (const item of galleryPersonality) {
    const select = selectByLabel(item.label);
    if (await select.count() === 0) { record(item.label, false, "select not found"); continue; }
    // The account may already have this exact value saved from a prior
    // session -- if so the class is already on Shell for a real reason,
    // and re-selecting the same value proves nothing about pre-save
    // isolation. Pick whichever of the two candidate values isn't already
    // the current selection, and derive the expected class from that.
    const current = await select.inputValue();
    const candidates = item.candidates || [item.value];
    const chosen = candidates.find((c) => c !== current) || item.value;
    await select.selectOption(chosen);
    const val = await select.inputValue();
    const expectedClass = item.classFor(chosen);
    const notYetOnShell = await page.evaluate((cls) => !document.querySelector(".app-shell")?.classList.contains(cls), expectedClass);
    record(`${item.label} (control changes; confirmed NOT live on Shell pre-save)`, val === chosen && notYetOnShell, `select=${val} current-was=${current}`);
    item.chosen = chosen;
    item.shellClass = expectedClass;
  }
  // Card Aspect Ratio and Column Gap set CSS vars, not classes -- just confirm select changes.
  for (const [label, value] of [["Card Aspect Ratio", "1:1"], ["Column Gap", "wide"]]) {
    const select = selectByLabel(label);
    await select.selectOption(value);
    const val = await select.inputValue();
    record(label, val === value, `select=${val}`);
  }

  // -----------------------------------------------------------------
  // Now SAVE both forms and verify persistence + real Shell integration.
  // -----------------------------------------------------------------
  await page.click('button:has-text("Save Profile")');
  await page.waitForTimeout(600);
  await page.click('button:has-text("Save Preferences")');
  await page.waitForTimeout(600);

  const toastOk = await page.locator(".toast, .notice").first().isVisible().catch(() => false);
  console.log("Save toast visible:", toastOk);

  // Confirm the earlier-set Gallery Personality values are now live on the app Shell (not just Settings-local).
  for (const item of galleryPersonality) {
    const hasClass = await page.evaluate((cls) => document.querySelector(".app-shell")?.classList.contains(cls), item.shellClass);
    record(`${item.label} live on .app-shell after Save`, hasClass, `class ${item.shellClass}`);
  }

  // Reload and confirm the form re-populates with saved values (real persistence, not just optimistic UI).
  await page.reload({ waitUntil: "load" });
  await page.waitForSelector(".profile-settings-preview");
  const themeAfterReload = await selectByLabel("Theme").inputValue();
  record("theme_mode persists across reload", themeAfterReload === "dark", `got ${themeAfterReload}`);
  const headlineAfterReload = await inputByLabel("Headline").inputValue();
  record("profile_headline persists across reload", headlineAfterReload === "Playwright Live Preview Check", `got "${headlineAfterReload}"`);

  } finally {
    // Restore the real account to exactly what it was before this run,
    // regardless of pass/fail above -- this is the live production admin
    // account, not a throwaway fixture.
    const restorePayload = { ...originalProfile, featured_tags: originalProfile.featured_tags || [] };
    const restoreResult = await page.evaluate(async ({ profile, settings }) => {
      const out = {};
      const profileRes = await fetch("/api/me/profile", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify(profile) });
      out.profile = profileRes.status;
      const settingsRes = await fetch("/api/me/settings", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify(settings) });
      out.settings = settingsRes.status;
      return out;
    }, { profile: restorePayload, settings: originalSettings });
    console.log("Restore result:", JSON.stringify(restoreResult));

    const verifyRestored = await page.evaluate(async () => {
      const res = await fetch("/api/me");
      return res.ok ? res.json() : null;
    });
    const restoredOk = verifyRestored?.user?.profile_headline === originalProfile.profile_headline
      && verifyRestored?.user?.user_settings?.theme_mode === originalSettings.theme_mode;
    record("Account restored to original state", restoredOk, restoredOk ? "confirmed" : "MISMATCH -- check manually");
  }

  await browser.close();

  const failed = results.filter((r) => !r.ok);
  console.log(`\n==== ${results.length - failed.length}/${results.length} PASSED ====`);
  if (failed.length) {
    console.log("FAILURES:");
    for (const f of failed) console.log(` - ${f.field}: ${f.detail || ""}`);
  }
  process.exitCode = failed.length ? 1 : 0;
}

main().catch((err) => { console.error("FATAL:", err); process.exit(2); });
