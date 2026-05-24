# Image Gallery DB-backed hardening patch

Patched from `Image Gallery(17).zip`.

## What changed

- Default media storage is now database-backed (`GALLERY_STORAGE_BACKEND=database`) instead of filesystem-backed.
- `.env.example` now includes the DB-backed media storage settings and chunk/packet settings.
- The frontend auth retry regex was fixed so login/register/resend retry correctly from the GitHub Pages/static frontend.
- Login/register now also set an HttpOnly session cookie while keeping the existing bearer token response for compatibility.
- `/api/auth/logout` clears the HttpOnly session cookie.
- Frontend requests now send `credentials: "include"` so cookie sessions work across the live backend.
- CORS now allows credentials for the configured origins/tunnel regex.
- Rate limits are DB-backed through `api_rate_limits`, with in-process fallback only if the DB limiter is unavailable.
- Client IP detection no longer blindly trusts `X-Forwarded-For`; it only trusts forwarding headers from configured trusted proxy CIDRs and prefers Cloudflare's `CF-Connecting-IP`.
- CSP no longer allows inline scripts from the backend app shell.
- GitHub Pages root shell generation no longer uses inline `document.write` scripts.
- Frontend upload size now learns the backend's `max_upload_bytes` from `/api/live/checks` instead of relying only on a hardcoded constant.
- Image upload validation now rejects corrupt/undecodable image bytes instead of accepting files based only on magic bytes.
- Migration/index creation no longer silently hides unexpected DB/index errors; expected duplicate-index cases are ignored, while real problems are logged.
- `.gitignore` and `.dockerignore` were tightened to keep secrets, generated folders, old backups, uploads, and zip artifacts out of releases.

## DB-backed operation

The app now defaults to database-backed storage in code. For an existing local `.env`, make sure these lines are present:

```dotenv
GALLERY_STORAGE_BACKEND=database
GALLERY_DB_BLOB_CHUNK_BYTES=8388608
GALLERY_REQUIRED_DB_PACKET_BYTES=536870912
GALLERY_MAX_UPLOAD_BYTES=524288000
```

The backend still has legacy disk fallback/migration support so old `uploads/` records can be migrated into `media_files` and `media_file_chunks`.

## Validation run

- `python -m compileall -q app scripts` passed.
- `npm run build` passed.
- `scripts/api_route_test.py` passed with the bundled virtualenv.
- `npm run test:mock-ui` could not run here because the Playwright Chromium binary is not installed in this container. Run `npx playwright install` locally if you want that browser test.
