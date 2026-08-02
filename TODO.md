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
  Kept: `app/static/` (frontend build artifacts — `scripts/write-root-shell.mjs`
  and `frontend/src/main.jsx` both still reference `app/static/react/`
  as part of the GitHub Pages deploy shell, unrelated to the Python
  backend) and a few standalone scripts that never imported `app.*`
  (`fill_character_subcategories.py`, `repair_gallery_metadata.py` — both
  raw `pymysql`, pre-Postgres-migration legacy; `start_pinggy_tunnel.py`,
  an alternate tunnel provider tool).
  Rewrote `.github/workflows/ci.yml` to syntax-check every Lua module and
  any remaining `.mjs` scripts instead of running Python lint/tests
  against a package that no longer exists.
  **Not touched** (still reference Python, but are manual/diagnostic
  tools not in the automatic live-serving path, so left alone rather than
  risking a large rewrite under time pressure): `scripts/start_live_backend.sh`,
  `scripts/nixos_live_doctor.sh`, and the disabled-by-default
  (`GALLERY_SERVICE_START_BACKEND_IF_MISSING=0`) Python-fallback branch
  inside `scripts/start_live_tunnel_service.sh`.
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
- Cleaning up the remaining Python references in `start_live_backend.sh`,
  `nixos_live_doctor.sh`, and the dead fallback branch in
  `start_live_tunnel_service.sh` (all currently harmless/inert, not part
  of the live path).
