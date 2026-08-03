# Lua rewrite — remaining work

**View counts no longer inflate on repeat views, 2026-08-03**: every
`GET /api/media/:id` unconditionally did `views=views+1` — reopening a
post, pulling to refresh, or the client silently retrying all inflated
the count, reported live. (Checked git history first: the original Python
backend had the exact same unconditional-increment behavior, so this
wasn't a rewrite regression, but still a real bug worth fixing either
way.) Added a `media_views(media_id, viewer_key)` table (new, not in any
prior migration script — created directly via psql) with a composite
primary key doing the actual dedup: `viewer_key` is `"user:<id>"` for a
logged-in viewer or `"ip:<address>"` for an anonymous one (public posts
don't require login to view). `M.media_detail` now does `INSERT ... ON
CONFLICT DO NOTHING RETURNING media_id` and only increments the counter
when that insert actually adds a new row — i.e. the first time *this*
viewer has ever seen *this* post. Verified live: the same viewer hitting
a post 3x only added 1 view; a genuinely different (real, newly
registered then deleted) viewer correctly added exactly 1 more.

**Two more real bugs found and fixed, 2026-08-02 (later same day)**:
- Login was silently locking out any account with a non-lowercase stored
  username (`M.login` lowercased the input via `normalize_username()` but
  then did an exact-match `WHERE username=%s` against it) — confirmed
  live against the site owner's own account ("HeavenlyXenusVR"). Fixed to
  `WHERE LOWER(username)=%s`; also hardened `M.register`'s duplicate-check
  the same way so a case-colliding second account can't be created going
  forward. Verified with a throwaway mixed-case test account: login now
  succeeds regardless of input case, and a colliding registration is
  correctly rejected.
- `/api/site/background` (the rotating 16:9 site-wide background,
  App.jsx's already-built 5-minute crossfade logic) was never ported to
  Lua at all — 404ing, so the feature silently did nothing. Recovered the
  original logic from git history (`9986ab5^:app/routers/media_feed.py` +
  `app/db/feed_collections.py`) and ported it to `routes.lua`'s new
  "Site-wide rotating background" section: candidates are filtered in SQL
  to public, non-deleted, image-kind, **`is_adult=false`**, aspect ratio
  within 0.035 of 16:9, cached 300s, with a "never immediately repeat the
  previous pick" rule. Simplified from Python by requiring
  `image_width`/`image_height` to already be populated (skips Python's
  image-header-byte-sniffing fallback for rows missing them — every
  current upload path already sets these columns, so the candidate pool
  isn't meaningfully smaller). Verified live: correct 16:9 image picked
  (3840×2160), persists across repeated calls within the 5-minute window
  with a correctly-ticking `refresh_after_seconds`, thumb URL resolves,
  and confirmed via direct query simulation that flipping a candidate's
  `is_adult` to true correctly removes it from the pool.

**Cutover complete as of 2026-08-02.** The live site
(gallery.xenusanimations.studio) is served directly by the Lua backend
(`lua/`, port 8789) — the cloudflared tunnel points straight at it. The
Python backend (`app/`) has been **removed from the repo entirely** (was
git history-preserved via normal commits, so it's fully recoverable with
`git log --diff-filter=D -- app/` if ever needed), its docker container
(`web_image_gallery`) stopped and removed, and its service block deleted
from the shared `Music/docker-compose.yml` (so it can't come back via
`restart: always` on a compose-wide restart). The Node reverse proxy that
used to bridge Lua/Python (`scripts/live_proxy.mjs`) is also gone. The
Telegram control-panel bot is now served exclusively by
`lua/src/telegram.lua`.

**Critical gap found and fixed, 2026-08-02**: `/api/users/search`,
`/api/users/:username`(`/profile`), followers/following/friends,
follow/friend-request/respond, and block were never ported to Lua at all —
confirmed live-404ing in production, breaking profile pages, user search,
and follow/friend/block flows for both the web app and iOS. Recovered the
original logic from git history (`9986ab5^:app/routers/social.py` +
`app/db/social.py`) and ported all of it to `lua/src/routes.lua` (new
"Public profiles, follows, friend requests..." section) + registered in
`lua/main.lua`. Verified live end-to-end with two throwaway test accounts
(created, exercised follow/friend-request/accept/block/unfollow, deleted
after — no residue). Found and fixed one real bug during that testing:
`list_profile_friends()`'s viewer-id parameter wasn't always `tostring()`'d
before binding against a `::text=%s` comparison — harmless when the caller
already had a string id, but `my_friends()` passed a raw Lua number twice,
which made Postgres error ("operator does not exist: text = integer") on
a query `db.fetchall()` silently swallows into an empty list rather than
surfacing. Also fixed a related profile-lookup bug: incorrectly reused
routes.lua's login/register `normalize_username()` (which lowercases) for
profile-by-username lookups, which are supposed to be case-sensitive exact
matches per the original Python — broke looking up the site owner's own
grandfathered mixed-case username, "HeavenlyXenusVR".

**Frontend, 2026-08-02**: the React SPA (`frontend/`, `node_modules/`,
`static/react/`) is NOT going away — it's a real client-routed app (feed,
media detail, messages, studio, upload, ...), not a SwarmPanel-style
server-rendered admin panel, so a full port isn't a "safe" incremental
step. What did move to Lua, as a deliberately narrow slice:
- `scripts/write-root-shell.mjs` → `scripts/write_root_shell.lua` (verified
  byte-identical output). `package.json`'s `build` script now runs
  `vite build && luajit scripts/write_root_shell.lua` — Node/Vite still
  builds the SPA itself, this only replaced the trivial static-file-writer
  second step.
- `/login` and `/register` are now server-rendered directly by
  `lua/src/pages_auth.lua` (form POST → `routes.login`/`register`/
  `verify_2fa`, no duplicated auth logic) instead of falling through to the
  React SPA shell. On success they render a small bridge page that seeds
  `localStorage`'s `image_gallery_token`/`image_gallery_user` (same keys
  `frontend/src/api.js` reads) and redirects to `/`, so the SPA picks up
  the session exactly like a normal in-app JS login would. Note:
  react-router still owns a client-side `/login` route — in-app link
  clicks never leave the SPA, so only a hard navigation (typed URL, fresh
  load, external redirect) hits the new Lua page. Both are valid, just
  visually different depending on entry point. No dedicated SPA
  `/register` route existed, so that path is purely additive.
  Verified live: GET /login, GET /register, POST /register (real account
  created then deleted), POST /login with bad credentials (error
  re-rendered, 401) all correct through the direct-to-Lua path.
- `/admin` is now a server-rendered site-owner dashboard
  (`lua/src/pages_admin.lua`, new shared `lua/src/html.lua` for esc/
  urlencoded-form-parsing/byte+date formatting): Reports, Flagged Uploads,
  Users & Bans, Storage, Site Settings, and Audit Log as one page with
  plain POST-per-action forms, reusing `routes.admin_*` directly (no logic
  duplicated). Gated by the same `require_site_owner` check as the JSON
  admin API (now exported as `routes.require_site_owner_for_page`).
  **Found and fixed two more real bugs while wiring this up**:
  (1) the site-owner gate had *never* actually granted access to the real
  owner account in production — `SITE_OWNER_EMAIL` in routes.lua didn't
  match the account's actual stored email, and `email_verified_at` was
  NULL. Fixed both (see the constant's own comment; confirmed with the
  user which email was authoritative before changing anything).
  (2) `routes.lua`'s `arr()` returns the special `cjson.empty_array`
  sentinel (lightuserdata, not a table) for empty lists, which is correct
  for JSON responses but breaks `ipairs()` when these pages call
  `routes.admin_*` directly instead of going through JSON encoding — added
  `html.as_list()` to guard every such call site.
  Verified live end-to-end with a real minted session token for the (now-
  fixed) owner account: GET /admin renders real data (15 media items,
  68.6 MB tracked, 507 orphaned cache files, top-storage-user table), and
  a real POST to /admin/actions/site-settings round-trips correctly
  (redirect + flash message + unchanged values confirmed via the JSON
  endpoint). Non-owner and logged-out access correctly return 403 / redirect
  to /login.
- `/settings/2fa` is now a server-rendered TOTP enrollment/disable page
  (`lua/src/pages_totp.lua`), open to any logged-in user (not site-owner-
  only) via a new `routes.require_login_for_page` export. Reuses
  `routes.totp_enroll/confirm/disable` directly. **Deliberately renders no
  QR code image** — see the file's header comment: piping the otpauth://
  URI (which embeds the raw TOTP secret) through a third-party QR-image
  service would leak that secret externally, and hand-rolling a QR
  encoder isn't something worth shipping unverified in an environment
  with no scanner to confirm it actually scans. Shows the base32 secret
  grouped for manual entry instead, plus the otpauth:// URI as a tappable
  link (most authenticator apps register that scheme). Fixed one bug
  found while testing the wrong-code retry path: the first draft
  re-called `routes.totp_enroll()` to redisplay the pending secret on a
  failed confirm, but that function unconditionally generates and stores
  a brand-new secret every call — silently invalidating the one the user
  had just scanned. Now reads the still-pending secret straight from the
  DB instead. Verified live end-to-end with a throwaway account: wrong
  code correctly rejected without invalidating the secret, correct code
  enables 2FA and shows recovery codes, status page reflects the enabled
  state, wrong disable-password rejected, correct password disables.

## Not ported (both are background-only, no HTTP/user-facing surface)

These two features existed only in the now-removed Python source. Losing
them costs nothing a user would notice; they'd need to be written from
scratch in Lua (not restored from Python, since that source is gone from
the working tree — see git history above) if ever wanted:

- **The periodic moderation-digest loop** — new reports/bans/signups/
  storage-growth summary, sent via Telegram/Discord.
- **Background AI learning** — the periodic pass that turned curated
  gallery metadata into new AI training examples, plus visual-hash/
  training-example lookup matching in the upload-analysis flow.
- Relatedly, **Ollama and OpenAI-compatible vision providers** and a local
  CLIP classifier were never ported to Lua either — only Gemini is (this
  deployment's actual configured provider). If `GALLERY_AI_PROVIDER` is
  ever set to anything else, or no Gemini key is configured, analysis
  gracefully degrades to heuristic/domain-hint instead of erroring.

## What changed in the final cutover session (2026-08-02)

- Ported the last two real HTTP gaps: `POST /api/media/:media_id/ai/train`
  and `POST /api/media/:media_id/diagnostics/load`. Verified live.
- **Critical fix: an event-loop-blocking bug.** Every outbound HTTPS call
  (Telegram polling, Gemini vision, Discord webhooks, Ollama status) used
  `ssl.https`/`socket.http` directly, which blocks the single OS thread
  copas runs on for the full call duration — for Telegram's ~30s long-poll,
  that froze the *entire server* for anyone else for ~30s at a stretch.
  Fixed by switching all four call sites to `copas.http`. Verified: 20
  rapid health checks during active Telegram long-polling all returned
  instantly.
- **Telegram bot cutover.** `lua/src/telegram.lua`'s bridge is now the sole
  `getUpdates` poller (Python's is gone).
- Stopped and removed the `web_image_gallery` container, pointed
  `~/.cloudflared/image-gallery-ingress.yml` at `http://localhost:8789`
  (Lua) directly, retired `image-gallery-proxy.service`/
  `scripts/live_proxy.mjs`, and repointed `image-gallery-tunnel.service`
  (the health-gate/config publisher) from port 8788 to 8789.
- **Removed the Python source entirely**: `app/` (all routers/db modules),
  `requirements.txt`, `Dockerfile`, the Python `tests/` suite, and the
  scripts that only existed to operate on `app.*` (`api_route_test.py`,
  `import_icloud_photos.py`, `prewarm_video_quality.py`,
  `reclassify_media_categories.py`,
  `seed_ai_vision_training_from_gallery.py`,
  `seed_ai_vision_training_from_image_zip.py`, `test_ai_vision_model.py`).
  Rewrote `.github/workflows/ci.yml` to syntax-check every Lua module and
  any remaining `.mjs` scripts instead of running Python lint/tests
  against a package that no longer exists.
  **Second cleanup pass (2026-08-02)**, after gallery.xenusanimations.studio
  started serving the SPA directly (see `lua/src/static.lua`): removed the
  now-fully-dead Python/MySQL-era remnants confirmed unused by grepping for
  callers — `pytest.ini`, `README_APPLY.txt` (referenced the deleted
  `app/`), `scripts/fill_character_subcategories.py` and
  `scripts/repair_gallery_metadata.py` (raw `pymysql` against the
  since-replaced MariaDB, DB is Postgres on 5432 now), `scripts/start_pinggy_tunnel.py`
  (only reachable via the launcher below; the live tunnel manager's
  `TUNNEL_PROVIDER` never supported `pinggy` anyway),
  `scripts/set_mariadb_500mb_packet.sh` and `scripts/prewarm_thumbnails.sh`
  (both shelled out to the `mariadb` CLI against the gone MySQL DB), and
  the whole `scripts/{start,stop,install_live_backend_service,uninstall_live_backend_service}.sh`
  family (installed/ran a systemd unit named `image-gallery-live-backend.service`
  that doesn't exist anymore — superseded by `image-gallery-lua.service` +
  `image-gallery-tunnel.service` + `image-gallery-cloudflared.service`).
  Also stripped the disabled-by-default Python-fallback branch
  (`install_python_deps`/`start_fallback_backend`, gated on
  `GALLERY_SERVICE_START_BACKEND_IF_MISSING`) out of the still-active
  `scripts/start_live_tunnel_service.sh`, and fixed its stale `PORT="${1:-8788}"`
  default to `8789`. Deleted the now-unused `.venv/` (100MB, was the Python
  backend's virtualenv; gitignored, nothing left references it).
  **Left alone**: `scripts/nixos_live_doctor.sh` and
  `scripts/install_nixos_dependencies.sh` still list `python311`/`mariadb`
  as NixOS packages to install/check — edited system-config-modifying
  scripts felt out of scope for a "delete unused files" pass, and other
  projects on this host may still use those packages.
- Verified live end-to-end after every step: `/api/health`,
  `/api/categories`, `/api/media`, `/api/tags`, `/api/site/announcement`
  all correct through the direct-to-Lua path; Telegram's own
  `getWebhookInfo` showed `pending_update_count: 0` (actively drained by
  Lua's poller, no backlog).

## If you ever want to go further

- Porting the two background loops and/or the Ollama/OpenAI vision
  providers to Lua from scratch, if you ever need them (Python source is
  gone from the working tree, but fully recoverable from git history for
  reference).
- Removing `python311`/`mariadb` from `scripts/nixos_live_doctor.sh` and
  `scripts/install_nixos_dependencies.sh`'s package lists, if nothing else
  on this host still needs them.
