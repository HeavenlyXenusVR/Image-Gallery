# Lua rewrite — remaining work

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
