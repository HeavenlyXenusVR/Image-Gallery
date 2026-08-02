# Lua rewrite — remaining work

**Cutover complete as of 2026-08-02.** The live site
(gallery.xenusanimations.studio) is served directly by the Lua backend
(`lua/`, port 8789) — the cloudflared tunnel points straight at it, the
Python backend (`app/`, `web_image_gallery` docker container) is stopped,
and the Node reverse proxy that used to bridge the two (`scripts/live_proxy.mjs`)
has been removed along with its systemd service. The Telegram control-panel
bot is now served exclusively by `lua/src/telegram.lua` — Python's poller is
stopped, so there's no more conflict.

`app/` (the Python source) is still present in the repo as historical
reference but is not running. See "Not ported" below for the two small
background-only gaps that come with that.

## Not ported (both are background-only, no HTTP/user-facing surface)

- **The periodic moderation-digest loop** (`_moderation_digest_loop` — new
  reports/bans/signups/storage-growth summary, sent via Telegram/Discord).
  Depends on `db.digest_counts_since()`/`site_settings.last_digest_at`,
  neither ported.
- **Background AI learning** (the periodic pass that turns curated gallery
  metadata into new training examples). Depends on visual-hash/
  training-example lookup matching (`_training_lookup_analysis`), not
  ported.
- Relatedly, **Ollama and OpenAI-compatible vision providers** and the local
  CLIP classifier subprocess aren't ported — only Gemini is (this
  deployment's actual configured provider). If `GALLERY_AI_PROVIDER` is ever
  set to anything else, or no Gemini key is configured, analysis gracefully
  degrades to heuristic/domain-hint instead of erroring.

## What changed in the final cutover session (2026-08-02)

- Ported the last two real HTTP gaps: `POST /api/media/:media_id/ai/train`
  (mirrors `record_ai_vision_training_example` — upserts by a dedupe key;
  not byte-identical to Python's hash, only used for this backend's own
  future upserts) and `POST /api/media/:media_id/diagnostics/load`
  (client-side telemetry logging). Both verified live.
- **Critical fix: an event-loop-blocking bug.** Every outbound HTTPS call
  (Telegram polling, Gemini vision, Discord webhooks, Ollama status) used
  `ssl.https`/`socket.http` directly, which blocks the single OS thread
  copas runs on for the full call duration — for Telegram's ~30s long-poll,
  that froze the *entire server* for anyone else for ~30s at a stretch, and
  is what caused a real request to hang mid-session. Fixed by switching all
  four call sites to `copas.http` (vendored alongside copas, yields during
  socket I/O instead of blocking). Verified: 20 rapid health checks during
  active Telegram long-polling all returned instantly.
- **Telegram bot cutover.** `lua/src/telegram.lua`'s bridge (all 8 gallery
  commands, db-health watch, startup/db-problem alerts) is now the sole
  `getUpdates` poller. Along the way, a systemd `Environment=` override
  meant to keep it disabled during testing turned out not to take
  precedence over the same key in `EnvironmentFile=` (contrary to
  documented systemd behavior, not fully root-caused) — worked around with
  a dedicated `GALLERY_LUA_TELEGRAM_FORCE_DISABLE` env var (a name `.env`
  never sets, so no ambiguity), which has since been removed now that the
  cutover is deliberate and complete.
- Stopped `web_image_gallery` (Python container), pointed
  `~/.cloudflared/image-gallery-ingress.yml` at `http://localhost:8789`
  (Lua) directly, restarted `image-gallery-cloudflared.service`, retired
  `image-gallery-proxy.service` and `scripts/live_proxy.mjs`, and
  repointed `image-gallery-tunnel.service` (the health-gate/config
  publisher) from port 8788 to 8789 so it stops crash-looping against a
  backend that's now intentionally offline.
- Verified live end-to-end after every step: `/api/health`,
  `/api/categories`, `/api/media`, `/api/tags`, `/api/site/announcement`
  all correct through the new direct-to-Lua path; Telegram's own
  `getWebhookInfo` showed `pending_update_count: 0` (actively being
  drained by Lua's poller, no backlog).

## If you ever want to go further

- `app/` (Python) is stopped but still in the repo. Whether to actually
  delete it or keep it as reference is up to you — it's a single monolith
  (`app/main.py`) mixing the FastAPI app, startup/lifespan, and the two
  background loops above that aren't ported, so a clean "delete what Lua
  replaced" pass would need a careful read-through first, not a blind
  `rm -rf app/`.
- Porting the two background loops and/or the Ollama/OpenAI vision
  providers, if you ever need them.
