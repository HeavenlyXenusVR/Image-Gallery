import { chromium } from "playwright";

const BASE_URL = process.env.IMAGE_GALLERY_TEST_URL || "http://127.0.0.1:8788";
const TOKEN = "mock-gallery-token";
const PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=";

const currentUser = {
  id: 1,
  username: "heavenly",
  display_name: "Heavenly Mock",
  email: "heavenly@example.test",
  bio: "Mock bio",
  website_url: "https://example.test",
  location_label: "Mock City",
  profile_headline: "Testing every button",
  profile_color: "#37c9a7",
  featured_tags: ["cloud", "aria"],
  public_profile: true,
  user_settings: {
    theme_mode: "system",
    accent_color: "#37c9a7",
    grid_density: "comfortable",
    default_sort: "new",
    items_per_page: 24,
    autoplay_previews: false,
    muted_previews: true,
    reduce_motion: false,
    open_original_in_new_tab: false,
  },
};

const categories = [
  { id: 2, name: "Profile Pictures", slug: "profile-pictures", subcategories: [{ id: 9, name: "Final Fantasy", slug: "final-fantasy" }] },
  { id: 10, name: "Dazzlings", slug: "dazzlings", subcategories: [{ id: 3, name: "Aria Blaze", slug: "aria-blaze" }] },
];

function mediaItem(id, overrides = {}) {
  return {
    id,
    user_id: 1,
    username: "heavenly",
    display_name: "Heavenly Mock",
    title: `Mock Media ${id}`,
    description: "Mock description",
    media_kind: "image",
    mime_type: "image/png",
    file_size: 2048,
    visibility: "public",
    comments_enabled: true,
    downloads_enabled: true,
    locked: false,
    is_adult: false,
    category_id: 2,
    category_name: "Profile Pictures",
    subcategory_id: 9,
    subcategory_name: "Final Fantasy",
    tags: ["cloud", "strife", "mock"],
    thumb_url: `/api/media/${id}/thumb?w=640`,
    preview_url: `/api/media/${id}/preview`,
    url: `/api/media/${id}/file`,
    download_url: `/api/media/${id}/download`,
    user_avatar_url: "/api/users/1/avatar?v=1",
    liked_by_me: false,
    bookmarked_by_me: false,
    like_count: id,
    views: 10 + id,
    downloads: id % 3,
    comment_count: 1,
    created_at: "2026-05-14T12:00:00Z",
    updated_at: "2026-05-14T12:00:00Z",
    ...overrides,
  };
}

const mediaRows = Array.from({ length: 25 }, (_, index) => mediaItem(index + 1));
const ownerMedia = mediaItem(14, { title: "Cloud Strife Profile Picture", like_count: 7 });
const friendUser = {
  id: 2,
  username: "mock-friend",
  display_name: "Mock Friend",
  profile_headline: "Friendship route",
  profile_color: "#89b4fa",
  following_by_me: false,
  friend_status: "none",
  media_count: 1,
  follower_count: 2,
  friend_count: 3,
};

const collections = [
  { id: 5, name: "Mock Favorites", description: "Saved mock media", item_count: 2, is_public: true },
  { id: 6, name: "Private Drafts", description: "Private collection", item_count: 1, is_public: false },
];

function json(payload, status = 200) {
  return {
    status,
    contentType: "application/json",
    body: JSON.stringify(payload),
    headers: { "Cache-Control": "no-store" },
  };
}

function png() {
  return {
    status: 200,
    contentType: "image/png",
    body: Buffer.from(PNG_BASE64, "base64"),
    headers: { "Cache-Control": "public, max-age=3600" },
  };
}

function withUpdatedMedia(id, patch = {}) {
  return { media: mediaItem(Number(id), { ...ownerMedia, id: Number(id), ...patch }) };
}

async function installMocks(context, options = {}) {
  const requests = [];
  const unhandled = [];
  let authenticated = !options.unauthenticated;

  await context.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname;
    const method = request.method();
    requests.push({ method, path, search: url.search });

    if (/^\/api\/media\/\d+\/(thumb|preview|file|download)$/.test(path) || /^\/api\/users\/\d+\/avatar$/.test(path)) {
      return route.fulfill(png());
    }

    if (path === "/api/me" && method === "GET") {
      if (!authenticated && !request.headers().authorization) return route.fulfill(json({ detail: "Not authenticated" }, 401));
      return route.fulfill(json({ user: currentUser }));
    }
    if (path === "/api/auth/login" && method === "POST") {
      authenticated = true;
      return route.fulfill(json({ token: TOKEN, user: currentUser }));
    }
    if (path === "/api/auth/register" && method === "POST") {
      authenticated = true;
      return route.fulfill(json({ token: TOKEN, user: { ...currentUser, username: "new-gallery-user" } }));
    }

    if (path === "/api/categories" && method === "GET") return route.fulfill(json({ categories }));
    if (path === "/api/tags" && method === "GET") return route.fulfill(json({ tags: [{ name: "cloud" }, { name: "aria" }, { name: "mock" }] }));
    if (path === "/api/live/checks" && method === "GET") return route.fulfill(json({ ok: true, checks: { api: true, database: true } }));

    if (path === "/api/media" && method === "GET") return route.fulfill(json({ media: mediaRows }));
    if (path === "/api/media" && method === "POST") return route.fulfill(json({ media: mediaItem(88, { title: "Uploaded Mock Media" }) }));
    if (path === "/api/media/random" && method === "GET") return route.fulfill(json({ media: ownerMedia }));
    if (path === "/api/media/analyze" && method === "POST") {
      return route.fulfill(json({ analysis: { media_kind: "image", title: "Analyzed Mock", description: "AI mock", category_name: "Profile Pictures", subcategory_name: "Final Fantasy", tags: ["analyzed", "mock"], is_adult: false } }));
    }
    const mediaDetail = path.match(/^\/api\/media\/(\d+)$/);
    if (mediaDetail && method === "GET") {
      return route.fulfill(json({
        media: mediaItem(Number(mediaDetail[1]), { ...ownerMedia, id: Number(mediaDetail[1]) }),
        comments: [{ id: 4, user_id: 1, username: "heavenly", display_name: "Heavenly Mock", body: "Existing mock comment" }],
      }));
    }
    if (mediaDetail && method === "DELETE") return route.fulfill(json({ ok: true }));
    if (/^\/api\/media\/\d+\/controls$/.test(path) && method === "PATCH") return route.fulfill(json(withUpdatedMedia(path.split("/")[3], { visibility: "unlisted" })));
    if (/^\/api\/media\/\d+\/restore$/.test(path) && method === "POST") return route.fulfill(json(withUpdatedMedia(path.split("/")[3], { deleted_at: null })));
    if (/^\/api\/media\/\d+\/like$/.test(path) && method === "POST") return route.fulfill(json(withUpdatedMedia(path.split("/")[3], { liked_by_me: true, like_count: 99 })));
    if (/^\/api\/media\/\d+\/bookmark$/.test(path) && method === "POST") return route.fulfill(json(withUpdatedMedia(path.split("/")[3], { bookmarked_by_me: true })));
    if (/^\/api\/media\/\d+\/comments$/.test(path) && method === "POST") return route.fulfill(json({ comment: { id: 5, user_id: 1, username: "heavenly", display_name: "Heavenly Mock", body: "Fresh mock comment" } }));
    if (/^\/api\/media\/\d+\/report$/.test(path) && method === "POST") return route.fulfill(json({ ok: true }));
    if (/^\/api\/comments\/\d+$/.test(path) && method === "DELETE") return route.fulfill(json({ ok: true }));

    if (path === "/api/collections" && method === "GET") return route.fulfill(json({ collections }));
    if (path === "/api/collections" && method === "POST") return route.fulfill(json({ collection: { id: 99, name: "Created Mock Collection", description: "Created", item_count: 0, is_public: true } }));
    const collectionDetail = path.match(/^\/api\/collections\/(\d+)$/);
    if (collectionDetail && method === "GET") {
      const collection = collections.find((item) => Number(item.id) === Number(collectionDetail[1])) || collections[0];
      return route.fulfill(json({ collection, media: [mediaItem(21), mediaItem(22)] }));
    }
    if (/^\/api\/collections\/\d+\/items$/.test(path) && method === "POST") return route.fulfill(json({ ok: true }));

    if (path === "/api/feed/following" && method === "GET") return route.fulfill(json({ media: mediaRows.slice(0, 10) }));
    if (path === "/api/me/likes" && method === "GET") return route.fulfill(json({ media: mediaRows.slice(0, 10).map((item) => ({ ...item, liked_by_me: true })) }));
    if (path === "/api/me/media" && method === "GET") return route.fulfill(json({ media: [mediaItem(31), mediaItem(32, { deleted_at: "2026-05-14T12:00:00Z" })] }));

    if (path === "/api/users/search" && method === "GET") return route.fulfill(json({ users: [friendUser, { ...currentUser, friend_status: "self" }] }));
    const profileMatch = path.match(/^\/api\/users\/([^/]+)\/profile$/);
    if (profileMatch && method === "GET") {
      const username = decodeURIComponent(profileMatch[1]);
      const user = username === currentUser.username ? currentUser : friendUser;
      return route.fulfill(json({ user, media: [mediaItem(41, { user_id: user.id, username: user.username, display_name: user.display_name })], collections, friends: [currentUser] }));
    }
    if (/^\/api\/users\/\d+\/follow$/.test(path) && method === "POST") return route.fulfill(json({ ok: true }));
    if (/^\/api\/users\/\d+\/friend-request$/.test(path) && method === "POST") return route.fulfill(json({ ok: true }));

    if (path === "/api/friends/requests" && method === "GET") {
      return route.fulfill(json({
        incoming: [{ id: 10, user: friendUser }],
        outgoing: [{ id: 11, user: { ...friendUser, id: 3, username: "pending-friend", display_name: "Pending Friend" } }],
      }));
    }
    if (path === "/api/me/friends" && method === "GET") return route.fulfill(json({ friends: [{ ...friendUser, id: 4, username: "actual-friend", display_name: "Actual Friend" }] }));
    if (/^\/api\/friends\/requests\/\d+$/.test(path) && method === "POST") return route.fulfill(json({ ok: true }));

    if (path === "/api/me/profile" && method === "PATCH") return route.fulfill(json({ user: currentUser }));
    if (path === "/api/me/settings" && method === "PATCH") return route.fulfill(json({ user: currentUser }));
    if (path === "/api/me/email" && method === "POST") return route.fulfill(json({ user: currentUser, email_verification_sent: true }));
    if (path === "/api/me/email/verify" && method === "POST") return route.fulfill(json({ user: currentUser }));
    if (path === "/api/me/avatar" && method === "POST") return route.fulfill(json({ user: { ...currentUser, avatar_url: "/api/users/1/avatar?v=2" } }));
    if (path === "/api/me/age-verification" && method === "POST") return route.fulfill(json({ user: currentUser }));
    if (path === "/api/me/password" && method === "POST") return route.fulfill(json({ ok: true }));

    unhandled.push(`${method} ${path}${url.search}`);
    return route.fulfill(json({ detail: `Unhandled mock route: ${method} ${path}` }, 599));
  });

  return { requests, unhandled };
}

function watchPage(page, failures) {
  page.on("pageerror", (error) => failures.push(`pageerror: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() === "error") failures.push(`console error: ${message.text()}`);
  });
  page.on("requestfailed", (request) => failures.push(`request failed: ${request.method()} ${request.url()} ${request.failure()?.errorText}`));
  page.on("response", (response) => {
    const url = response.url();
    if (url.includes("/api/") && response.status() >= 500) failures.push(`api ${response.status()}: ${url}`);
  });
}

async function expectVisible(page, text) {
  await page.getByText(text, { exact: false }).first().waitFor({ state: "visible", timeout: 10_000 });
}

async function click(page, name) {
  await page.getByRole("button", { name }).first().click();
}

async function installBrowserSafety(context) {
  await context.addInitScript(() => {
    window.__mockOpened = [];
    window.open = (url) => {
      window.__mockOpened.push(String(url || ""));
      return null;
    };
  });
}

async function runAuthAndPublicMock(browser, failures) {
  const publicContext = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  await installBrowserSafety(publicContext);
  const publicMock = await installMocks(publicContext, { unauthenticated: true });
  const publicPage = await publicContext.newPage();
  watchPage(publicPage, failures);
  await publicPage.goto(`${BASE_URL}/`, { waitUntil: "networkidle" });
  await publicPage.locator(".media-card").first().waitFor({ state: "visible", timeout: 10_000 });
  await publicPage.locator(".card-actions button").first().click();
  await expectVisible(publicPage, "Login");

  await publicPage.getByLabel("Username").fill("heavenly");
  await publicPage.getByLabel("Password").fill("mock-password");
  await publicPage.locator(".auth-card button.primary").click();
  await publicPage.locator(".media-card").first().waitFor({ state: "visible", timeout: 10_000 });
  if (!publicMock.requests.some((request) => request.path === "/api/auth/login" && request.method === "POST")) failures.push("gallery login form did not POST");
  failures.push(...publicMock.unhandled);
  await publicContext.close();

  const registerContext = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  await installBrowserSafety(registerContext);
  const registerMock = await installMocks(registerContext, { unauthenticated: true });
  const registerPage = await registerContext.newPage();
  watchPage(registerPage, failures);
  await registerPage.goto(`${BASE_URL}/login`, { waitUntil: "networkidle" });
  await click(registerPage, "Register");
  await registerPage.getByLabel("Username").fill("new-gallery-user");
  await registerPage.getByLabel("Display name").fill("New Gallery User");
  await registerPage.getByLabel("Email").fill("new-gallery@example.test");
  await registerPage.getByLabel("Password").fill("mock-password");
  await registerPage.locator(".auth-card button.primary").click();
  await registerPage.locator(".media-card").first().waitFor({ state: "visible", timeout: 10_000 });
  if (!registerMock.requests.some((request) => request.path === "/api/auth/register" && request.method === "POST")) failures.push("gallery register form did not POST");
  failures.push(...registerMock.unhandled);
  await registerContext.close();
}

async function runAuthenticatedMock(browser, failures) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 980 } });
  await installBrowserSafety(context);
  await context.addInitScript((payload) => {
    localStorage.setItem("image_gallery_token", payload.token);
    localStorage.setItem("image_gallery_user", JSON.stringify(payload.user));
  }, { token: TOKEN, user: currentUser });
  const mock = await installMocks(context);
  const page = await context.newPage();
  watchPage(page, failures);

  await page.goto(`${BASE_URL}/`, { waitUntil: "networkidle" });
  await page.locator(".media-card").first().waitFor({ state: "visible", timeout: 10_000 });
  await click(page, "Refresh");
  await page.getByPlaceholder("wallpaper, meme, vaporwave").fill("cloud");
  await page.locator(".filter-rail select").nth(0).selectOption("image");
  await page.locator(".filter-rail select").nth(1).selectOption("2");
  await page.locator(".filter-rail select").nth(2).selectOption("9");
  await page.locator(".filter-rail select").nth(3).selectOption("views");
  await page.locator(".tag-cloud button").first().click();
  await page.getByRole("button", { name: "Next" }).click();
  await page.getByRole("button", { name: "Previous" }).click();
  await page.locator(".card-actions button").nth(0).click();
  await page.locator(".card-actions button").nth(1).click();
  await page.locator(".card-actions button").nth(2).click();
  const openedAfterCardDownload = await page.evaluate(() => window.__mockOpened.length);
  if (openedAfterCardDownload < 1) failures.push("card download did not call window.open");
  await click(page, "Surprise");
  await page.waitForURL(/\/media\/\d+/, { timeout: 10_000 });
  await expectVisible(page, "Cloud Strife Profile Picture");

  await page.getByRole("button", { name: /Like|Unlike/ }).first().click();
  await page.getByRole("button", { name: /Save|Saved/ }).first().click();
  await page.getByRole("button", { name: "Download" }).click();
  await page.locator(".detail-side select").first().selectOption("5");
  await page.getByRole("button", { name: "Add" }).click();
  await page.locator(".detail-side").getByRole("button", { name: "Save" }).first().click();
  await page.locator(".detail-side").getByRole("button", { name: "Delete" }).first().click();
  await page.getByPlaceholder("Reason").fill("mock report");
  await page.getByPlaceholder("Details").fill("mock details");
  await page.locator("form.side-box").getByRole("button", { name: "Send" }).click();
  await page.getByPlaceholder("Add a comment").fill("Fresh mock comment");
  await page.getByRole("button", { name: "Post" }).click();
  await expectVisible(page, "Fresh mock comment");
  await page.locator(".comment .icon-button").first().click();

  await page.getByRole("link", { name: "Collections" }).click();
  await expectVisible(page, "Collections");
  await click(page, "Refresh");
  await click(page, "Mine");
  await page.getByPlaceholder("Collection name").fill("Created Mock Collection");
  await page.getByPlaceholder("Description").fill("Created through mock test");
  await page.getByRole("button", { name: "Create" }).click();
  await expectVisible(page, "Created Mock Collection");
  await page.locator(".collection-row").first().click();

  await page.getByRole("link", { name: "Users" }).click();
  await expectVisible(page, "Users");
  await page.getByPlaceholder("Search users").fill("friend");
  await expectVisible(page, "Mock Friend");
  await page.locator(".user-card").first().getByRole("button", { name: "Follow" }).click();
  await page.locator(".user-card").first().getByRole("button", { name: /Friend|Add Friend|Requested/ }).click();
  await page.locator(".user-card").first().getByRole("link").first().click();
  await expectVisible(page, "Mock Friend");
  await page.getByRole("button", { name: "Follow" }).first().click();

  await page.getByRole("link", { name: "Following" }).click();
  await expectVisible(page, "Following");
  await page.locator(".media-card").first().waitFor({ state: "visible", timeout: 10_000 });
  await page.getByRole("link", { name: "Liked" }).click();
  await expectVisible(page, "Liked");
  await page.locator(".media-card").first().waitFor({ state: "visible", timeout: 10_000 });

  await page.getByRole("link", { name: "Friends" }).click();
  await expectVisible(page, "Friends");
  await click(page, "Refresh");
  await page.getByRole("button", { name: "Accept" }).click();
  await page.getByRole("button", { name: "Decline" }).click();
  await page.getByRole("button", { name: "Cancel" }).click();

  await page.getByRole("link", { name: "Studio" }).click();
  await expectVisible(page, "Studio");
  await click(page, "Refresh");
  await page.locator(".studio-list .side-box").first().getByRole("button", { name: "Save" }).click();
  await page.locator(".studio-list").getByRole("button", { name: "Delete" }).first().click();

  await page.getByRole("link", { name: "Upload" }).click();
  await expectVisible(page, "Upload");
  await page.locator("input[type='file']").setInputFiles({ name: "mock.png", mimeType: "image/png", buffer: Buffer.from(PNG_BASE64, "base64") });
  await expectVisible(page, "mock.png");
  const analyzeButton = page.getByRole("button", { name: "Analyze" });
  await analyzeButton.waitFor({ state: "visible", timeout: 10_000 });
  await page.waitForFunction(() => {
    const button = Array.from(document.querySelectorAll("button")).find((item) => item.textContent?.includes("Analyze"));
    return button && !button.disabled;
  });
  await Promise.all([
    page.waitForResponse((response) => response.url().includes("/api/media/analyze") && response.request().method() === "POST"),
    analyzeButton.click(),
  ]);
  const analyzedTitle = await page.getByLabel("Title").inputValue();
  if (analyzedTitle !== "Analyzed Mock") failures.push(`analyze did not fill title, saw: ${analyzedTitle}`);
  await click(page, "Upload");
  await page.waitForURL(/\/media\/88/, { timeout: 10_000 });

  await page.getByTitle("Settings").click();
  await expectVisible(page, "Settings");
  await page.getByLabel("Display name").fill("Heavenly Mock Updated");
  await page.locator("form.stacked-form.side-box").nth(0).getByRole("button", { name: "Save" }).click();
  await page.locator("form.stacked-form.side-box").nth(1).getByRole("button", { name: "Save" }).click();
  await page.locator("input[type='file']").setInputFiles({ name: "avatar.png", mimeType: "image/png", buffer: Buffer.from(PNG_BASE64, "base64") });
  await page.getByLabel("Email").fill("heavenly-updated@example.test");
  await page.getByRole("button", { name: "Save Email" }).click();
  await page.getByLabel("Code").fill("123456");
  await page.getByRole("button", { name: "Verify", exact: true }).click();
  await page.getByLabel("Birthdate").fill("2000-01-01");
  await page.getByLabel("I am 18+").check();
  await page.getByRole("button", { name: "Verify Age" }).click();
  await page.getByLabel("Current", { exact: true }).fill("old-password");
  await page.getByLabel("New", { exact: true }).fill("new-password");
  await page.getByRole("button", { name: "Change" }).click();

  await page.getByTitle("Logout").click();
  await expectVisible(page, "Login");

  const requiredPosts = [
    "/api/media/analyze",
    "/api/media",
    "/api/me/profile",
    "/api/me/settings",
    "/api/me/email",
    "/api/me/email/verify",
    "/api/me/age-verification",
    "/api/me/password",
  ];
  for (const path of requiredPosts) {
    if (!mock.requests.some((request) => request.path === path && ["POST", "PATCH"].includes(request.method))) {
      failures.push(`expected mutation request for ${path}`);
    }
  }
  failures.push(...mock.unhandled);
  await context.close();
}

async function runMobileMock(browser, failures) {
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 },
    isMobile: true,
    hasTouch: true,
  });
  await installBrowserSafety(context);
  await context.addInitScript((payload) => {
    localStorage.setItem("image_gallery_token", payload.token);
    localStorage.setItem("image_gallery_user", JSON.stringify(payload.user));
  }, { token: TOKEN, user: currentUser });
  const mock = await installMocks(context);
  const page = await context.newPage();
  watchPage(page, failures);

  await page.goto(`${BASE_URL}/`, { waitUntil: "networkidle" });
  await page.locator(".media-card").first().waitFor({ state: "visible", timeout: 10_000 });
  await click(page, "Refresh");

  await page.getByRole("link", { name: "Collections" }).click();
  await expectVisible(page, "Collections");
  await page.getByRole("link", { name: "Users" }).click();
  await expectVisible(page, "Users");
  await page.getByRole("link", { name: "Following" }).click();
  await expectVisible(page, "Following");
  await page.locator(".media-card").first().waitFor({ state: "visible", timeout: 10_000 });
  await page.getByRole("link", { name: "Liked" }).click();
  await expectVisible(page, "Liked");
  await page.locator(".media-card").first().waitFor({ state: "visible", timeout: 10_000 });
  await page.getByRole("link", { name: "Friends" }).click();
  await expectVisible(page, "Friends");
  await page.getByRole("link", { name: "Studio" }).click();
  await expectVisible(page, "Studio");
  await page.getByRole("link", { name: "Upload" }).click();
  await expectVisible(page, "Upload");
  await page.getByTitle("Settings").click();
  await expectVisible(page, "Settings");
  await page.getByTitle("Profile").click();
  await expectVisible(page, "Testing every button");
  await page.getByTitle("Logout").click();
  await expectVisible(page, "Login");

  failures.push(...mock.unhandled);
  await context.close();
}

async function main() {
  const browser = await chromium.launch({ headless: true });
  const failures = [];
  try {
    await runAuthAndPublicMock(browser, failures);
    await runAuthenticatedMock(browser, failures);
    await runMobileMock(browser, failures);
  } finally {
    await browser.close();
  }
  if (failures.length) {
    console.error(failures.join("\n"));
    process.exit(1);
  }
  console.log("image_gallery_mock_ui=passed");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
