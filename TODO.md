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
- **Video thumbnail/quality cache warmup.**
- **`POST /api/media/analyze`, `POST /api/media/:media_id/ai/train`,
  `POST /api/media/:media_id/diagnostics/load`** — the two `ai/` ones need
  the LLM pipeline above; diagnostics/load is just client-side telemetry
  logging and is low priority.

(`PATCH /api/media/:media_id`, `PATCH /api/media/:media_id/controls`,
`DELETE /api/media/:media_id`, `POST /api/media/:media_id/restore`,
`POST /api/media/:media_id/report`, `DELETE /api/comments/:comment_id`,
`GET /api/media/:media_id/similar`, `POST /api/media/bulk`, and
`POST /api/media/bulk-delete` are now ported — see
`lua/main.lua`/`lua/src/routes.lua`. Any new literal-segment route under
`/api/media/*` still needs to go above the `/api/media/:media_id` registration
in `lua/main.lua` — see the ROUTE-ORDERING TRAP comment there.

Multi-subcategory arrays (up to 3 per post, `subcategory_ids`/
`subcategory_names` on upload and edit, `subcategories`/`subcategory_ids`/
`subcategory_names` on every media response) are also now ported — see the
"Category/subcategory find-or-create + multi-subcategory support" section in
`lua/src/routes.lua`, above `M.list_media`.

`GET /api/admin/storage` and `POST /api/admin/storage/purge-orphans` are also
now ported, with one deliberate fix over the Python version: Python's
`_walk_cache_dir` builds its "referenced" set from `storage_by_user`'s
per-user aggregate rows (`row["id"]` on a row shaped `{user_id, username,
display_name, item_count, total_bytes}` — a KeyError, and even if it weren't,
a user id can't match a cache filename keyed by media id anyway). The Lua
version builds the referenced set from actual live `media_items` ids
instead, which is what `_thumb_cache`/`_video_cache` filenames are really
keyed by, so orphan detection actually works. See the comment above
`walk_cache_dir` in `lua/src/routes.lua`.)

## Once everything above is ported

- Add the newly-ported routes to `PORTED_ROUTES` in `scripts/live_proxy.mjs`
  (keep it in sync with `lua/main.lua`'s `httpd.route(...)` calls).
- When the list covers 100% of `app/`'s routes and the Telegram bot has a
  Lua equivalent running, retire the Python backend and `scripts/live_proxy.mjs`
  entirely, and point the cloudflared ingress
  (`~/.cloudflared/image-gallery-ingress.yml`) straight at the Lua backend's
  port.
