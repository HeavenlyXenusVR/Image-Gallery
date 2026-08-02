# Lua rewrite — remaining work

The live site (gallery.xenusanimations.studio) is now served by
`scripts/live_proxy.mjs`, a reverse proxy that routes already-ported
endpoints to the Lua backend (`lua/`) and falls back to the original
Python/FastAPI backend (`app/`) for everything else. See that file's header
comment for the exact list of ported routes and how to keep it in sync with
`lua/main.lua`.

Nothing below is broken — it all still works today via the Python fallback.
This is a punch list for finishing the full replacement.

## Not yet ported

- **LLM classification pipeline** (`app/ai_metadata.py`, ~2150 lines) —
  OpenAI/Gemini/Ollama prompt construction plus heuristic fallback. Powers
  `auto_ai` uploads and `POST /api/media/analyze`. The Lua side only has the
  status/config surface (`ai_vision_status` etc.), not the actual
  classification calls.
- **Telegram bot integration** (`app/telegram.py` + gallery-specific command
  handlers) — long-running polling background service, not an HTTP route at
  all. Needs its own standalone Lua process/service, not just a route port.
- **Possible-duplicate detection** via perceptual hashing.
- **Background AI learning** (training examples feeding back into future
  classification).
- **Saved-search match notifications.**
- **Multi-subcategory arrays** on media (Lua currently assumes the
  single-subcategory shape).
- **Video thumbnail/quality cache warmup.**
- **Admin storage dashboard / orphaned-cache-purge endpoints** — these walk
  the filesystem directly and haven't been touched.
- **`/api/media/trending`, `/api/media/random`, `/api/media/bulk`** and any
  other literal-segment routes under `/api/media/*` in
  `app/routers/media.py` not already in the ported list — see the
  ROUTE-ORDERING TRAP comment in `lua/main.lua` above the
  `/api/media/:media_id` registration before adding any of these.

## Once everything above is ported

- Add the newly-ported routes to `PORTED_ROUTES` in `scripts/live_proxy.mjs`
  (keep it in sync with `lua/main.lua`'s `httpd.route(...)` calls).
- When the list covers 100% of `app/`'s routes and the Telegram bot has a
  Lua equivalent running, retire the Python backend and `scripts/live_proxy.mjs`
  entirely, and point the cloudflared ingress
  (`~/.cloudflared/image-gallery-ingress.yml`) straight at the Lua backend's
  port.
